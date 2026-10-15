import SwiftUI

struct EditorControlItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let action: EditorAction
    var enabled = true
    var active = false
    var mixed = false
}

@MainActor @Observable
final class EditorControlsState {
    var commands: [EditorCommand] = []
    var items: [EditorControlItem] = []
    var highlighted = 0
    var maximumMenuHeight: CGFloat = 300
    var isSlash = false
    var paragraphExpanded = false
    var paragraphHighlight = 0
    var detail: String?
    var address = ""
    var rows = 3
    var columns = 3
    var choose: (EditorAction) -> Void = { _ in }
    var cancel: () -> Void = {}
    var detailChanged: () -> Void = {}

    var paragraphItems: [EditorControlItem] { items.filter { $0.id.hasPrefix("paragraph-") } }

    func toggleParagraphMenu() {
        paragraphExpanded.toggle()
        paragraphHighlight = paragraphItems.firstIndex(where: \.active) ?? 0
        detailChanged()
    }

    func handleParagraphKey(_ key: String) -> Bool {
        guard paragraphExpanded else { return false }
        if key == "escape" || key == "tab" {
            paragraphExpanded = false
            detailChanged()
            return key == "escape"
        }
        let available = paragraphItems.indices.filter { paragraphItems[$0].enabled }
        if key == "up" || key == "down" {
            guard !available.isEmpty else { return true }
            let current = available.firstIndex(of: paragraphHighlight) ?? 0
            paragraphHighlight = available[(current + (key == "up" ? available.count - 1 : 1)) % available.count]
            return true
        }
        if key == "return" {
            guard paragraphItems.indices.contains(paragraphHighlight), paragraphItems[paragraphHighlight].enabled else { return true }
            let action = paragraphItems[paragraphHighlight].action
            paragraphExpanded = false
            choose(action)
            return true
        }
        return false
    }

    func open(_ detail: String) {
        paragraphExpanded = false
        self.detail = detail
        detailChanged()
    }
}

@MainActor
private enum ParagraphControlIcon {
    static func image(for action: EditorAction?, symbol: String) -> Image {
        if case .paragraph(let style) = action,
            style.hasPrefix("heading:"), let level = Int(style.dropFirst("heading:".count)),
            (1...6).contains(level)
        {
            #if SWIFT_PACKAGE
                let bundle = Bundle.module
            #else
                let bundle = Bundle.main
            #endif
            return Image("heading-\(level)", bundle: bundle).renderingMode(.template)
        }
        return Image(systemName: symbol)
    }
}

#if os(macOS)
    private struct SelectionSurface: ViewModifier {
        var cornerRadius: CGFloat
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.colorSchemeContrast) private var contrast

        func body(content: Content) -> some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay {
                    shape.strokeBorder(
                        Color.primary.opacity(contrast == .increased ? 0.35 : 0.12), lineWidth: 0.5
                    ).allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 3, y: 2)
        }
    }
#endif

private struct EditorControlsView: View {
    @Bindable var state: EditorControlsState
    @State private var hoveredControl: String?
    private var isSelectionToolbar: Bool { !state.isSlash && state.detail == nil }

    var body: some View {
        #if os(macOS)
            if isSelectionToolbar {
                VStack(alignment: .leading, spacing: 4) {
                    selectionToolbar.padding(3)
                        .modifier(SelectionSurface(cornerRadius: 16))
                    if state.paragraphExpanded { paragraphMenu }
                }
                .fixedSize()
                .padding(8)  // Leave room for the surface shadow inside the transparent panel.
            } else {
                standardPanel
            }
        #else
            standardPanel
        #endif
    }

