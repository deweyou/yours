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
    var detail: String?
    var address = ""
    var rows = 3
    var columns = 3
    var choose: (EditorAction) -> Void = { _ in }
    var cancel: () -> Void = {}
    var detailChanged: () -> Void = {}

    func open(_ detail: String) {
        self.detail = detail
        detailChanged()
    }
}

private struct EditorControlsView: View {
    @Bindable var state: EditorControlsState

    var body: some View {
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
        .padding(8)
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
                            Label(command.title, systemImage: command.symbol)
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

    private var selectionToolbar: some View {
        HStack(spacing: 3) {
            Menu {
                ForEach(state.items.filter { $0.id.hasPrefix("paragraph-") }) { item in
                    Button(item.title) { state.choose(item.action) }.disabled(!item.enabled)
                }
            } label: {
                Image(systemName: "textformat.size")
            }
            .help("format.menu").accessibilityLabel("format.menu")
            .accessibilityIdentifier("selection-style")
            Divider().frame(height: 18)
            ForEach(state.items.filter { ["bold", "italic", "underline", "strike", "inline-code"].contains($0.id) }) { item in
                Button {
                    state.choose(item.action)
                } label: {
                    Image(systemName: item.symbol).frame(width: 26, height: 26)
                        .background(item.active ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                #if os(macOS)
                    .background { if item.enabled { PointingHandRegion() } }
                #endif
                .disabled(!item.enabled).help(item.title)
                .accessibilityLabel(item.title)
                .accessibilityValue(item.mixed ? L10n.string("editor.mixed") : item.active ? L10n.string("editor.enabled") : "")
                .accessibilityIdentifier("selection-" + item.id)
            }
            Button {
                state.open("link")
            } label: {
                Image(systemName: "link").frame(width: 26, height: 26)
            }
            .buttonStyle(.plain).disabled(!state.items.contains { $0.id == "link" && $0.enabled })
            .help("link.add_or_edit").accessibilityLabel("link.add_or_edit").accessibilityIdentifier("selection-link")
            Menu {
                ForEach(state.items.filter { ["quote", "indent", "outdent", "clear"].contains($0.id) }) { item in
                    Button(item.title) { state.choose(item.action) }.disabled(!item.enabled)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("editor.more")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityElement(children: .contain)
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
        private weak var editor: NSTextView?
        var isShowing: Bool { panel?.isVisible == true }
        var hasDetail: Bool { state.detail != nil }

        func show(in editor: NSTextView, range: NSRange) {
            guard let window = editor.window, window.isKeyWindow || panel?.isKeyWindow == true else {
                close()
                return
            }
            self.editor = editor
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
                    rootView: EditorControlsView(state: state).glassEffect(.regular, in: .rect(cornerRadius: 10)))
                panel.contentView = hosting
                self.panel = panel
                NotificationCenter.default.addObserver(
                    self, selector: #selector(applicationResigned), name: NSApplication.didResignActiveNotification, object: nil)
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowResigned(_:)), name: NSWindow.didResignKeyNotification, object: window)
            }
            guard let panel else { return }
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
            let size = panel.contentView?.fittingSize ?? CGSize(width: 280, height: 300)
            // Align to the selection's beginning, below its last line, including wrapped selections.
            var origin = CGPoint(x: start.minX, y: screen.minY - size.height - 5)
            if origin.y < visible.minY { origin.y = screen.maxY + 5 }
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
