import SwiftUI
import WebKit

#if os(macOS)
    import AppKit
    typealias RenderedImage = NSImage
#else
    import UIKit
    typealias RenderedImage = UIImage
#endif

struct RenderedContentKey: Hashable {
    var content: RenderedContent
    var width: Int
    var fontSize: CGFloat
    var dark: Bool
}

struct RenderedContentImage {
    var image: RenderedImage
    var size: CGSize
    var baseline: CGFloat
    var selectionBounds: CGRect? = nil
}

/// WebKit requires the network-client entitlement even for bundled file pages.
/// Navigation stays local; the page CSP separately prohibits remote subresources.
@MainActor
private final class RenderNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    var failed = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed = true
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failed = true }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.request.url?.isFileURL == true ? .allow : .cancel
    }
}

/// At most two short-lived web renderers, with a bounded cache shared across documents.
/// The native editor owns selection and storage; WebKit only produces disposable pixels.
@MainActor
final class DocumentContentRenderer {
    static let shared = DocumentContentRenderer()
    private var active = 0
    private var cache: [RenderedContentKey: RenderedContentImage] = [:]
    private var cacheOrder: [RenderedContentKey] = []

    enum RenderError: LocalizedError {
        case unavailable, tooLarge
        var errorDescription: String? {
            switch self {
            case .unavailable: L10n.string("rendered.unavailable")
            case .tooLarge: L10n.string("rendered.too_large")
            }
        }
    }

    func render(_ key: RenderedContentKey) async throws -> RenderedContentImage {
        if let cached = cache[key] { return cached }
        guard key.content.source.utf16.count <= 50_000 else { throw RenderError.tooLarge }
        while active >= 2 { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        active += 1
        defer { active -= 1 }
        #if SWIFT_PACKAGE
            let bundle = Bundle.module
        #else
            let bundle = Bundle.main
        #endif
        guard let directory = bundle.url(forResource: "DocumentRendering", withExtension: nil) else { throw RenderError.unavailable }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let width = CGFloat(max(80, min(2048, key.width)))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1200), configuration: configuration)
        #if os(macOS)
            web.underPageBackgroundColor = .clear
        #else
            web.isOpaque = false
            web.backgroundColor = .clear
            web.scrollView.isScrollEnabled = false
        #endif
        let navigation = RenderNavigation()
        web.navigationDelegate = navigation
        defer { web.stopLoading() }
        web.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        var ready = false
        for _ in 0..<150 {
            try Task.checkCancellation()
            if navigation.failed { throw RenderError.unavailable }
            if navigation.finished,
                (try? await web.evaluateJavaScript("document.readyState === 'complete' && typeof renderDocumentContent === 'function'"))
                    as? Bool == true
            {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { throw RenderError.unavailable }
        let raw = try await web.callAsyncJavaScript(
            "return await window.renderDocumentContent(input)",
            arguments: [
                "input": [
                    "kind": key.content.kind.rawValue, "source": key.content.source,
                    "width": width, "fontSize": key.fontSize, "dark": key.dark,
                ]
            ],
            in: nil, contentWorld: .page)
        try Task.checkCancellation()
        guard let dimensions = raw as? [String: NSNumber],
            let measuredWidth = dimensions["width"]?.doubleValue, let measuredHeight = dimensions["height"]?.doubleValue,
            let baseline = dimensions["baseline"]?.doubleValue,
            measuredWidth > 0, measuredHeight > 0, measuredWidth <= 4096, measuredHeight <= 4096
        else { throw RenderError.tooLarge }
        web.frame.size = CGSize(width: max(width, measuredWidth), height: measuredHeight)
        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = CGRect(x: 0, y: 0, width: measuredWidth, height: measuredHeight)
        snapshot.snapshotWidth = NSNumber(value: min(measuredWidth * 2, 4096))
        let image = try await web.takeSnapshot(configuration: snapshot)
        try Task.checkCancellation()
        let scale = min(1, width / measuredWidth)
        let result = RenderedContentImage(
            image: image, size: CGSize(width: measuredWidth * scale, height: measuredHeight * scale), baseline: baseline * scale,
            selectionBounds: CGRect(
                x: (dimensions["contentX"]?.doubleValue ?? 0) * scale, y: 0,
                width: (dimensions["contentWidth"]?.doubleValue ?? measuredWidth) * scale, height: measuredHeight * scale))
        cache[key] = result
        cacheOrder.append(key)
        while cacheOrder.count > 32 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        return result
    }
}

/// Immutable attachment geometry; replacing it invalidates display without changing source.
final class RenderedContentAttachment: NSTextAttachment {
    let content: RenderedContent
    @MainActor init(content: RenderedContent, size: CGSize? = nil, baseline: CGFloat? = nil) {
        self.content = content
        let size = size ?? CGSize(width: content.isBlock ? 280 : 72, height: content.isBlock ? 72 : 24)
        let baseline = baseline ?? (content.isBlock ? size.height : size.height - 5)
        super.init(data: nil, ofType: nil)
        bounds = CGRect(x: 0, y: baseline - size.height, width: size.width, height: size.height)
        #if os(macOS)
            attachmentCell = RenderedContentCell(size: size, baseline: baseline)
        #endif
    }
    required init?(coder: NSCoder) { nil }
}

#if os(macOS)
    private final class RenderedContentCell: NSTextAttachmentCell {
        nonisolated let size: CGSize
        nonisolated let baseline: CGFloat
        init(size: CGSize, baseline: CGFloat) {
            self.size = size
            self.baseline = baseline
            super.init(textCell: "")
        }
        required init(coder: NSCoder) {
            size = .zero
            baseline = 0
            super.init(coder: coder)
        }
        nonisolated override func cellSize() -> NSSize { size }
        nonisolated override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: baseline - size.height) }
        override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}

    }
