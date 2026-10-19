import SwiftUI

/// A sheet owns a draft; preview work never edits the document or registers undo.
@Observable @MainActor
final class RenderedContentDraft {
    let original: RenderedContent
    var source: String
    var result: RenderedContentImage?
    var error: String?
    var isRendering = false
    private var generation = 0

    init(content: RenderedContent) {
        original = content
        source = content.source
    }

    func preview(dark: Bool, width: Int = 640, fontSize: CGFloat = 22) async {
        generation += 1
        let current = generation
        var content = original
        content.source = source
        isRendering = true
        error = nil
        defer { if generation == current { isRendering = false } }
        do {
            try await Task.sleep(for: .milliseconds(250))
            let rendered = try await DocumentContentRenderer.shared.render(
                RenderedContentKey(content: content, width: width, fontSize: fontSize, dark: dark))
            try Task.checkCancellation()
            guard generation == current, source == content.source else { return }
            result = rendered
        } catch is CancellationError {
            // A newer keystroke or dismissal superseded this draft preview.
        } catch {
            guard !Task.isCancelled, generation == current, source == content.source else { return }
            let detail = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            self.error = String(detail.prefix(600))
        }
    }
}

/// Formula drafts update only disposable document pixels until the popover closes.
struct FormulaSourcePopover: View {
    @State private var draft: RenderedContentDraft
    let model: RenderedContentModel
    @State private var originalResult: RenderedContentImage?
    @State private var originalError: String?
    @State private var cancelled = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(content: RenderedContent, model: RenderedContentModel) {
        _draft = State(initialValue: RenderedContentDraft(content: content))
        self.model = model
        _originalResult = State(initialValue: model.result)
        _originalError = State(initialValue: model.error)
    }

    private var key: RenderedContentKey {
        var content = draft.original
        content.source = draft.source
        return RenderedContentKey(content: content, width: Int(model.width), fontSize: model.fontSize, dark: colorScheme == .dark)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SourceCodeEditor(
                source: $draft.source, kind: draft.original.kind,
                onCancel: {
                    cancelled = true
                    dismiss()
                }, onSubmit: { dismiss() }
            )
            .frame(height: 92)
            if let error = draft.error {
                Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .padding(.horizontal, 12).padding(.bottom, 12)
                    .accessibilityIdentifier("rendered-preview-error")
            }
        }
        .background(.background)
        .frame(width: 380)
        .presentationCompactAdaptation(.popover)
        #if os(macOS)
            .background {
                // NSPopover handles Escape before NSTextView's responder callbacks.
                // Keep its cancel shortcut registered without adding a visible control.
                Button("rendered.cancel") {
                    cancelled = true
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        #endif
        .task(id: key) {
            await draft.preview(dark: key.dark, width: key.width, fontSize: key.fontSize)
            guard !Task.isCancelled, !cancelled, let result = draft.result, draft.error == nil else { return }
            model.result = result
            model.onRender(result)
        }
        .onDisappear {
            if cancelled {
                model.result = originalResult
                model.error = originalError
                if let originalResult { model.onRender(originalResult) }
            } else {
                model.onChange(draft.original, draft.source)
            }
            model.onDismiss()
        }
    }
}

struct RenderedContentSourceEditor: View {
    let onApply: (String) -> Void
    @State private var draft: RenderedContentDraft
    @State private var cancelled = false
    @State private var completed = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(content: RenderedContent, onApply: @escaping (String) -> Void) {
        _draft = State(initialValue: RenderedContentDraft(content: content))
        self.onApply = onApply
    }

