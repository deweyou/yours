import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

struct WorkspaceView: View {
    @Bindable var store: NoteStore
    var body: some View {
        #if os(macOS)
            MacWorkspaceView(store: store)
        #else
            MobileWorkspaceView(store: store)
        #endif
    }
}

struct RecordCard: View {
    let note: Note
    @Environment(\.fontResolutionContext) private var fontContext
    #if os(macOS)
        @ScaledMetric private var minimumHeight = 120.0
        @ScaledMetric private var maximumHeight = 320.0
        private let cornerRadius: CGFloat = 12
    #else
        @ScaledMetric private var minimumHeight = 112.0
        @ScaledMetric private var maximumHeight = 280.0
        private let cornerRadius: CGFloat = 16
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Text(note.displayTitle).font(TitleTypography.card(in: fontContext)).lineLimit(2).layoutPriority(1)
                Spacer(minLength: 0)
            }
            Text(note.text.isEmpty ? L10n.string("note.body.empty") : String(note.text.prefix(600)))
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(note.updatedAt, format: .dateTime.month().day())
                .font(.caption).foregroundStyle(.secondary).layoutPriority(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: minimumHeight, maxHeight: maximumHeight, alignment: .top)
        .background(.background, in: RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct NoteEditorView: View {
    let note: Note
    @Bindable var store: NoteStore
    let saveError: String?
    let retrySave: () -> Void
    @FocusState private var isTitleFocused: Bool
    @FocusState private var isFocused: Bool
    @State private var commandBridge = EditorCommandBridge()
    @State private var selection = AttributedTextSelection()
    @State private var showsMarkdownHelp = false
    @State private var showsExport = false
    @State private var exportDocument = MarkdownFile(source: "")
    @State private var exportError: String?
    @State private var didCopyMarkdown = false
    @State private var bodyFocusRequest = 0
    @State private var toast = ToastPresenter()
    @Environment(\.undoManager) private var undoManager
    @Environment(\.fontResolutionContext) private var fontContext

    private var richText: AttributedString {
        store.notes.first(where: { $0.id == note.id })?.richText ?? AttributedString()
    }

    private var editorCanvasColor: Color {
        #if os(macOS)
            Color(nsColor: .textBackgroundColor)
        #else
            Color(uiColor: .systemBackground)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(
                "note.title.placeholder",
                text: Binding(
                    get: { store.notes.first(where: { $0.id == note.id })?.title ?? "" },
                    set: { value in
                        store.updateTitle(id: note.id, title: value)
                        guard value.contains(where: { $0.isNewline }) else { return }
                        isTitleFocused = false
                        isFocused = true
                        bodyFocusRequest &+= 1
                    }
                ), axis: .vertical
            )
            .font(TitleTypography.document)
            .foregroundStyle(Color(AppTheme.documentHeading))
            .lineSpacing(DocumentTypography.titleLineSpacing)
            .lineLimit(1...4)
            .textFieldStyle(.plain)
            .submitLabel(.next)
            .focused($isTitleFocused)
            .accessibilityLabel("note.title.accessibility_label")
            .accessibilityIdentifier("note-title")
            .onSubmit {
                isTitleFocused = false
                isFocused = true
                bodyFocusRequest &+= 1
            }
            .padding(.leading, DocumentTypography.titleLeadingInset)
            .frame(maxWidth: DocumentTypography.readingWidth)
            .padding(.horizontal, 32)
            .padding(.top, DocumentTypography.titleTopInset)
            .padding(.bottom, DocumentTypography.titleBottomInset)
            .frame(maxWidth: .infinity)

            NativeRichTextEditor(
                text: Binding(
                    get: { richText },
                    set: { store.updateRichText(id: note.id, text: $0) }
                ), selection: $selection, commandBridge: commandBridge, documentID: note.id, focusWhenEmpty: false,
                focusRequest: bodyFocusRequest,
                onEditLink: {
                    commandBridge.openLink?()
                },
                onToast: { toast.show($0) }
            )
            .font(.body)
            .frame(maxWidth: .infinity)
            .focused($isFocused)
            .accessibilityLabel("note.body.accessibility_label")
        }
        .background(editorCanvasColor)
        .overlay { ToastOverlay(presenter: toast) }
        .onChange(of: note.id) { _, _ in toast.clear() }
        .onDisappear { toast.clear() }
        .navigationTitle(note.displayTitle)
        #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu("format.menu", systemImage: "textformat") {
                        Button(
                            formatLabel(L10n.string("format.bold")) { DocumentTypography.emphasis(in: $0, context: fontContext) & 1 != 0 },
                            systemImage: "bold"
                        ) {
                            toggleBold()
                        }
                        .keyboardShortcut("b", modifiers: .command)
                        Button(
                            formatLabel(L10n.string("format.italic")) {
                                DocumentTypography.emphasis(in: $0, context: fontContext) & 2 != 0
                            },
                            systemImage: "italic"
                        ) { toggleItalic() }
                        .keyboardShortcut("i", modifiers: .command)
                        Button(formatLabel(L10n.string("format.underline")) { $0.underlineStyle != nil }, systemImage: "underline") {
                            commandBridge.perform?(.underline)
                        }
                        .keyboardShortcut("u", modifiers: .command)
                        Button(
                            formatLabel(L10n.string("format.strikethrough")) { $0.strikethroughStyle != nil }, systemImage: "strikethrough"
                        ) {
                            commandBridge.perform?(.strike)
                        }
                        Divider()
                        ForEach(1...6, id: \.self) { level in
                            Button(L10n.heading(level)) { paragraph("heading:\(level)") }
                        }
                        Button("format.body") { paragraph("body") }
                        Button("format.list.bulleted") { paragraph("bullet") }
                        Button("format.list.numbered") { paragraph("numbered") }
                        Button("format.checklist") { paragraph("task") }
                        Button("format.quote") { paragraph("quote") }
                        Button("format.code_block") { paragraph("code") }
                        Button("table.insert", systemImage: "tablecells") { insertTable() }
                        Button("format.list.indent") { indentList(outdent: false) }
                        Button("format.list.outdent") { indentList(outdent: true) }
                        Button("checklist.toggle") { toggleTask() }
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                        Divider()
                        Button("link.add_or_edit", systemImage: "link") {
                            commandBridge.openLink?()
                        }
                        .keyboardShortcut("k", modifiers: .command)
                        .disabled(!hasSelection)
                        Button("link.remove") { commandBridge.perform?(.link(nil)) }
                        .disabled(!hasSelection)
                        Button("format.clear") { commandBridge.perform?(.clear) }
                        Button("format.monospaced", systemImage: "chevron.left.forwardslash.chevron.right") {
                            toggleCode()
                        }
                    }
                    .accessibilityLabel("format.menu")
                    .disabled(isTitleFocused)
                    .help("format.menu.help")
                    Menu("Markdown", systemImage: "text.badge.checkmark") {
                        Button("markdown.copy", systemImage: "doc.on.doc") { copyMarkdown() }
                        .accessibilityIdentifier("copy-markdown")
                        Button("markdown.export", systemImage: "square.and.arrow.up") {
                            exportDocument = MarkdownFile(source: MarkdownFormatting.serialize(richText, context: fontContext))
                            showsExport = true
                        }
                        .accessibilityIdentifier("export-markdown")
                        Divider()
                        Button("markdown.format.selection") { convertMarkdown(wholeDocument: false) }
                        .disabled(!hasSelection)
                        Button("markdown.format.document") { convertMarkdown(wholeDocument: true) }
                        .disabled(richText.characters.isEmpty)
                        Divider()
                        Button("markdown.supported_syntax") { showsMarkdownHelp = true }
                    }
                    .accessibilityLabel("Markdown")
                    .help("markdown.actions.help")
                }
                ToolbarItem(placement: .automatic) {
                    Text(L10n.characterCount(TableData.plainText(in: richText).count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { formattingBar.disabled(isTitleFocused) }
        #endif
        .fileExporter(
            isPresented: $showsExport, document: exportDocument, contentType: MarkdownFile.contentType,
            defaultFilename: note.markdownFilename
        ) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("markdown.export_failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("common.ok") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .onChange(of: richText) { _, _ in didCopyMarkdown = false }
        .sheet(isPresented: $showsMarkdownHelp) {
            NavigationStack {
                List {
                    Section("markdown.help.automatic_formatting") {
                        Text("markdown.help.block_shortcuts")
                        Text("markdown.help.inline_shortcuts")
                        Text("markdown.help.continue_list")
                    }
                    Section("markdown.help.menu_syntax") {
                        Text("markdown.example.headings")
                        Text("markdown.example.emphasis")
                        Text("markdown.example.inline")
                        Text("markdown.example.lists")
                        Text("markdown.example.checklist")
                        Text("markdown.example.code_block")
                    }
                    Section {
                        Text(
                            "markdown.help.capabilities"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle(L10n.string("markdown.syntax"))
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("common.done") { showsMarkdownHelp = false }
                    }
                }
            }
            #if os(macOS)
                .frame(width: 520, height: 540)
            #endif
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let saveError {
                HStack {
                    Label(L10n.unsaved(saveError), systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer()
                    Button("common.retry", action: retrySave)
                }
                .padding()
                .background(.regularMaterial)
            }
        }
        .task {
            if note.title.isEmpty && richText.characters.isEmpty { isTitleFocused = true }
        }
    }

    private var formattingBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                Menu {
                    Button("format.body") { paragraph("body") }
                    ForEach(1...6, id: \.self) { level in
                        Button(L10n.heading(level)) { paragraph("heading:\(level)") }
                    }
                    Divider()
                    Button("format.quote") { paragraph("quote") }
                    Button("format.code_block") { paragraph("code") }
                    Button("table.insert", systemImage: "tablecells") { insertTable() }
                } label: {
                    Label("format.paragraph", systemImage: "textformat.size")
                }
                .accessibilityIdentifier("paragraph-menu")
                Divider().frame(height: 18)
                Button {
                    toggleBold()
                } label: {
                    Image(systemName: "bold")
                }
                .help("format.bold.help").accessibilityLabel("format.bold").accessibilityIdentifier("format-bold")
                Button {
                    toggleItalic()
                } label: {
                    Image(systemName: "italic")
                }
                .help("format.italic.help").accessibilityLabel("format.italic")
                Button {
                    toggleCode()
                } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .help("format.inline_code").accessibilityLabel("format.inline_code")
                Divider().frame(height: 18)
                Menu {
                    Button("format.list.bulleted") { paragraph("bullet") }
                    Button("format.list.numbered") { paragraph("numbered") }
                    Button("format.checklist") { paragraph("task") }
                    Divider()
                    Button("format.indent") { indentList(outdent: false) }
                    Button("format.outdent") { indentList(outdent: true) }
                } label: {
                    Label("format.list", systemImage: "list.bullet")
                }
                .accessibilityIdentifier("list-menu")
                Button {
                    paragraph("task")
                } label: {
                    Image(systemName: "checklist")
                }
                .help("format.checklist").accessibilityLabel("format.checklist")
                Button {
                    insertTable()
                } label: {
                    Image(systemName: "tablecells")
                }
                .help("table.insert").accessibilityLabel("table.insert").accessibilityIdentifier("insert-table")
                if didCopyMarkdown {
                    Label("markdown.copied", systemImage: "checkmark")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }

    private func insertTable() { commandBridge.insertTable?() }

    private func copyMarkdown() {
        let source = MarkdownFormatting.serialize(richText, context: fontContext)
        #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(source, forType: .string)
        #else
            UIPasteboard.general.string = source
        #endif
        didCopyMarkdown = true
    }

    private func toggleCode() { commandBridge.perform?(.inlineCode) }

    private func indentList(outdent: Bool) { commandBridge.perform?(.indent(outdent)) }

    private func formatLabel(_ title: String, matches: (AttributeContainer) -> Bool) -> String {
        let values = selection.attributes(in: richText).map(matches)
        guard !values.isEmpty else { return title }
        if values.allSatisfy({ $0 }) { return "✓ " + title }
        if values.contains(true) { return L10n.mixedFormat(title) }
        return title
    }

    private func paragraph(_ style: String) {
        commandBridge.perform?(style == "quote" ? .quote : .paragraph(style))
    }

    private func toggleTask() {
        var updated = richText
        ParagraphEditing.toggleTask(in: &updated, selection: &selection)
        store.applyRichEdit(id: note.id, text: updated, undoManager: undoManager)
    }

    private var hasSelection: Bool {
        if case .ranges(let ranges) = selection.indices(in: richText) { return ranges.ranges.count == 1 }
        return false
    }

    private func toggleBold() { toggleEmphasis(1) }
    private func toggleItalic() { toggleEmphasis(2) }

    private func toggleEmphasis(_ flag: Int) { commandBridge.perform?(.emphasis(flag)) }

    private func convertMarkdown(wholeDocument: Bool) {
        var updated = richText
        if wholeDocument {
            updated = MarkdownFormatting.renderKeepingBlocks(updated)
            selection = AttributedTextSelection(insertionPoint: updated.endIndex)
        } else {
            guard case .ranges(let ranges) = selection.indices(in: updated),
                ranges.ranges.count == 1, let range = ranges.ranges.first
            else { return }
            let source = AttributedString(updated[range])
            updated.replaceSelection(&selection, with: MarkdownFormatting.renderKeepingBlocks(source))
        }
        store.applyRichEdit(id: note.id, text: updated, undoManager: undoManager)
        isFocused = true
    }
}