    private var standardPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.detail == "link" {
                linkEditor
            } else if state.detail == "table" {
                tableEditor
            } else if state.isSlash {
                slashMenu
            } else {
                selectionToolbar
            }
        }
        #if os(iOS)
            .buttonStyle(EditorTouchButtonStyle())
        #endif
        .padding(isSelectionToolbar ? 3 : 8)
        #if os(macOS)
            .glassEffect(.regular, in: .rect(cornerRadius: 12))
        #endif
        .fixedSize(horizontal: false, vertical: true)
        #if os(macOS)
            .onExitCommand {
                if state.detail != nil {
                    state.detail = nil
                    state.detailChanged()
                } else {
                    state.cancel()
                }
            }
        #endif
    }

    private var slashMenu: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if state.commands.isEmpty {
                        Text("editor.no_results").foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(Array(state.commands.enumerated()), id: \.element.id) { index, command in
                        if index == 0 || state.commands[index - 1].category != command.category {
                            Text(L10n.string(String.LocalizationValue(command.category))).font(.caption).foregroundStyle(.secondary)
                                .padding(.top, 5)
                        }
                        Button {
                            if command.id == "table" { state.open("table") } else { state.choose(command.action) }
                        } label: {
                            Label {
                                Text(command.title)
                            } icon: {
                                ParagraphControlIcon.image(for: command.action, symbol: command.symbol)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7).padding(.horizontal, 6)
                            #if os(iOS)
                                .frame(minHeight: 44)
                            #endif
                            .background(
                                index == state.highlighted ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        #if os(macOS)
                            .background(PointingHandRegion())
                        #endif
                        .accessibilityIdentifier("slash-command-" + command.id)
                        .id(command.id)
                    }
                }
            }
            .frame(width: 264, height: min(state.maximumMenuHeight, CGFloat(max(1, state.commands.count)) * 44 + 35))
            .onChange(of: state.highlighted) { _, index in
                if state.commands.indices.contains(index) { proxy.scrollTo(state.commands[index].id) }
            }
        }
        .accessibilityIdentifier("slash-menu")
    }

    private var paragraphItems: [EditorControlItem] {
        state.items.filter { $0.id.hasPrefix("paragraph-") }
    }

    private var selectionToolbar: some View {
        HStack(spacing: 2) {
            Button {
                state.toggleParagraphMenu()
            } label: {
                let selected = paragraphItems.first(where: \.active)
                HStack(spacing: 3) {
                    ParagraphControlIcon.image(for: selected?.action, symbol: selected?.symbol ?? "textformat")
                        .frame(width: 16, height: 16)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .frame(width: 36, height: 26)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .frame(height: 26)
            .help(paragraphItems.first(where: \.active)?.title ?? L10n.string("editor.mixed"))
            .accessibilityLabel("format.menu")
            .accessibilityValue(paragraphItems.first(where: \.active)?.title ?? L10n.string("editor.mixed"))
            .accessibilityIdentifier("selection-style")
            .background(
                (hoveredControl == "style" || state.paragraphExpanded) ? Color.primary.opacity(0.07) : .clear,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 13, bottomLeadingRadius: 13, bottomTrailingRadius: 6, topTrailingRadius: 6)
            )
            .onHover { hoveredControl = $0 ? "style" : nil }
            #if os(macOS)
                .background(PointingHandRegion())
            #endif
            Divider().frame(height: 14).padding(.horizontal, 2)
            ForEach(state.items.filter { ["bold", "italic", "underline", "strike", "inline-code"].contains($0.id) }) { item in
                toolbarButton(item)
            }
            Divider().frame(height: 14).padding(.horizontal, 2)
            ForEach(state.items.filter { ["link", "quote"].contains($0.id) }) { item in
                toolbarButton(item, trailingCornerRadius: item.id == "quote" ? 13 : 6)
            }
        }
        .font(.system(size: 12))
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private var paragraphMenu: some View {
        VStack(spacing: 0) {
            ForEach(Array(paragraphItems.enumerated()), id: \.element.id) { index, item in
                if index == 1 || item.id == "paragraph-bullet" || item.id == "paragraph-code" {
                    Divider().padding(.horizontal, 6).padding(.vertical, 4)
                }
                Button {
                    state.paragraphExpanded = false
                    state.choose(item.action)
                } label: {
                    HStack(spacing: 8) {
                        ParagraphControlIcon.image(for: item.action, symbol: item.symbol)
                            .frame(width: 16, height: 16)
                        Text(item.title)
                        Spacer(minLength: 8)
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(item.active ? 1 : 0)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 8).frame(height: 24)
                    .contentShape(.rect)
                    .background(state.paragraphHighlight == index ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(!item.enabled)
                .onHover { if $0 && item.enabled { state.paragraphHighlight = index } }
                #if os(macOS)
                    .background(PointingHandRegion())
                #endif
                .accessibilityLabel(item.title)
                .accessibilityValue(item.active ? L10n.string("editor.enabled") : "")
                .accessibilityIdentifier("selection-" + item.id)
            }
        }
        .padding(4).frame(width: 152)
        #if os(macOS)
            .modifier(SelectionSurface(cornerRadius: 9))
        #endif
        .accessibilityElement(children: .contain)
    }

    private func toolbarButton(_ item: EditorControlItem, trailingCornerRadius: CGFloat = 6) -> some View {
        Button {
            if item.id == "link" { state.open("link") } else { state.choose(item.action) }
        } label: {
            Image(systemName: item.symbol)
                .foregroundStyle(item.enabled && item.active ? Color.accentColor : Color.primary)
                .opacity(item.enabled ? 1 : 0.3)
                .frame(width: 26, height: 26)
                .background(
                    hoveredControl == item.id && item.enabled ? Color.primary.opacity(0.07) : .clear,
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 6, bottomLeadingRadius: 6,
                        bottomTrailingRadius: trailingCornerRadius, topTrailingRadius: trailingCornerRadius)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hoveredControl = $0 && item.enabled ? item.id : nil }
        #if os(macOS)
            .background { PointingHandRegion(cursor: item.enabled ? .pointingHand : .operationNotAllowed) }
        #endif
        .disabled(!item.enabled).help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.mixed ? L10n.string("editor.mixed") : item.active ? L10n.string("editor.enabled") : "")
        .accessibilityIdentifier("selection-" + item.id)
    }

    private var linkEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("link.add_or_edit").font(.headline)
            TextField("https://", text: $state.address).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("link-address")
            HStack {
                Button("link.remove") { state.choose(.link(nil)) }
                Spacer()
                Button("common.cancel") {
                    state.detail = nil
                    state.detailChanged()
                }.accessibilityIdentifier("link-cancel")
                Button("common.apply") { if let url = validURL { state.choose(.link(url)) } }
                    .disabled(validURL == nil).accessibilityIdentifier("link-apply")
            }
        }.frame(width: 310)
    }

    private var validURL: URL? {
        guard let url = URL(string: state.address.trimmingCharacters(in: .whitespacesAndNewlines)),
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        return url
    }

    private var tableEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("table.insert").font(.headline)
            Stepper("\(L10n.string("editor.rows")): \(state.rows)", value: $state.rows, in: 1...8)
            Stepper("\(L10n.string("editor.columns")): \(state.columns)", value: $state.columns, in: 1...8)
            HStack {
                Button("common.cancel") {
                    state.detail = nil
                    state.detailChanged()
                }.accessibilityIdentifier("table-cancel")
                Spacer()
                Button("table.insert") { state.choose(.table(rows: state.rows, columns: state.columns)) }
                    .accessibilityIdentifier("table-apply")
            }
        }.frame(width: 264)
    }
}