    private var isDiagram: Bool { draft.original.kind == .mermaid }
    private var previewKey: RenderedContentKey {
        var content = draft.original
        content.source = draft.source
        return RenderedContentKey(content: content, width: 640, fontSize: 22, dark: colorScheme == .dark)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                if isDiagram && geometry.size.width >= 700 {
                    HStack(alignment: .top, spacing: 0) {
                        sourcePanel.frame(width: geometry.size.width * 0.44)
                        Divider()
                        previewPanel
                    }
                } else {
                    VStack(spacing: 16) {
                        previewPanel.frame(height: geometry.size.height * (isDiagram ? 0.48 : 0.42))
                        sourcePanel
                    }
                }
            }
            if let error = draft.error {
                VStack(alignment: .leading, spacing: 4) {
                    Label("rendered.preview_error", systemImage: "exclamationmark.triangle").font(.callout.weight(.medium))
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                }
                .accessibilityIdentifier("rendered-preview-error")
            }

        }
        #if os(macOS)
            .frame(width: isDiagram ? 900 : 560, height: isDiagram ? 580 : 440)
            .background(SheetOutsideClickObserver { dismiss() })
            .background {
                Button("rendered.cancel") { cancel() }
                .keyboardShortcut(.cancelAction)
                .hidden().frame(width: 0, height: 0).accessibilityHidden(true)
                Button("rendered.apply") { dismiss() }
                .keyboardShortcut(.return, modifiers: .command)
                .hidden().frame(width: 0, height: 0).accessibilityHidden(true)
            }
        #else
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .presentationDetents([.large])
        #endif
        .task(id: previewKey) { await draft.preview(dark: colorScheme == .dark) }
        .onDisappear {
            guard !completed else { return }
            completed = true
            if !cancelled, draft.source != draft.original.source { onApply(draft.source) }
        }
    }

    private func cancel() {
        cancelled = true
        dismiss()
    }

    private var sourcePanel: some View {
        SourceCodeEditor(source: $draft.source, kind: draft.original.kind, onCancel: cancel, onSubmit: { dismiss() })
    }

    private var previewPanel: some View {
        Group {
            if let result = draft.result {
                DiagramPreview(result: result)
            } else {
                Text(draft.error == nil ? "rendered.rendering" : "rendered.preview_empty")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(.background)
        .accessibilityLabel(Text("rendered.preview"))
        .accessibilityIdentifier("rendered-live-preview")
    }
}

/// Magnification belongs to the viewport, never to the persisted attachment size.
struct DiagramPreview: View {
    let result: RenderedContentImage
    var onClick: (() -> Void)?
    #if !os(macOS)
        @State private var zoom: CGFloat = 1
        @GestureState private var magnification: CGFloat = 1
    #endif

    var body: some View {
        #if os(macOS)
            NativeDiagramPreview(result: result, onClick: onClick)
        #else
            GeometryReader { geometry in
                let fit = min(geometry.size.width / result.size.width, geometry.size.height / result.size.height)
                let scale = fit * min(4, max(0.5, zoom * magnification))
                ScrollView([.horizontal, .vertical]) {
                    RenderedContentImageView(result: result)
                        .frame(width: result.size.width * scale, height: result.size.height * scale)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($magnification) { value, state, _ in state = value.magnification }
                        .onEnded { value in zoom = min(4, max(0.5, zoom * value.magnification)) }
                )
                .onTapGesture { onClick?() }
            }
        #endif
    }
}

#if os(macOS)
    private struct NativeDiagramPreview: NSViewRepresentable {
        let result: RenderedContentImage
        var onClick: (() -> Void)?

        func makeNSView(context: Context) -> DiagramScrollView {
            let view = DiagramScrollView()
            view.borderType = .noBorder
            view.drawsBackground = false
            view.hasHorizontalScroller = true
            view.hasVerticalScroller = true
            view.autohidesScrollers = true
            view.allowsMagnification = true
            view.minMagnification = 0.5
            view.maxMagnification = 4
            view.documentView = view.imageView
            view.imageView.imageScaling = .scaleProportionallyUpOrDown
            view.imageView.imageAlignment = .alignCenter
            view.addGestureRecognizer(NSClickGestureRecognizer(target: view, action: #selector(DiagramScrollView.openEditor)))
            return view
        }

        func updateNSView(_ view: DiagramScrollView, context: Context) {
            view.imageView.image = result.image
            view.onClick = onClick
        }
    }

    private final class DiagramScrollView: NSScrollView {
        let imageView = NSImageView()
        var onClick: (() -> Void)?
        private var viewportSize = CGSize.zero

        override func layout() {
            super.layout()
            // Keep the fitted canvas stable while the clip view magnifies it.
            let size = contentView.frame.size
            if viewportSize != size {
                viewportSize = size
                imageView.frame = CGRect(origin: .zero, size: size)
            }
        }

        @objc func openEditor() { onClick?() }

        override func scrollWheel(with event: NSEvent) {
            if onClick != nil && magnification <= 1 {
                nextResponder?.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }
#endif

struct RenderedContentImageView: View {
    let result: RenderedContentImage
    var body: some View {
        #if os(macOS)
            Image(nsImage: result.image).resizable().interpolation(.high)
        #else
            Image(uiImage: result.image).resizable().interpolation(.high)
        #endif
    }
}

#if os(macOS)
    /// Native sheets normally ignore their parent's clicks. Consume that click
    /// to finish this draft without also editing the document underneath.
    private struct SheetOutsideClickObserver: NSViewRepresentable {
        var onOutsideClick: () -> Void

        func makeNSView(context: Context) -> ObserverView {
            let view = ObserverView()
            view.onOutsideClick = onOutsideClick
            return view
        }

        func updateNSView(_ view: ObserverView, context: Context) { view.onOutsideClick = onOutsideClick }
        static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.stopObserving() }

        final class ObserverView: NSView {
            var onOutsideClick: (() -> Void)?
            private var monitor: Any?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                stopObserving()
                guard window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    guard let self, let sheet = self.window, let parent = sheet.sheetParent,
                        event.window === parent
                    else { return event }
                    self.onOutsideClick?()
                    return nil
                }
            }

            func stopObserving() {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
        }
    }
#endif