#endif

@Observable @MainActor
final class RenderedContentModel {
    var content: RenderedContent
    var width: CGFloat = 300
    var fontSize: CGFloat = 18
    var result: RenderedContentImage?
    var error: String?
    var onRender: (RenderedContentImage) -> Void = { _ in }
    var onChange: (RenderedContent, String) -> Void = { _, _ in }
    var onDismiss: () -> Void = {}
    var onSelect: () -> Void = {}
    var isSelected = false
    var isRangeSelection = false
    var isSelectionEmphasized = true
    init(content: RenderedContent) { self.content = content }
}

struct RenderedContentView: View {
    @Bindable var model: RenderedContentModel
    @Environment(\.colorScheme) private var colorScheme
    #if os(macOS)
        @Environment(\.controlActiveState) private var controlActiveState
    #endif
    @State private var editingContent: RenderedContent?
    @State private var editingFormula: RenderedContent?

    private func beginEditing() {
        model.onSelect()
        if model.content.kind == .mermaid {
            editingContent = model.content
        } else {
            editingFormula = model.content
        }
    }
    private var selectionColor: Color {
        #if os(macOS)
            Color(
                nsColor: controlActiveState == .inactive
                    || (!model.isSelectionEmphasized && editingFormula == nil && editingContent == nil)
                    ? .unemphasizedSelectedTextBackgroundColor : .selectedTextBackgroundColor)
        #else
            Color.accentColor.opacity(0.22)
        #endif
    }