#if os(macOS)
    import AppKit

    @MainActor
    final class NativeEditorControls: NSObject {
        private final class Panel: NSPanel {
            var acceptsKeyboard = false
            override var canBecomeKey: Bool { acceptsKeyboard }
            override var canBecomeMain: Bool { false }
        }
        let state = EditorControlsState()
        private var panel: Panel?
        private var outsideClickMonitor: Any?
        private weak var editor: NSTextView?
        var isShowing: Bool { panel?.isVisible == true }
        var hasDetail: Bool { state.detail != nil }

        func show(in editor: NSTextView, range: NSRange) {
            guard let window = editor.window, window.isKeyWindow || panel?.isKeyWindow == true else {
                close()
                return
            }
            self.editor = editor
            if outsideClickMonitor == nil {
                outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                    // AppKit dispatches local event monitors on the main thread.
                    MainActor.assumeIsolated {
                        if let self, self.state.paragraphExpanded, event.window !== self.panel {
                            self.state.paragraphExpanded = false
                            self.state.detailChanged()
                        }
                    }
                    return event
                }
            }
            if panel == nil {
                let panel = Panel(
                    contentRect: .zero, styleMask: [.nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
                panel.isFloatingPanel = true
                panel.hidesOnDeactivate = true
                panel.isReleasedWhenClosed = false
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = true
                let hosting = NSHostingView(
                    rootView: EditorControlsView(state: state))
                panel.contentView = hosting
                self.panel = panel
                NotificationCenter.default.addObserver(
                    self, selector: #selector(applicationResigned), name: NSApplication.didResignActiveNotification, object: nil)
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowResigned(_:)), name: NSWindow.didResignKeyNotification, object: window)
            }
            guard let panel else { return }
            panel.appearance = editor.effectiveAppearance
            panel.hasShadow = state.isSlash || state.detail != nil
            let start = editor.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
            let end = editor.firstRect(
                forCharacterRange: NSRange(location: range.length > 0 ? NSMaxRange(range) - 1 : range.location, length: 0),
                actualRange: nil)
            let screen = start.union(end)
            let visible = window.convertToScreen(editor.convert(editor.visibleRect, to: nil))
            guard visible.intersects(screen) else {
                close()
                return
            }
            panel.contentView?.layoutSubtreeIfNeeded()
            let size = panel.contentView?.fittingSize ?? CGSize(width: 280, height: 300)
            // Align to the selection's beginning, below its last line, including wrapped selections.
            let surfaceInset: CGFloat = state.isSlash || state.detail != nil ? 0 : 8
            var origin = CGPoint(x: start.minX - surfaceInset, y: screen.minY - size.height - 8 + surfaceInset)
            if origin.y < visible.minY { origin.y = screen.maxY + 8 - surfaceInset }
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
            panel.setFrame(CGRect(origin: origin, size: size), display: true)
            if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
            panel.orderFront(nil)
            state.detailChanged = { [weak self] in
                guard let self, let editor = self.editor else { return }
                self.panel?.acceptsKeyboard = self.hasDetail
                self.show(in: editor, range: range)
                if self.hasDetail {
                    self.panel?.makeKey()
                } else {
                    editor.window?.makeKey()
                    editor.window?.makeFirstResponder(editor)
                }
            }
        }

        @objc private func windowResigned(_ notification: Notification) {
            // Opening the address editor transfers key status within this editing session.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.editor?.window?.isKeyWindow != true, self.panel?.isKeyWindow != true else { return }
                self.close()
            }
        }

        @objc private func applicationResigned() { close() }

        func close() {
            if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
            outsideClickMonitor = nil
            state.paragraphExpanded = false
            if let panel { panel.parent?.removeChildWindow(panel) }
            panel?.orderOut(nil)
            state.detail = nil
            panel?.acceptsKeyboard = false
        }
    }
#else
    import UIKit

    private struct EditorTouchButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
                .opacity(configuration.isPressed ? 0.55 : 1)
        }
    }

    @MainActor
    final class NativeEditorControls {
        let state = EditorControlsState()
        private var hosting: UIHostingController<EditorControlsView>?
        private weak var editor: UITextView?
        var isShowing: Bool { hosting?.view.superview != nil }
        var hasDetail: Bool { state.detail != nil }

        func show(in editor: UITextView, range: NSRange) {
            guard editor.isFirstResponder else {
                close()
                return
            }
            self.editor = editor
            if hosting == nil { hosting = UIHostingController(rootView: EditorControlsView(state: state)) }
            guard let hosting else { return }
            hosting.view.backgroundColor = .secondarySystemBackground
            // The scroll viewport and accessory must share a height budget. Measuring
            // the root also accounts for parameter controls and Dynamic Type.
            state.maximumMenuHeight = min(220, max(88, (editor.window?.bounds.height ?? 600) * 0.28))
            let width = max(280, editor.bounds.width)
            let size = hosting.sizeThatFits(in: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
            let previousHeight = hosting.view.frame.height
            hosting.view.frame = CGRect(x: 0, y: 0, width: width, height: max(44, size.height))
            if editor.inputAccessoryView !== hosting.view || abs(previousHeight - hosting.view.frame.height) > 0.5 {
                editor.inputAccessoryView = hosting.view
                editor.reloadInputViews()
            }
            state.detailChanged = { [weak self] in self?.show(in: editor, range: range) }
        }
        func showDetail(in editor: UITextView) {
            self.editor = editor
            let controller = UIHostingController(rootView: EditorControlsView(state: state))
            controller.modalPresentationStyle = .pageSheet
            controller.sheetPresentationController?.detents = [.medium()]
            var presenter = editor.window?.rootViewController
            while let next = presenter?.presentedViewController { presenter = next }
            detailController = controller
            state.detailChanged = { [weak self] in self?.close() }
            presenter?.present(controller, animated: true)
        }
        private weak var detailController: UIViewController?
        func close() {
            detailController?.dismiss(animated: true)
            if editor?.inputAccessoryView === hosting?.view {
                editor?.inputAccessoryView = nil
                editor?.reloadInputViews()
            }
            state.detail = nil
        }
    }
#endif