    var body: some View {
        Button {
            beginEditing()
        } label: {
            Group {
                if let result = model.result {
                    if model.content.kind == .mermaid {
                        DiagramPreview(result: result, onClick: beginEditing)
                    } else {
                        RenderedContentImageView(result: result)
                    }
                } else if model.error != nil {
                    Label("rendered.failed", systemImage: "exclamationmark.triangle").font(.caption)
                } else {
                    ProgressView().controlSize(.small)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(.rect)
        }
        .buttonStyle(.plain)
        #if os(macOS)
            .background {
                if model.isSelected && !model.isRangeSelection {
                    // Native attachment selection extends a device pixel beyond
                    // the attachment. Cover that fringe without changing hit or
                    // layout geometry; the tight highlight is drawn above pixels.
                    Color(nsColor: .textBackgroundColor).padding(.horizontal, -1)
                }
            }
        #endif
        .overlay {
            if model.isSelected || editingFormula != nil || editingContent != nil {
                GeometryReader { geometry in
                    let fullBounds = CGRect(origin: .zero, size: model.result?.size ?? geometry.size)
                    let bounds = model.isRangeSelection ? fullBounds : (model.result?.selectionBounds ?? fullBounds)
                    let scale = geometry.size.width / max(1, model.result?.size.width ?? geometry.size.width)
                    RoundedRectangle(cornerRadius: model.isRangeSelection ? 0 : 4)
                        .fill(selectionColor)
                        .blendMode(colorScheme == .dark ? .screen : .multiply)
                        .frame(width: bounds.width * scale, height: geometry.size.height)
                        .offset(x: bounds.minX * scale)
                        .allowsHitTesting(false)
                }
            }
        }
        .accessibilityLabel(Text(model.content.kind == .mermaid ? "rendered.mermaid" : "rendered.math"))
        .accessibilityValue(model.content.source)
        .help("rendered.edit")
        #if os(macOS)
            .background(PointingHandRegion())
            .accessibilityAction(named: Text("rendered.edit")) { beginEditing() }
        #endif
        .task(id: RenderedContentKey(content: model.content, width: Int(model.width), fontSize: model.fontSize, dark: colorScheme == .dark))
        {
            let key = RenderedContentKey(
                content: model.content, width: Int(model.width), fontSize: model.fontSize, dark: colorScheme == .dark)
            model.result = nil
            model.error = nil
            do {
                let result = try await DocumentContentRenderer.shared.render(key)
                try Task.checkCancellation()
                guard model.content == key.content else { return }
                model.result = result
                model.onRender(result)
            } catch is CancellationError {
                // Removed/replaced attachments must never write an obsolete layout back.
            } catch {
                guard !Task.isCancelled, model.content == key.content else { return }
                model.error = error.localizedDescription
            }
        }
        .popover(item: $editingFormula, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { original in
            FormulaSourcePopover(content: original, model: model)
        }
        .sheet(
            item: $editingContent, onDismiss: { model.onDismiss() },
            content: { original in
                RenderedContentSourceEditor(content: original) { source in
                    model.onChange(original, source)
                }
            })
    }
}

@MainActor
final class RenderedContentOverlayController {
    @MainActor private final class Entry {
        let model: RenderedContentModel
        #if os(macOS)
            let host: NSHostingView<RenderedContentView>
        #else
            let host: UIHostingController<RenderedContentView>
        #endif
        init(content: RenderedContent) {
            model = RenderedContentModel(content: content)
            #if os(macOS)
                host = NSHostingView(rootView: RenderedContentView(model: model))
            #else
                host = UIHostingController(rootView: RenderedContentView(model: model))
                host.view.backgroundColor = .clear
            #endif
        }
    }
    private var entries: [UUID: Entry] = [:]
    private var refreshing = false

    func updateSelectionEmphasis(_ emphasized: Bool) {
        for entry in entries.values { entry.model.isSelectionEmphasized = emphasized }
    }

    func updateSelection(in view: PlatformTextView, tracking: Bool = false) {
        #if os(macOS)
            guard let storage = view.textStorage else { return }
            let selection = view.selectedRange()
        #else
            let storage = view.textStorage
            let selection = view.selectedRange
        #endif
        var selected: Set<UUID> = []
        if selection.length > 0, NSMaxRange(selection) <= storage.length {
            storage.enumerateAttribute(.yoursRenderedContent, in: selection) { value, _, _ in
                if let data = value as? Data, let content = try? JSONDecoder().decode(RenderedContent.self, from: data) {
                    selected.insert(content.id)
                }
            }
        }
        for (id, entry) in entries {
            let isSelected = selected.contains(id)
            let isRangeSelection = selection.length > 1
            guard tracking || entry.model.isSelected != isSelected || entry.model.isRangeSelection != isRangeSelection else { continue }
            entry.model.isSelected = isSelected
            entry.model.isRangeSelection = isRangeSelection
            #if os(macOS)
                if tracking && entry.host.frame.intersects(view.visibleRect) {
                    // NSTextView tracks the mouse in a nested event loop. Flush
                    // the changed hosting view rather than waiting for mouse-up.
                    entry.host.needsLayout = true
                    entry.host.layoutSubtreeIfNeeded()
                    entry.host.displayIfNeeded()
                }
            #endif
        }
    }

    func refresh(in view: PlatformTextView, onChange: @escaping (RenderedContent, String) -> Void) {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        #if os(macOS)
            guard let storage = view.textStorage, let layout = view.layoutManager, let container = view.textContainer else { return }
            let origin = view.textContainerOrigin
        #else
            let storage = view.textStorage
            let layout = view.layoutManager
            let container = view.textContainer
            let origin = CGPoint(x: view.textContainerInset.left, y: view.textContainerInset.top)
        #endif
        var valid: Set<UUID> = []
        storage.enumerateAttribute(.yoursRenderedContent, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard range.length == 1, let data = value as? Data,
                let content = try? JSONDecoder().decode(RenderedContent.self, from: data), !valid.contains(content.id)
            else { return }
            valid.insert(content.id)
            let entry = entries[content.id] ?? Entry(content: content)
            if entries[content.id] == nil {
                entries[content.id] = entry
                #if os(macOS)
                    view.addSubview(entry.host)
                #else
                    view.addSubview(entry.host.view)
                #endif
            }
            entry.model.content = content
            entry.model.width = max(80, container.size.width - 2 * container.lineFragmentPadding)
            entry.model.fontSize = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont)?.pointSize ?? 18
            entry.model.onChange = onChange
            entry.model.onSelect = { [weak view] in
                guard let view else { return }
                var selected: NSRange?
                storage.enumerateAttribute(.yoursRenderedContent, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                    if (value as? Data) == data {
                        selected = range
                        stop.pointee = true
                    }
                }
                guard let selected else { return }
                #if os(macOS)
                    view.window?.makeFirstResponder(view)
                    view.setSelectedRange(selected)
                #else
                    view.selectedRange = selected
                #endif
            }
            entry.model.onDismiss = { [weak view, weak entry] in
                guard let view, let entry else { return }
                #if os(macOS)
                    guard let window = view.window, entry.host.superview === view else { return }
                    window.makeFirstResponder(view)
                #else
                    guard view.window != nil, entry.host.view.superview === view else { return }
                    view.becomeFirstResponder()
                #endif
            }
            entry.model.onRender = { [weak self, weak view, weak entry] result in
                guard let self, let view, let entry, self.entries[content.id] === entry, entry.model.content == content else { return }
                // Resolve the current position after async rendering; prior ranges can be stale.
                var target: NSRange?
                storage.enumerateAttribute(.yoursRenderedContent, in: NSRange(location: 0, length: storage.length)) {
                    current, candidate, stop in
                    if (current as? Data) == data {
                        target = candidate
                        stop.pointee = true
                    }
                }
                guard let target, target.length == 1 else { return }
                storage.addAttribute(
                    .attachment, value: RenderedContentAttachment(content: content, size: result.size, baseline: result.baseline),
                    range: target)
                layout.invalidateLayout(forCharacterRange: target, actualCharacterRange: nil)
                self.refresh(in: view, onChange: onChange)
            }
            if let result = entry.model.result,
                let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? RenderedContentAttachment,
                attachment.bounds.size != result.size
            {
                storage.addAttribute(
                    .attachment, value: RenderedContentAttachment(content: content, size: result.size, baseline: result.baseline),
                    range: range)
                layout.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let frame = rect.offsetBy(dx: origin.x, dy: origin.y)
            #if os(macOS)
                if entry.host.frame != frame { entry.host.frame = frame }
            #else
                if entry.host.view.frame != frame { entry.host.view.frame = frame }
            #endif
        }
        for id in Set(entries.keys).subtracting(valid) {
            #if os(macOS)
                entries[id]?.host.removeFromSuperview()
            #else
                entries[id]?.host.view.removeFromSuperview()
            #endif
            entries.removeValue(forKey: id)
        }
        // Undo can restore selected attachments after the selection notification.
        // Newly created hosts must inherit that selection immediately.
        updateSelection(in: view)
        #if os(macOS)
            updateSelectionEmphasis(view.window?.firstResponder === view)
        #endif
    }
}
