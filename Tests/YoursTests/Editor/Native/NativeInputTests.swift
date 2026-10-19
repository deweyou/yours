#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Yours

    @MainActor
    struct NativeInputTests {
        @Test(arguments: [false, true]) func codeStartTypingSurvivesSelectionBindingUpdates(composing: Bool) throws {
            var text = MarkdownFormatting.render("打yy`撒`大叔大")
            var selection = AttributedTextSelection(insertionPoint: text.startIndex)
            let editor = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                selection: Binding(get: { selection }, set: { selection = $0 }))
            let coordinator = editor.makeCoordinator()
            let view = ReadingMacTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 200))
            view.textContainer?.replaceLayoutManager(CodeLayoutManager())
            let storage = try #require(view.textStorage)
            storage.setAttributedString(NativeTextAttributes.native(text, context: EnvironmentValues().fontResolutionContext))
            coordinator.textView = view
            view.delegate = coordinator
            view.didResolveTypingAttributes = {
                coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
            }
            let layout = try #require(view.layoutManager as? CodeLayoutManager)
            let container = try #require(view.textContainer)
            let range = (view.string as NSString).range(of: "撒")
            view.setSelectedRange(NSRange(location: range.location, length: 0))
            coordinator.update(editor)
            layout.ensureLayout(for: container)
            let surface = try #require(
                layout.inlineCodeBackgroundRects(
                    forGlyphRange: layout.glyphRange(
                        forCharacterRange: range,
                        actualCharacterRange: nil), in: container
                ).first)
            view.resolveInlineCodeTypingAttributes(at: CGPoint(x: surface.minX + 2, y: surface.midY))
            coordinator.update(editor)
            #expect(view.typingAttributes[.yoursCodeStyle] as? String == "inline")
            // AppKit may resolve the leading boundary from the preceding body run
            // again between mouse selection and the text input client callback.
            view.typingAttributes = storage.attributes(at: 0, effectiveRange: nil)
            for index in 0..<3 {
                if composing && index == 0 {
                    view.setMarkedText("1", selectedRange: NSRange(location: 1, length: 0), replacementRange: view.selectedRange())
                    #expect(view.typingAttributes[.yoursCodeStyle] as? String == "inline")
                }
                view.insertText("1", replacementRange: view.hasMarkedText() ? view.markedRange() : view.selectedRange())
                coordinator.update(editor)
            }
            let inserted = (view.string as NSString).range(of: "111")
            #expect(inserted.length == 3)
            storage.enumerateAttribute(.yoursCodeStyle, in: inserted) { value, _, _ in
                #expect(value as? String == "inline")
            }
        }

        @Test(arguments: [false, true], [false, true])
        func typingPreservesInlineBoundarySide(inside: Bool, composing: Bool) throws {
            var text = MarkdownFormatting.render("前`撒`后")
            var selection = AttributedTextSelection(insertionPoint: text.startIndex)
            let editor = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                selection: Binding(get: { selection }, set: { selection = $0 }))
            let coordinator = editor.makeCoordinator()
            let view = ReadingMacTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 200))
            view.textContainer?.replaceLayoutManager(CodeLayoutManager())
            let storage = try #require(view.textStorage)
            storage.setAttributedString(NativeTextAttributes.native(text, context: EnvironmentValues().fontResolutionContext))
            coordinator.textView = view
            view.delegate = coordinator
            view.didResolveTypingAttributes = {
                coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
            }
            coordinator.update(editor)
            view.setSelectedRange(NSRange(location: inside ? 2 : 1, length: 0))
            #expect(view.setInlineCodeBoundary(inside: inside))
            for _ in 0..<2 {
                if composing {
                    for syllable in ["zh", "zhong"] {
                        view.setMarkedText(
                            syllable, selectedRange: NSRange(location: syllable.utf16.count, length: 0),
                            replacementRange: view.hasMarkedText() ? view.markedRange() : view.selectedRange())
                        let marked = view.markedRange()
                        #expect(marked.length == syllable.utf16.count)
                        if !inside {
                            // Only the last marked character touches the code surface;
                            // no generated gap may remain before the composing text.
                            let preceding = marked.location - 1
                            #expect(storage.attribute(.yoursInlineSpacing, at: preceding, effectiveRange: nil) == nil)
                            #expect(storage.attribute(.yoursInlineSpacing, at: NSMaxRange(marked) - 1, effectiveRange: nil) != nil)
                        }
                    }
                }
                view.insertText("中", replacementRange: view.hasMarkedText() ? view.markedRange() : view.selectedRange())
                coordinator.update(editor)
                #expect(view.inlineCodeBoundary?.inside == inside)
                #expect((view.typingAttributes[.yoursCodeStyle] as? String == "inline") == inside)
            }
            #expect(view.string == (inside ? "前撒中中后" : "前中中撒后"))
            let inserted = (view.string as NSString).range(of: "中中")
            storage.enumerateAttribute(.yoursCodeStyle, in: inserted) { value, _, _ in
                #expect((value as? String == "inline") == inside)
            }
        }

        @Test(arguments: ["正文", "**加粗**", "*斜体*", "`代码`", "- 项目", "> 引用", "# 标题"])
        func returnResetsInlineStylesBeforeFollowingInput(markdown: String) throws {
            var source = MarkdownFormatting.render(markdown)
            source.underlineStyle = .single
            source.strikethroughStyle = .single
            let (view, coordinator) = editor(source)
            view.delegate = coordinator
            let before = try #require(view.textStorage).attributedSubstring(from: NSRange(location: 0, length: view.string.utf16.count))
            view.insertText("\n", replacementRange: view.selectedRange())
            coordinator.update(coordinator.parent)
            #expect(view.typingAttributes[.underlineStyle] == nil)
            #expect(view.typingAttributes[.strikethroughStyle] == nil)
            #expect(view.typingAttributes[.link] == nil)
            #expect(view.typingAttributes[.yoursCodeStyle] == nil)
            #expect((view.typingAttributes[.yoursInlineEmphasis] as? Int ?? 0) == 0)
            view.insertText("新文字", replacementRange: view.selectedRange())
            let storage = try #require(view.textStorage)
            let inserted = (view.string as NSString).range(of: "新文字")
            #expect(storage.attribute(.underlineStyle, at: inserted.location, effectiveRange: nil) == nil)
            #expect(storage.attribute(.strikethroughStyle, at: inserted.location, effectiveRange: nil) == nil)
            #expect((storage.attribute(.yoursInlineEmphasis, at: inserted.location, effectiveRange: nil) as? Int ?? 0) == 0)
            #expect(
                NativeTextAttributes.rich(storage.attributedSubstring(from: NSRange(location: 0, length: before.length)))
                    == NativeTextAttributes.rich(before))
        }

        @Test func backspaceOnEmptyFirstHeadingReturnsToBody() {
            let (view, coordinator) = editor(MarkdownFormatting.render("# 标题"))
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))

            for _ in view.string { view.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
            #expect(view.string.isEmpty)
            // Once the last character is gone there is no range to delete, so AppKit
            // sends another deleteBackward command without calling shouldChangeTextIn.
            view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            #expect(view.string.isEmpty)
            #expect(view.selectedRange() == NSRange(location: 0, length: 0))
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")
            #expect(view.typingAttributes[.yoursCodeStyle] == nil)
        }

        @Test func emptyDocumentDoesNotStartWithHeadingTypingStyle() {
            let (view, coordinator) = editor(AttributedString())
            coordinator.update(coordinator.parent)
            let role = view.typingAttributes[.yoursParagraphStyle] as? String
            #expect(role == nil || role == "body")
            #expect(view.typingAttributes[.yoursCodeStyle] == nil)
        }

        @Test func clickingBelowTrailingCodeEndsBlockAndPreservesCodeContent() throws {
            let context = EnvironmentValues().fontResolutionContext
            for suffix in ["", "\n"] {
                var source = AttributedString("let value = 1" + suffix)
                source.font = .body.monospaced()
                source[ParagraphStyleAttribute.self] = "code"
                source[CodeStyleAttribute.self] = "block:test"
                source[CodeLanguageAttribute.self] = "swift"
                let (view, coordinator) = editor(source)
                let window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = view
                view.allowsUndo = true
                let undo = try #require(view.undoManager)
                undo.beginUndoGrouping()
                #expect(coordinator.exitTrailingCode())
                undo.endUndoGrouping()
                #expect(view.string == "let value = 1\n")
                #expect(view.typingAttributes[.yoursCodeStyle] == nil)
                #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")
                #expect(view.selectedRange().location == view.string.utf16.count)
                let restored = NativeTextAttributes.rich(view.textStorage!)
                #expect(MarkdownFormatting.serialize(restored, context: context) == "```swift\nlet value = 1\n```\n")
                #expect(!coordinator.exitTrailingCode())
                undo.undo()
                #expect(view.string == String(source.characters))
                #expect(view.typingAttributes[.yoursCodeStyle] as? String == "block:test")
                undo.redo()
                #expect(view.string == "let value = 1\n")
                #expect(view.typingAttributes[.yoursCodeStyle] == nil)
            }
        }

        @Test func shiftReturnInsertsLineBreakWithoutChangingParagraphStyle() {
            let (view, coordinator) = editor(MarkdownFormatting.render("## Heading"))
            view.delegate = coordinator
            #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertLineBreak(_:))))
            #expect(view.string == "Heading\u{2028}")
            #expect(view.selectedRange().location == view.string.utf16.count)
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "heading:2")
            let rich = NativeTextAttributes.rich(view.textStorage!)
            let markdown = MarkdownFormatting.serialize(rich, context: EnvironmentValues().fontResolutionContext)
            let restored = MarkdownFormatting.render(markdown)
            #expect(String(restored.characters) == view.string)
            #expect(restored.runs.allSatisfy { $0[ParagraphStyleAttribute.self] == "heading:2" })
        }

        @Test func oneTabIndentsTaskAndReturnKeepsTheSameDepth() throws {
            let (view, coordinator) = editor(MarkdownFormatting.render("- [x] Parent"))
            view.delegate = coordinator

            #expect(coordinator.textView(view, doCommandBy: #selector(NSResponder.insertTab(_:))))
            #expect(view.string == "\tParent")
            #expect(view.textStorage?.attribute(.yoursParagraphStyle, at: 0, effectiveRange: nil) as? String == "task")

            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.string == "\tParent\n\t")
            let nextLine = (view.string as NSString).range(of: "\n").location + 1
            #expect(view.textStorage?.attribute(.yoursParagraphStyle, at: nextLine, effectiveRange: nil) as? String == "task")
            #expect(String(view.string.dropFirst(nextLine)).prefix(while: { $0 == "\t" }).count == 1)
        }

        @Test func secondReturnOnEmptyBulletExitsToBody() {
            let (view, coordinator) = editor(MarkdownFormatting.render("- First"))
            view.delegate = coordinator

            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.string == "First\n")
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "bullet")

            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.string == "First\n")
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")

            view.insertText("Body", replacementRange: view.selectedRange())
            #expect(view.string == "First\nBody")
        }

        @Test func secondReturnOnEmptyTaskExitsToBody() {
            let (view, coordinator) = editor(MarkdownFormatting.render("- [ ] Task"))
            view.delegate = coordinator

            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.string == "Task\n")
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "task")

            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.string == "Task\n")
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")

            view.insertText("Body", replacementRange: view.selectedRange())
            #expect(view.string == "Task\nBody")
        }

        @Test func markdownPasteReplacesUTF16SelectionAndSupportsUndo() throws {
            let original = AttributedString("前🌿后")
            let (view, coordinator) = editor(original)
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.allowsUndo = true
            view.setSelectedRange(NSRange(location: 1, length: 2))
            let undo = try #require(view.undoManager)
            undo.beginUndoGrouping()
            #expect(coordinator.pasteContent(encoded: nil, plainText: "**中文**", hasRichText: false))
            undo.endUndoGrouping()
            #expect(view.string == "前中文后")
            #expect(view.selectedRange() == NSRange(location: 3, length: 0))
            let rich = NativeTextAttributes.rich(try #require(view.textStorage))
            #expect(rich.runs.contains { ($0[InlineEmphasisAttribute.self] ?? 0) != 0 })
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")
            undo.undo()
            #expect(view.string == "前🌿后")
            #expect(view.selectedRange() == NSRange(location: 1, length: 2))
            undo.redo()
            #expect(view.string == "前中文后")
            view.insertText("续写", replacementRange: view.selectedRange())
            #expect(view.string == "前中文续写后")
        }

        @Test func markdownPasteLeavesPlainTextRichTextAndCodeToNativePaste() {
            let (view, coordinator) = editor(AttributedString("原文"))
            for plain in ["普通文字\n\n下一段", "https://example.com", "unfinished **", "user_name"] {
                #expect(coordinator.pasteContent(encoded: nil, plainText: plain, hasRichText: false) == false)
                #expect(view.string == "原文")
            }
            #expect(coordinator.pasteContent(encoded: nil, plainText: "# 标题", hasRichText: true) == false)
            view.typingAttributes[.yoursCodeStyle] = "block:test"
            #expect(coordinator.pasteContent(encoded: nil, plainText: "# 标题", hasRichText: false) == false)
            #expect(view.string == "原文")
        }

        @Test func internalClipboardTakesPriorityOverMarkdown() throws {
            let (view, coordinator) = editor(AttributedString())
            let encoded = try RichTextClipboard.encode(AttributedString("**保留字面量**"))
            #expect(coordinator.pasteContent(encoded: encoded, plainText: "**保留字面量**", hasRichText: true))
            #expect(view.string == "**保留字面量**")
        }

        @Test func repositoryMarkdownSamplePastesAllSupportedBlocksWithFreshIDs() throws {
            var root = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { root.deleteLastPathComponent() }
            let source = try String(contentsOf: root.appendingPathComponent("docs/examples/markdown-paste-sample.md"), encoding: .utf8)
            let (view, coordinator) = editor(AttributedString())
            #expect(coordinator.pasteContent(encoded: nil, plainText: source, hasRichText: false))
            let first = NativeTextAttributes.rich(try #require(view.textStorage))
            for level in 1...6 {
                #expect(first.runs.contains { $0[ParagraphStyleAttribute.self] == "heading:\(level)" })
            }
            #expect(first.runs.contains { $0[QuoteAttribute.self] == true })
            #expect(first.runs.contains { $0[TaskStateAttribute.self] == true })
            #expect(first.runs.contains { $0[TaskStateAttribute.self] == false })
            let tables = Set(first.runs.compactMap { $0[TableAttribute.self]?.id })
            #expect(tables.count == 2)
            let codes = Set(first.runs.compactMap { $0[CodeStyleAttribute.self] }.filter { $0.hasPrefix("block:") })
            #expect(codes.count == 4)
            #expect(first.runs.contains { $0[QuoteAttribute.self] == true && $0[CodeStyleAttribute.self]?.hasPrefix("block:") == true })
            #expect(view.string.contains("**这里保持字面量，不变成加粗**"))
            #expect(coordinator.pasteContent(encoded: nil, plainText: source, hasRichText: false))
            let repeated = NativeTextAttributes.rich(try #require(view.textStorage))
            #expect(Set(repeated.runs.compactMap { $0[TableAttribute.self]?.id }).count == 4)
            #expect(Set(repeated.runs.compactMap { $0[CodeStyleAttribute.self] }.filter { $0.hasPrefix("block:") }).count == 8)
        }

        @Test func listMarkersStayOutsideTextSelectionAndContinueSemantically() throws {
            let (view, coordinator) = editor(MarkdownFormatting.render("12. 中文🌿"))
            view.delegate = coordinator
            #expect(view.string == "中文🌿")
            #expect(view.textStorage?.attribute(.yoursListMarker, at: 0, effectiveRange: nil) as? String == "12.")
            view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
            #expect(view.textStorage?.attributedSubstring(from: view.selectedRange()).string == "中文🌿")
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            #expect(coordinator.intercept(range: view.selectedRange(), replacement: "\n") == false)
            #expect(view.string == "中文🌿\n")
            #expect(view.typingAttributes[.yoursListMarker] as? String == "13.")
            view.insertText("下一项", replacementRange: view.selectedRange())
            #expect(view.string == "中文🌿\n下一项")
            let rich = NativeTextAttributes.rich(try #require(view.textStorage))
            #expect(MarkdownFormatting.serialize(rich, context: EnvironmentValues().fontResolutionContext) == "12. 中文🌿\n13. 下一项")
        }

        @Test func backspaceAtListContentStartOutdentsThenExitsWithoutDeletingText() {
            let (view, coordinator) = editor(MarkdownFormatting.render("    - 中文🌿"))
            view.setSelectedRange(NSRange(location: 1, length: 0))
            #expect(coordinator.backspaceAtParagraphStart())
            #expect(view.string == "中文🌿")
            #expect(view.typingAttributes[.yoursListMarker] as? String == "•")
            #expect(coordinator.backspaceAtParagraphStart())
            #expect(view.string == "中文🌿")
            #expect(view.textStorage?.attribute(.yoursListMarker, at: 0, effectiveRange: nil) == nil)
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")
        }

        @Test func listShortcutLeavesAnEmptyIndentedCaretAndSupportsUndo() throws {
            let (view, coordinator) = editor(AttributedString("-"))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            view.allowsUndo = true
            let undo = try #require(view.undoManager)
            undo.beginUndoGrouping()
            #expect(coordinator.intercept(range: view.selectedRange(), replacement: " ") == false)
            undo.endUndoGrouping()
            #expect(view.string.isEmpty)
            #expect(view.selectedRange().location == 0)
            #expect(view.typingAttributes[.yoursListMarker] as? String == "•")
            let paragraph = try #require(view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
            #expect(paragraph.firstLineHeadIndent > 0)
            undo.undo()
            #expect(view.string == "- ")
            undo.redo()
            #expect(view.string.isEmpty)
            #expect(view.typingAttributes[.yoursListMarker] as? String == "•")
        }

        @Test(arguments: ["-", "*", "+", "1."])
        func listShortcutStylesEmptyParagraphOnFirstSpace(prefix: String) throws {
            let (view, coordinator) = editor(AttributedString("\n后续正文"))
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: 0, length: 0))
            for character in prefix { view.insertText(String(character), replacementRange: view.selectedRange()) }
            view.insertText(" ", replacementRange: view.selectedRange())
            coordinator.update(coordinator.parent)
            let storage = try #require(view.textStorage)
            #expect(view.string == "\n后续正文")
            #expect(view.selectedRange().location == 0)
            let marker = prefix == "1." ? "1." : "•"
            #expect(storage.attribute(.yoursListMarker, at: 0, effectiveRange: nil) as? String == marker)
            let paragraph = try #require(storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
            #expect(paragraph.firstLineHeadIndent == DocumentTypography.listIndent)
            #expect(storage.attribute(.yoursListMarker, at: 1, effectiveRange: nil) == nil)
            view.insertText("中文🌿", replacementRange: view.selectedRange())
            #expect(view.string == "中文🌿\n后续正文")
            #expect(storage.attribute(.yoursListMarker, at: 0, effectiveRange: nil) as? String == marker)
        }

        @Test(arguments: ["- ", "1. ", "[] ", "[] \t", "[] \t\t"], ["", "\n后文"])
        func emptyListGeometryMatchesFirstCharacter(shortcut: String, suffix: String) throws {
            let (original, coordinator) = editor(AttributedString(suffix))
            let storage = NSTextStorage(attributedString: original.textStorage!)
            let layout = CodeLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 500, height: 10_000))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            let view = ReadingMacTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 300), textContainer: container)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            coordinator.textView = view
            view.delegate = coordinator
            coordinator.update(coordinator.parent)
            view.setSelectedRange(NSRange(location: 0, length: 0))
            for character in shortcut { view.insertText(String(character), replacementRange: view.selectedRange()) }
            coordinator.update(coordinator.parent)
            layout.ensureLayout(for: container)
            let start = view.selectedRange().location
            let emptyCaret = view.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
            let font = try #require(view.typingAttributes[.font] as? NSFont)
            let emptyMarker =
                layout.taskMarkerRect(at: start)
                ?? layout.emptyTaskMarkerRect(at: start, font: font, quoted: false, in: container)
            view.insertText("中", replacementRange: view.selectedRange())
            coordinator.update(coordinator.parent)
            layout.ensureLayout(for: container)
            let filledCaret = view.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
            let filledMarker = try #require(layout.taskMarkerRect(at: start))
            #expect(abs(emptyCaret.minX - filledCaret.minX) < 0.01)
            #expect(abs(emptyMarker.minX - filledMarker.minX) < 0.01)
            #expect(abs(emptyMarker.minY - filledMarker.minY) < 0.01)
        }

        @Test(arguments: 1...6, ["", "正文\n"])
        func emptyHeadingGeometryMatchesFirstCharacter(level: Int, prefix: String) throws {
            let (original, coordinator) = editor(AttributedString(prefix + "/h"))
            let storage = NSTextStorage(attributedString: original.textStorage!)
            let layout = CodeLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 500, height: 10_000))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            let view = ReadingMacTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 300), textContainer: container)
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            defer { window.orderOut(nil) }
            coordinator.textView = view
            view.delegate = coordinator
            coordinator.update(coordinator.parent)
            let start = prefix.utf16.count
            coordinator.performControlAction(
                .paragraph("heading:\(level)"), range: NSRange(location: start + 2, length: 0),
                slash: NSRange(location: start, length: 2))
            coordinator.update(coordinator.parent)
            layout.ensureLayout(for: container)
            let emptyCaret = view.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
            let emptyVisible = view.visibleInsertionPointRect(view.convert(window.convertFromScreen(emptyCaret), from: nil))
            let before = try #require(view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
            view.insertText("1", replacementRange: view.selectedRange())
            coordinator.update(coordinator.parent)
            layout.ensureLayout(for: container)
            let filledCaret = view.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
            let filledVisible = view.visibleInsertionPointRect(view.convert(window.convertFromScreen(filledCaret), from: nil))
            #expect(abs(emptyVisible.minY - filledVisible.minY) < 0.5)
            let after = try #require(storage.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle)
            #expect(before.paragraphSpacingBefore == after.paragraphSpacingBefore)
            #expect(abs(emptyCaret.minY - filledCaret.minY) < 0.5)
        }

        @Test(arguments: ["- 第一项", "1. 第一项"])
        func continuedEmptyListKeepsMarkerWhenIndented(markdown: String) throws {
            let (original, coordinator) = editor(MarkdownFormatting.render(markdown))
            let storage = NSTextStorage(attributedString: original.textStorage!)
            let layout = CodeLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 500, height: 10_000))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            let view = ReadingMacTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 300), textContainer: container)
            coordinator.textView = view
            view.delegate = coordinator
            coordinator.update(coordinator.parent)
            view.insertText("\n", replacementRange: view.selectedRange())
            for _ in 0..<2 {
                view.doCommand(by: #selector(NSResponder.insertTab(_:)))
                coordinator.update(coordinator.parent)
                layout.ensureLayout(for: container)
                let rect = try #require(
                    layout.emptyListMarkerRect(
                        selection: view.selectedRange(), attributes: view.typingAttributes, in: container))
                #expect(rect.width > 0)
                #expect(view.typingAttributes[.yoursListMarker] as? String == (markdown.hasPrefix("1.") ? "1." : "•"))
            }
            #expect(view.string == "第一项\n\t\t")
            view.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
            coordinator.update(coordinator.parent)
            layout.ensureLayout(for: container)
            let empty = try #require(
                layout.emptyListMarkerRect(
                    selection: view.selectedRange(), attributes: view.typingAttributes, in: container))
            let start = view.selectedRange().location
            view.insertText("子项", replacementRange: view.selectedRange())
            layout.ensureLayout(for: container)
            let filled = try #require(layout.taskMarkerRect(at: start))
            #expect(abs(empty.minX - filled.minX) < 0.01)
            #expect(view.typingAttributes[.yoursListMarker] != nil)
            #expect(view.string == "第一项\n\t子项")
        }

        @Test func backspaceOnNewTaskKeepsCurrentLineAndOutdentsBeforeExiting() throws {
            let (view, coordinator) = editor(MarkdownFormatting.render("- [ ] 第一项"))
            view.delegate = coordinator
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            view.allowsUndo = true
            view.insertText("\n", replacementRange: view.selectedRange())
            view.doCommand(by: #selector(NSResponder.insertTab(_:)))
            #expect(view.string == "第一项\n\t")
            view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            #expect(view.string == "第一项\n")
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "task")
            let undo = try #require(view.undoManager)
            undo.removeAllActions()
            undo.beginUndoGrouping()
            view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            undo.endUndoGrouping()
            #expect(view.string == "第一项\n")
            #expect(view.selectedRange().location == view.string.utf16.count)
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")
            #expect(view.textStorage?.attribute(.yoursTaskChecked, at: 0, effectiveRange: nil) as? Bool == false)
            undo.undo()
            #expect(view.string == "第一项\n")
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "task")
            undo.redo()
            view.insertText("正文", replacementRange: view.selectedRange())
            #expect(view.string == "第一项\n正文")
            #expect(view.textStorage?.attribute(.yoursTaskChecked, at: 4, effectiveRange: nil) == nil)
        }

        @Test func listCaretSkipsIndentationWithoutChangingSelectionOrPlainTabs() {
            let (view, coordinator) = editor(MarkdownFormatting.render("Before\n        1. 中文🌿"))
            view.delegate = coordinator
            let paragraphStart = (view.string as NSString).range(of: "\t\t").location
            let contentStart = paragraphStart + 2
            for offset in paragraphStart...contentStart {
                #expect(coordinator.clampedListCaret(NSRange(location: offset, length: 0)).location == contentStart)
            }
            let selected = NSRange(location: paragraphStart, length: view.string.utf16.count - paragraphStart)
            #expect(coordinator.clampedListCaret(selected) == selected)
            view.setSelectedRange(NSRange(location: paragraphStart, length: 0))
            coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
            #expect(view.selectedRange().location == contentStart)
            #expect(coordinator.moveLeftFromListStart())
            #expect(view.selectedRange().location == paragraphStart - 1)
            let (plainView, plainCoordinator) = editor(AttributedString("\t正文"))
            #expect(plainCoordinator.clampedListCaret(NSRange(location: 0, length: 0)).location == 0)
            #expect(plainView.string == "\t正文")
        }

        @Test(arguments: ["-", "1.", "[]"], [0, 1, 2])
        func listReturnPreservesDepthAndEmptyReturnExits(prefix: String, depth: Int) throws {
            let (view, coordinator) = editor(AttributedString())
            view.delegate = coordinator
            for character in prefix + " " { view.insertText(String(character), replacementRange: view.selectedRange()) }
            for _ in 0..<depth { view.doCommand(by: #selector(NSResponder.insertTab(_:))) }
            view.insertText("中文🌿", replacementRange: view.selectedRange())
            view.insertText("\n", replacementRange: view.selectedRange())
            coordinator.update(coordinator.parent)
            let indent = String(repeating: "\t", count: depth)
            #expect(view.string == indent + "中文🌿\n" + indent)
            #expect(
                view.typingAttributes[.yoursParagraphStyle] as? String == (prefix == "-" ? "bullet" : prefix == "1." ? "numbered" : "task"))
            view.insertText("\n", replacementRange: view.selectedRange())
            coordinator.update(coordinator.parent)
            #expect(view.string == indent + "中文🌿\n")
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")
            view.insertText("正文", replacementRange: view.selectedRange())
            #expect(view.string == indent + "中文🌿\n正文")
        }

        @Test(arguments: ["-", "1.", "[]"], ["-", "1.", "[]"])
        func emptyListCanSwitchTypeButSyntaxAfterContentStaysLiteral(from: String, to: String) throws {
            let (view, coordinator) = editor(AttributedString())
            view.delegate = coordinator
            for character in from + " " { view.insertText(String(character), replacementRange: view.selectedRange()) }
            for character in to + " " { view.insertText(String(character), replacementRange: view.selectedRange()) }
            coordinator.update(coordinator.parent)
            #expect(view.string.isEmpty)
            let role = to == "-" ? "bullet" : to == "1." ? "numbered" : "task"
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == role)
            view.insertText("中文🌿", replacementRange: view.selectedRange())
            for character in to + " " { view.insertText(String(character), replacementRange: view.selectedRange()) }
            #expect(view.string == "中文🌿" + to + " ")
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == role)
        }

        @Test(arguments: ["-", "1.", "[]"], ["-", "1.", "[]"])
        func nestedEmptyListTypeSwitchPreservesIndent(from: String, to: String) {
            let (view, coordinator) = editor(AttributedString())
            view.delegate = coordinator
            for character in from + " " { view.insertText(String(character), replacementRange: view.selectedRange()) }
            view.doCommand(by: #selector(NSResponder.insertTab(_:)))
            view.doCommand(by: #selector(NSResponder.insertTab(_:)))
            for character in to + " " { view.insertText(String(character), replacementRange: view.selectedRange()) }
            coordinator.update(coordinator.parent)
            #expect(view.string == "\t\t")
            #expect(view.selectedRange().location == 2)
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == (to == "-" ? "bullet" : to == "1." ? "numbered" : "task"))
        }

        @Test(arguments: ["-", "1.", "[]"], [0, 1, 2])
        func listBackspacePreservesTextAndExitsBeforeMerging(prefix: String, depth: Int) throws {
            let markdown = "前文\n" + String(repeating: "    ", count: depth) + (prefix == "[]" ? "- [ ]" : prefix) + " 中文🌿"
            let (view, coordinator) = editor(MarkdownFormatting.render(markdown))
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: 3 + depth, length: 0))
            for level in (0..<depth).reversed() {
                view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                #expect(view.string == "前文\n" + String(repeating: "\t", count: level) + "中文🌿")
                #expect(view.selectedRange().location == 3 + level)
            }
            view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            #expect(view.string == "前文\n中文🌿")
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")
            view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            #expect(view.string == "前文中文🌿")
        }

        @Test(arguments: ["-", "12.", "- [x]"])
        func listSplitPreservesBothSidesAndTaskCompletion(markdownPrefix: String) throws {
            let (view, coordinator) = editor(MarkdownFormatting.render(markdownPrefix + " 中文🌿尾文"))
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: "中文🌿".utf16.count, length: 0))
            view.insertText("\n", replacementRange: view.selectedRange())
            #expect(view.string == "中文🌿\n尾文")
            let storage = try #require(view.textStorage)
            if markdownPrefix == "12." {
                #expect(storage.attribute(.yoursListMarker, at: 0, effectiveRange: nil) as? String == "12.")
                #expect(storage.attribute(.yoursListMarker, at: 5, effectiveRange: nil) as? String == "13.")
            }
            if markdownPrefix == "- [x]" {
                #expect(storage.attribute(.yoursTaskChecked, at: 0, effectiveRange: nil) as? Bool == true)
                #expect(storage.attribute(.yoursTaskChecked, at: 5, effectiveRange: nil) as? Bool == false)
            }
        }

        @Test func checkedTaskIndentAndOutdentPreserveCompletion() throws {
            let (view, coordinator) = editor(MarkdownFormatting.render("- [x] 已完成🌿"))
            view.delegate = coordinator
            for _ in 0..<2 {
                view.doCommand(by: #selector(NSResponder.insertTab(_:)))
                #expect(view.textStorage?.attribute(.yoursTaskChecked, at: 0, effectiveRange: nil) as? Bool == true)
            }
            view.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
            #expect(view.textStorage?.attribute(.yoursTaskChecked, at: 0, effectiveRange: nil) as? Bool == true)
        }

        @Test(arguments: ["-", "1.", "[]"])
        func listIndentUndoRedoRestoresSelectionAndSemantics(prefix: String) throws {
            let (view, coordinator) = editor(MarkdownFormatting.render((prefix == "[]" ? "- [ ]" : prefix) + " 中文🌿"))
            view.delegate = coordinator
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            view.allowsUndo = true
            let undo = try #require(view.undoManager)
            let before = view.selectedRange()
            undo.beginUndoGrouping()
            view.doCommand(by: #selector(NSResponder.insertTab(_:)))
            undo.endUndoGrouping()
            #expect(view.string == "\t中文🌿")
            undo.undo()
            #expect(view.string == "中文🌿")
            #expect(view.selectedRange() == before)
            undo.redo()
            #expect(view.string == "\t中文🌿")
            #expect(view.selectedRange().location == before.location + 1)
            view.insertText("续写", replacementRange: view.selectedRange())
            #expect(view.string == "\t中文🌿续写")
        }

        @Test(arguments: ["-", "1.", "[]"])
        func listSyntaxInsideCodeAndMarkedInputDoesNotConvert(prefix: String) {
            let (view, coordinator) = editor(MarkdownFormatting.render("```\n原文\n```"))
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: 0, length: 0))
            for character in prefix + " " { view.insertText(String(character), replacementRange: view.selectedRange()) }
            #expect(view.string.hasPrefix(prefix + " 原文"))
            #expect(view.textStorage?.attribute(.yoursListMarker, at: 0, effectiveRange: nil) == nil)
            let (markedView, markedCoordinator) = editor(AttributedString(prefix))
            markedView.setMarkedText(
                prefix, selectedRange: NSRange(location: prefix.utf16.count, length: 0),
                replacementRange: NSRange(location: 0, length: prefix.utf16.count))
            #expect(markedView.hasMarkedText())
            #expect(markedCoordinator.intercept(range: markedView.selectedRange(), replacement: " "))
            #expect(markedView.string == prefix)
        }

        @Test(arguments: ["-", "1.", "- [ ]"])
        func quotedListContinuationAndExitKeepQuote(prefix: String) throws {
            let (view, coordinator) = editor(MarkdownFormatting.render("> " + prefix + " 中文🌿"))
            view.delegate = coordinator
            view.insertText("\n", replacementRange: view.selectedRange())
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
            view.insertText("\n", replacementRange: view.selectedRange())
            coordinator.update(coordinator.parent)
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")
            view.insertText("引用正文", replacementRange: view.selectedRange())
            #expect(view.string == "中文🌿\n引用正文")
            let storage = try #require(view.textStorage)
            #expect(storage.attribute(.yoursQuote, at: 5, effectiveRange: nil) as? Bool == true)
            #expect(storage.attribute(.yoursListMarker, at: 5, effectiveRange: nil) == nil)
            #expect(storage.attribute(.yoursTaskChecked, at: 5, effectiveRange: nil) == nil)
        }

        @Test(arguments: ["-", "1.", "- [ ]"])
        func listSelectionReplacementPreservesUTF16AndMarkers(prefix: String) throws {
            let (view, coordinator) = editor(MarkdownFormatting.render(prefix + " 中文🌿尾文"))
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: 2, length: 2))
            view.insertText("👩🏽‍💻", replacementRange: view.selectedRange())
            #expect(view.string == "中文👩🏽‍💻尾文")
            #expect(view.selectedRange().location == "中文👩🏽‍💻".utf16.count)
            #expect(
                view.textStorage?.attribute(.yoursParagraphStyle, at: 0, effectiveRange: nil) as? String
                    == (prefix == "-" ? "bullet" : prefix == "1." ? "numbered" : "task"))
        }

        @Test(arguments: ["-", "1.", "- [ ]"])
        func listIndentDepthLimitAndOutdentAtRootDoNotInsertTabs(prefix: String) {
            let (view, coordinator) = editor(MarkdownFormatting.render(prefix + " 内容"))
            view.delegate = coordinator
            view.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
            #expect(view.string == "内容")
            for _ in 0..<10 { view.doCommand(by: #selector(NSResponder.insertTab(_:))) }
            #expect(view.string == String(repeating: "\t", count: 8) + "内容")
            for _ in 0..<10 { view.doCommand(by: #selector(NSResponder.insertBacktab(_:))) }
            #expect(view.string == "内容")
        }

        @Test(arguments: 1...6)
        func headingShortcutReturnAndBackspaceAcrossAllLevels(level: Int) {
            let (view, coordinator) = editor(AttributedString())
            view.delegate = coordinator
            for character in String(repeating: "#", count: level) + " " {
                view.insertText(String(character), replacementRange: view.selectedRange())
            }
            view.insertText("标题🌿", replacementRange: view.selectedRange())
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "heading:\(level)")
            view.insertText("\n", replacementRange: view.selectedRange())
            view.insertText("正文", replacementRange: view.selectedRange())
            #expect(view.string == "标题🌿\n正文")
            #expect(view.textStorage?.attribute(.yoursParagraphStyle, at: 0, effectiveRange: nil) as? String == "heading:\(level)")
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            #expect(view.string == "标题🌿\n正文")
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")
        }

        @Test(arguments: ["正文", "# 标题", "> 引用", "- 列表", "1. 列表", "- [ ] 待办", "> - 引用列表"], ["**", "*", "~~", "`"])
        func inlineShortcutInsideBlocksKeepsOuterStyleAndFollowingTyping(block: String, marker: String) throws {
            let (view, coordinator) = editor(MarkdownFormatting.render(block))
            view.delegate = coordinator
            let role = view.typingAttributes[.yoursParagraphStyle] as? String
            let quoted = view.typingAttributes[.yoursQuote] as? Bool
            let start = view.string.utf16.count
            for character in marker + "中文🌿" + marker { view.insertText(String(character), replacementRange: view.selectedRange()) }
            let storage = try #require(view.textStorage)
            #expect(storage.attribute(.yoursParagraphStyle, at: start, effectiveRange: nil) as? String == role)
            #expect(storage.attribute(.yoursQuote, at: start, effectiveRange: nil) as? Bool == quoted)
            if marker == "**" || marker == "*" {
                #expect(
                    (storage.attribute(.yoursInlineEmphasis, at: start, effectiveRange: nil) as? Int ?? 0) & (marker == "**" ? 1 : 2) != 0)
            } else if marker == "~~" {
                #expect(storage.attribute(.strikethroughStyle, at: start, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
            } else {
                #expect(storage.attribute(.yoursCodeStyle, at: start, effectiveRange: nil) as? String == "inline")
            }
            view.insertText("后文", replacementRange: view.selectedRange())
            let next = start + "中文🌿".utf16.count
            #expect(storage.attribute(.yoursCodeStyle, at: next, effectiveRange: nil) == nil)
            #expect((storage.attribute(.yoursInlineEmphasis, at: next, effectiveRange: nil) as? Int ?? 0) == 0)
            #expect((storage.attribute(.strikethroughStyle, at: next, effectiveRange: nil) as? Int ?? 0) == 0)
        }

        @Test(arguments: ["**链接🌿**", "*链接🌿*", "~~链接🌿~~", "# **链接🌿**", "> **链接🌿**", "- **链接🌿**", "- [ ] **链接🌿**"])
        func linkOnFormattedSelectionPreservesLabelAndFormatting(markdown: String) throws {
            let (view, coordinator) = editor(MarkdownFormatting.render(markdown))
            view.delegate = coordinator
            let storage = try #require(view.textStorage)
            let before = storage.attributes(at: 0, effectiveRange: nil)
            view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
            view.insertText("https://example.com/path?q=1", replacementRange: view.selectedRange())
            #expect(view.string == "链接🌿")
            #expect(storage.attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "https://example.com/path?q=1"))
            for key in [NSAttributedString.Key.yoursParagraphStyle, .yoursInlineEmphasis, .strikethroughStyle] {
                #expect(String(describing: storage.attribute(key, at: 0, effectiveRange: nil)) == String(describing: before[key]))
            }
        }

        @Test(arguments: ["**中文🌿**", "*中文🌿*", "~~中文🌿~~", "`中文🌿`"])
        func inlineShortcutUndoRedoRestoresSyntaxAndCanContinue(syntax: String) throws {
            let (view, coordinator) = editor(AttributedString(String(syntax.dropLast())))
            view.delegate = coordinator
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            view.allowsUndo = true
            let undo = try #require(view.undoManager)
            undo.beginUndoGrouping()
            view.insertText(String(syntax.suffix(1)), replacementRange: view.selectedRange())
            undo.endUndoGrouping()
            #expect(view.string == "中文🌿")
            undo.undo()
            #expect(view.string == syntax)
            undo.redo()
            #expect(view.string == "中文🌿")
            view.insertText("后文", replacementRange: view.selectedRange())
            #expect(view.string == "中文🌿后文")
            let context = EnvironmentValues().fontResolutionContext
            let tail = "中文🌿".utf16.count
            let display = try #require(view.textStorage?.attribute(.font, at: tail, effectiveRange: nil) as? NSFont)
            #expect(display.fontName == BundledSerifFont.lightName)
            let restored = NativeTextAttributes.rich(try #require(view.textStorage))
            let range = try #require(restored.range(of: "后文"))
            let stored = try #require(restored[range].font).resolve(in: context)
            #expect(stored.isMonospaced == false)
            #expect(stored.isBold == false)
            #expect(stored.isItalic == false)
            #expect(CTFontCopyPostScriptName(stored.ctFont) as String != BundledSerifFont.regularName)
        }

        @Test func emptyDocumentTypesInSerifAndStoresSystemBody() throws {
            let (view, coordinator) = editor(AttributedString())
            view.delegate = coordinator
            coordinator.update(coordinator.parent)
            let font = try #require(view.typingAttributes[.font] as? NSFont)
            #expect(font.fontName == BundledSerifFont.lightName)
            view.insertText("中文🌿", replacementRange: view.selectedRange())
            let rich = NativeTextAttributes.rich(try #require(view.textStorage))
            let context = EnvironmentValues().fontResolutionContext
            let stored = try #require(rich.font).resolve(in: context).ctFont
            #expect(CTFontCopyFamilyName(stored) == CTFontCopyFamilyName(Font.body.resolve(in: context).ctFont))
            #expect(abs(CTFontGetSize(stored) - CTFontGetSize(Font.body.resolve(in: context).ctFont)) < 0.001)
        }

        private func editor(_ source: AttributedString) -> (NSTextView, NativeRichTextEditor.Coordinator) {
            var text = source
            var selection = AttributedTextSelection(insertionPoint: source.endIndex)
            let editor = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }), selection: Binding(get: { selection }, set: { selection = $0 }))
            let coordinator = editor.makeCoordinator()
            let view = NSTextView()
            let native = NativeTextAttributes.native(source, context: EnvironmentValues().fontResolutionContext)
            view.textStorage?.setAttributedString(native)
            view.setSelectedRange(NSRange(location: native.length, length: 0))
            if native.length > 0 { view.typingAttributes = native.attributes(at: native.length - 1, effectiveRange: nil) }
            coordinator.textView = view
            return (view, coordinator)
        }

        @Test func structuredCopyPreservesQuoteAndTaskSemanticsWithStandardFallbacks() throws {
            let source = MarkdownFormatting.render("> Quoted\n\n- [x] Done")
            let (view, coordinator) = editor(source)
            view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))

            #expect(coordinator.copyStructured(cut: false))
            let pasteboard = NSPasteboard.general
            let encoded = try #require(pasteboard.data(forType: .init("app.yours.richtext")))
            let copied = try RichTextClipboard.decode(encoded)
            #expect(copied.runs.contains { $0[QuoteAttribute.self] == true })
            #expect(copied.runs.contains { $0[TaskStateAttribute.self] == true })
            #expect(pasteboard.data(forType: .rtf) != nil)
            #expect(pasteboard.string(forType: .string) == "Quoted\nDone")
        }

        @Test func taskCheckboxExposesAnAccessibleToggleAction() throws {
            let source = MarkdownFormatting.render("- [ ] Accessible task")
            let native = NativeTextAttributes.native(source, context: EnvironmentValues().fontResolutionContext)
            let view = ReadingMacTextView()
            view.textContainer?.replaceLayoutManager(CodeLayoutManager())
            view.textStorage?.setAttributedString(native)
            var toggledMarker: Int?
            view.toggleTask = { marker in
                toggledMarker = marker
                return true
            }

            let action = try #require(view.accessibilityCustomActions()?.first)
            #expect(action.name == L10n.markComplete("Accessible task"))
            #expect(action.handler?() == true)
            #expect(toggledMarker == 0)
        }

        @Test func selectingBlankParagraphKeepsItsLayoutAndTypingMetrics() throws {
            let source = MarkdownFormatting.render("## Heading\n\n\nBody")
            let (view, coordinator) = editor(source)
            let offset = (view.string as NSString).range(of: "\n\n").location + 1
            let range = try #require(Range<AttributedString.Index>(NSRange(location: offset, length: 0), in: source))
            coordinator.parent.selection = AttributedTextSelection(insertionPoint: range.lowerBound)
            view.textContainer?.size = CGSize(width: 560, height: 10_000)
            let layout = try #require(view.layoutManager)
            let container = try #require(view.textContainer)
            let bodyRange = (view.string as NSString).range(of: "Body")
            let glyphs = layout.glyphRange(forCharacterRange: bodyRange, actualCharacterRange: nil)
            let bodyBefore = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let before = try #require(view.textStorage?.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)
            coordinator.update(coordinator.parent)
            let typing = try #require(view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
            #expect(typing.lineSpacing == before.lineSpacing)
            #expect(typing.paragraphSpacing == before.paragraphSpacing)
            #expect(typing.paragraphSpacingBefore == before.paragraphSpacingBefore)
            #expect(layout.boundingRect(forGlyphRange: glyphs, in: container) == bodyBefore)
            #expect(view.selectedRange() == NSRange(location: offset, length: 0))
        }

        @Test func localCodeLanguageActionKeepsDocumentSelectionAndOtherBlocks() throws {
            let (view, coordinator) = editor(MarkdownFormatting.render("```swift\nlet x = 1\n```\nBody\n```json\ntrue\n```"))
            let original = view.string
            let body = (original as NSString).range(of: "Body")
            view.setSelectedRange(body)
            let id = try #require(view.textStorage?.attribute(.yoursCodeStyle, at: 0, effectiveRange: nil) as? String)
            coordinator.changeCodeLanguage(id: id, language: "python")
            #expect(view.string == original)
            #expect(view.selectedRange() == body)
            #expect(view.textStorage?.attribute(.yoursCodeLanguage, at: 0, effectiveRange: nil) as? String == "python")
            let second = (original as NSString).range(of: "true")
            #expect(view.textStorage?.attribute(.yoursCodeLanguage, at: second.location, effectiveRange: nil) as? String == "json")
        }

        @Test func codeLanguageAndHighlightsSurviveOnlyAsSemanticAttributes() throws {
            let rendered = MarkdownFormatting.render("```swift\n\nlet value = 42\n```")
            let context = EnvironmentValues().fontResolutionContext
            let native = NativeTextAttributes.native(rendered, context: context)
            #expect(native.attribute(.yoursSyntaxColor, at: 1, effectiveRange: nil) as? Bool == true)
            let rich = NativeTextAttributes.rich(native)
            #expect(rich.runs.allSatisfy { $0.foregroundColor == nil })
            #expect(MarkdownFormatting.serialize(rich, context: context).hasPrefix("```swift\n\n"))
            var note = Note(id: UUID(), text: "", createdAt: Date(), updatedAt: Date())
            note.richText = rich
            let restored = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
            #expect(restored.richText.runs.first?[CodeLanguageAttribute.self] == "swift")
        }

        @Test func formattingCodePreservesOtherBlocksSelectionAndUndo() async throws {
            let (view, coordinator) = editor(
                MarkdownFormatting.render(
                    "~~~javascript\nconst x={name:'中文🌿'};\n~~~\n正文\n~~~python\nprint(1)\n~~~"))
            let window = NSWindow(contentRect: view.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.contentView = view
            view.allowsUndo = true
            let undo = try #require(view.undoManager)
            let original = view.string
            let storage = try #require(view.textStorage)
            let id = try #require(storage.attribute(.yoursCodeStyle, at: 0, effectiveRange: nil) as? String)
            let body = (original as NSString).range(of: "正文")
            view.setSelectedRange(body)
            undo.beginUndoGrouping()
            try await coordinator.formatCode(id: id)
            undo.endUndoGrouping()
            #expect(view.string.contains("const x = { name: \"中文🌿\" };"))
            #expect(view.string.hasSuffix("正文\nprint(1)"))
            #expect((view.string as NSString).substring(with: view.selectedRange()) == "正文")
            #expect(storage.attribute(.yoursCodeStyle, at: 0, effectiveRange: nil) as? String == id)
            let formatted = view.string
            undo.undo()
            #expect(view.string == original)
            #expect(view.selectedRange() == body)
            undo.redo()
            #expect(view.string == formatted)
        }

        @Test func invalidCodeFormattingLeavesDocumentAndUndoUnchanged() async throws {
            let (view, coordinator) = editor(MarkdownFormatting.render("~~~json\n{broken:}\n~~~"))
            let before = view.string
            let storage = try #require(view.textStorage)
            let id = try #require(storage.attribute(.yoursCodeStyle, at: 0, effectiveRange: nil) as? String)
            await #expect(throws: CodeFormatting.Failure.self) { try await coordinator.formatCode(id: id) }
            #expect(view.string == before)
        }

        @Test func staleFormattingCannotOverwriteEditedOrRelabeledCode() throws {
            let (view, coordinator) = editor(MarkdownFormatting.render("~~~javascript\nconst x=1\n~~~"))
            let storage = try #require(view.textStorage)
            let id = try #require(storage.attribute(.yoursCodeStyle, at: 0, effectiveRange: nil) as? String)
            let snapshot = NSAttributedString(attributedString: storage)
            storage.replaceCharacters(in: NSRange(location: 8, length: 1), with: "2")
            #expect(throws: CodeFormatting.Failure.self) {
                try coordinator.applyFormattedCode("const x = 1;", id: id, snapshot: snapshot)
            }
            #expect(view.string == "const x=2")
            storage.setAttributedString(snapshot)
            coordinator.changeCodeLanguage(id: id, language: "typescript")
            #expect(throws: CodeFormatting.Failure.self) {
                try coordinator.applyFormattedCode("const x = 1;", id: id, snapshot: snapshot)
            }
            #expect(storage.attribute(.yoursCodeLanguage, at: 0, effectiveRange: nil) as? String == "typescript")
        }

        @Test func codeIndentSelectionCannotReplaceAdjacentBody() {
            let (view, coordinator) = editor(MarkdownFormatting.render("```swift\nlet x = 1\n```\nBody"))
            view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
            view.typingAttributes = view.textStorage!.attributes(at: 0, effectiveRange: nil)
            let original = view.string
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\t"))
            #expect(view.string == original)
        }

        @Test func codeIndentUndoRedoKeepsCaretBeforeTheOpenTrailingLine() throws {
            let (view, coordinator) = editor(AttributedString("```swift"))
            view.delegate = coordinator
            let window = NSWindow(contentRect: view.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.contentView = view
            view.allowsUndo = true
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            view.insertText("let value = 42", replacementRange: view.selectedRange())
            let undo = try #require(view.undoManager)
            undo.removeAllActions()
            undo.beginUndoGrouping()
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\t"))
            undo.endUndoGrouping()
            #expect(view.selectedRange() == NSRange(location: 16, length: 0))
            undo.undo()
            #expect(view.selectedRange() == NSRange(location: 14, length: 0))
            undo.redo()
            #expect(view.selectedRange() == NSRange(location: 16, length: 0))
            #expect(view.string == "  let value = 42\n")
            #expect(view.typingAttributes[.yoursCodeLanguage] as? String == "swift")
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.string == "  let value = 42\n  \n")
            #expect(view.selectedRange() == NSRange(location: 19, length: 0))
            view.insertText("next", replacementRange: view.selectedRange())
            #expect(view.string == "  let value = 42\n  next\n")
            #expect(view.typingAttributes[.yoursCodeLanguage] as? String == "swift")
        }

        @Test func codeNewlineContinuesIndentAndBlankIndentExits() {
            let (view, coordinator) = editor(MarkdownFormatting.render("```python\n    return 1\n```"))
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.string == "    return 1\n    ")
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.string == "    return 1\n")
            #expect(view.typingAttributes[.yoursCodeStyle] == nil)
            #expect(view.typingAttributes[.yoursCodeLanguage] == nil)
        }

        @Test func editingTableUpdatesPayloadAndDoesNotLeakIntoTyping() throws {
            let table = TableData()
            let (view, coordinator) = editor(table.attributedText + AttributedString("\n"))
            var updated = table
            updated.rows[0][0] = "Saved header"
            coordinator.changeTable(id: table.id, table: updated)
            let rich = NativeTextAttributes.rich(view.textStorage!)
            #expect(rich.runs.first?[TableAttribute.self]?.rows[0][0] == "Saved header")
            view.typingAttributes = view.textStorage!.attributes(at: 0, effectiveRange: nil)
            #expect(coordinator.intercept(range: view.selectedRange(), replacement: "x"))
            #expect(view.typingAttributes[.attachment] == nil)
            #expect(view.typingAttributes[.yoursTable] == nil)
        }

        @Test func strikeShortcutPreservesNextTypingAttributes() {
            let (view, coordinator) = editor(AttributedString("Text ~~done~"))
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "~"))
            #expect(view.string == "Text done")
            #expect(
                view.textStorage?.attribute(.strikethroughStyle, at: 5, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
            #expect(view.typingAttributes[.strikethroughStyle] == nil)
        }

        @Test func headingReturnResetsTypingStyleWithoutChangingHeading() {
            let (view, coordinator) = editor(MarkdownFormatting.render("# 标题"))
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.string == "标题\n")
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")
            #expect(view.textStorage?.attribute(.yoursParagraphStyle, at: 0, effectiveRange: nil) as? String == "heading:1")
        }

        @Test func listBackspaceRemovesPrefixWithoutDeletingText() {
            let (view, coordinator) = editor(AttributedString("• 任务"))
            view.setSelectedRange(NSRange(location: 2, length: 0))
            #expect(!coordinator.intercept(range: NSRange(location: 1, length: 1), replacement: ""))
            #expect(view.string == "任务")
            #expect(view.selectedRange().location == 0)
        }

        @Test func secondReturnOnEmptyQuoteExitsAndClearsTheTrailingQuoteBoundary() {
            let (view, coordinator) = editor(MarkdownFormatting.render("> First"))
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))

            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.string == "First\n")
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.string == "First\n")
            #expect(view.selectedRange() == NSRange(location: view.string.utf16.count, length: 0))
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")
            #expect(view.typingAttributes[.yoursQuote] == nil)
            var quoteRange = NSRange()
            _ = view.textStorage?.attribute(.yoursQuote, at: 0, effectiveRange: &quoteRange)
            let storage = NSTextStorage(attributedString: view.textStorage!)
            let layout = CodeLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 500, height: 10_000))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(forCharacterRange: quoteRange, actualCharacterRange: nil)
            let bar = layout.quoteBarRect(forGlyphRange: glyphs, in: container)
            #expect(bar.maxY <= layout.extraLineFragmentRect.minY)
        }

        @Test func secondReturnOnEmptyQuoteBeforeBodyClearsItsTerminatingBoundary() {
            let (view, coordinator) = editor(MarkdownFormatting.render("> First\nBody"))
            view.delegate = coordinator
            let firstLineEnd = (view.string as NSString).range(of: "\n").location
            view.setSelectedRange(NSRange(location: firstLineEnd, length: 0))

            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.string == "First\n\nBody")
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.string == "First\n\nBody")
            let blankBoundary = (view.string as NSString).range(of: "\n\n").location + 1
            #expect(view.selectedRange() == NSRange(location: blankBoundary, length: 0))
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")
            #expect(view.typingAttributes[.yoursQuote] == nil)
            #expect(view.textStorage?.attribute(.yoursParagraphStyle, at: blankBoundary, effectiveRange: nil) as? String == "body")
            #expect(view.textStorage?.attribute(.yoursQuote, at: blankBoundary, effectiveRange: nil) == nil)

            let storage = NSTextStorage(attributedString: view.textStorage!)
            let layout = CodeLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 500, height: 10_000))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            var quoteRange = NSRange()
            _ = storage.attribute(.yoursQuote, at: 0, effectiveRange: &quoteRange)
            let quoteGlyphs = layout.glyphRange(forCharacterRange: quoteRange, actualCharacterRange: nil)
            let blankGlyph = layout.glyphIndexForCharacter(at: blankBoundary)
            #expect(
                layout.quoteBarRect(forGlyphRange: quoteGlyphs, in: container).maxY
                    <= layout.lineFragmentRect(forGlyphAt: blankGlyph, effectiveRange: nil).minY)
        }

        @Test func backspaceOnEmptyQuoteContinuationExitsBeforeMergingParagraphs() {
            let (view, coordinator) = editor(MarkdownFormatting.render("> First\n> "))
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))

            #expect(view.string == "First\n")
            view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            #expect(view.string == "First\n")
            #expect(view.typingAttributes[.yoursQuote] == nil)
            #expect(view.selectedRange() == NSRange(location: view.string.utf16.count, length: 0))
            view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            #expect(view.string == "First")
            #expect(view.selectedRange() == NSRange(location: view.string.utf16.count, length: 0))
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
            #expect(
                MarkdownFormatting.serialize(
                    NativeTextAttributes.rich(view.textStorage!), context: EnvironmentValues().fontResolutionContext) == "> First")
        }

        @Test func deletingAllQuoteTextKeepsTheEmptyQuoteTypingState() {
            let (view, coordinator) = editor(MarkdownFormatting.render("> 引用"))
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))

            while !view.string.isEmpty { view.deleteBackward(nil) }

            #expect(view.string.isEmpty)
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")
            coordinator.update(coordinator.parent)
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
            view.insertText("继续", replacementRange: view.selectedRange())
            #expect(view.textStorage?.attribute(.yoursQuote, at: 0, effectiveRange: nil) as? Bool == true)
        }

        @Test func backspaceOnAnEmptyQuoteExitsBeforeFollowingTextIsTyped() {
            let (view, coordinator) = editor(MarkdownFormatting.render("> 引用"))
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))

            while !view.string.isEmpty { view.deleteBackward(nil) }
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)

            view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            #expect(view.typingAttributes[.yoursQuote] == nil)
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "body")

            view.insertText("正文", replacementRange: view.selectedRange())
            #expect(view.textStorage?.attribute(.yoursQuote, at: 0, effectiveRange: nil) == nil)
            #expect(view.textStorage?.attribute(.yoursParagraphStyle, at: 0, effectiveRange: nil) as? String == "body")
        }

        @Test func deletingLastQuoteCharacterRestoresQuoteFromStorageWhenAppKitDropsTypingState() {
            let (view, coordinator) = editor(MarkdownFormatting.render("> 1"))
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: 1, length: 0))
            view.typingAttributes.removeValue(forKey: .yoursQuote)

            #expect(!coordinator.intercept(range: NSRange(location: 0, length: 1), replacement: ""))
            #expect(view.string.isEmpty)
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
            coordinator.update(coordinator.parent)
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
        }

        @Test func readingTextViewPreservesQuoteAfterItsLastCharacterIsDeleted() {
            let source = MarkdownFormatting.render("> 1")
            var text = source
            var selection = AttributedTextSelection(insertionPoint: source.endIndex)
            let editor = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }), selection: Binding(get: { selection }, set: { selection = $0 }))
            let coordinator = editor.makeCoordinator()
            let view = ReadingMacTextView()
            let native = NativeTextAttributes.native(source, context: EnvironmentValues().fontResolutionContext)
            view.textStorage?.setAttributedString(native)
            view.setSelectedRange(NSRange(location: 1, length: 0))
            view.typingAttributes = native.attributes(at: 0, effectiveRange: nil)
            view.delegate = coordinator
            view.didResolveTypingAttributes = {
                coordinator.textViewDidChangeSelection(Notification(name: NSTextView.didChangeSelectionNotification, object: view))
            }
            coordinator.textView = view

            view.deleteBackward(nil)
            coordinator.update(coordinator.parent)

            #expect(view.string.isEmpty)
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
        }

        @Test func deletingLastQuoteCharacterKeepsTheBarGeometryStable() throws {
            let source = MarkdownFormatting.render("> 1")
            var text = source
            var selection = AttributedTextSelection(insertionPoint: source.endIndex)
            let editor = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                selection: Binding(get: { selection }, set: { selection = $0 })
            )
            let coordinator = editor.makeCoordinator()
            let native = NativeTextAttributes.native(source, context: EnvironmentValues().fontResolutionContext)
            let storage = NSTextStorage(attributedString: native)
            let layout = CodeLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 500, height: 10_000))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            let view = ReadingMacTextView(
                frame: CGRect(x: 0, y: 0, width: 500, height: 320),
                textContainer: container
            )
            let window = NSWindow(
                contentRect: view.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = view
            view.delegate = coordinator
            coordinator.textView = view
            view.setSelectedRange(NSRange(location: native.length, length: 0))
            view.typingAttributes = native.attributes(at: 0, effectiveRange: nil)
            layout.ensureLayout(for: container)

            let filled = layout.quoteBarRect(
                forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs),
                in: container
            ).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)

            view.deleteBackward(nil)
            coordinator.update(coordinator.parent)
            let empty = try #require(view.emptyQuoteBarDrawingRect())

            #expect(view.string.isEmpty)
            #expect(abs(filled.minY - empty.minY) < 0.01)
            #expect(abs(filled.maxY - empty.maxY) < 0.01)
        }

        @Test func firstReturnExtendsOneQuoteBarThroughTheTrailingEmptyLine() throws {
            let source = MarkdownFormatting.render("> 1")
            var text = source
            var selection = AttributedTextSelection(insertionPoint: source.endIndex)
            let editor = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                selection: Binding(get: { selection }, set: { selection = $0 })
            )
            let coordinator = editor.makeCoordinator()
            let native = NativeTextAttributes.native(source, context: EnvironmentValues().fontResolutionContext)
            let storage = NSTextStorage(attributedString: native)
            let layout = CodeLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 500, height: 10_000))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            let view = ReadingMacTextView(
                frame: CGRect(x: 0, y: 0, width: 500, height: 320),
                textContainer: container
            )
            let window = NSWindow(
                contentRect: view.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = view
            view.delegate = coordinator
            coordinator.textView = view
            view.setSelectedRange(NSRange(location: native.length, length: 0))
            view.typingAttributes = native.attributes(at: 0, effectiveRange: nil)

            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            layout.ensureLayout(for: container)
            let empty = try #require(view.emptyQuoteBarDrawingRect())
            let glyphs = layout.glyphRange(
                forCharacterRange: NSRange(location: 0, length: storage.length),
                actualCharacterRange: nil
            )
            let bars = layout.quoteBarDrawingRects(
                forGlyphRange: glyphs,
                at: view.textContainerOrigin,
                trailingEmptyBar: empty
            )

            #expect(view.string == "1\n")
            #expect(bars.count == 1)
            #expect(bars[0].contains(empty))
            #expect(bars[0].minY < empty.minY)
        }

        @Test func secondReturnAtDocumentEndExitsTheTrailingEmptyQuote() throws {
            let frameInitializedView = ReadingMacTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 320))
            #expect(frameInitializedView.subviews.count == 1)
            var text = AttributedString()
            var selection = AttributedTextSelection(insertionPoint: text.startIndex)
            let editor = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                selection: Binding(get: { selection }, set: { selection = $0 })
            )
            let coordinator = editor.makeCoordinator()
            let storage = NSTextStorage()
            let layout = CodeLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 500, height: 10_000))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            let view = ReadingMacTextView(
                frame: CGRect(x: 0, y: 0, width: 500, height: 320),
                textContainer: container
            )
            let window = NSWindow(
                contentRect: view.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = view
            view.delegate = coordinator
            coordinator.textView = view
            view.setSelectedRange(NSRange(location: 0, length: 0))
            var bodySample = AttributedString("\n")
            bodySample.font = .body
            bodySample[ParagraphStyleAttribute.self] = "body"
            let nativeBody = NativeTextAttributes.native(bodySample, context: EnvironmentValues().fontResolutionContext)
            view.typingAttributes = nativeBody.attributes(at: 0, effectiveRange: nil)

            layout.ensureLayout(for: container)
            let bodyExtraLineX = layout.extraLineFragmentUsedRect.minX
            view.insertText(">", replacementRange: view.selectedRange())
            view.insertText(" ", replacementRange: view.selectedRange())
            coordinator.update(coordinator.parent)
            let emptyQuoteStyle = try #require(view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
            #expect(view.string.isEmpty)
            #expect(emptyQuoteStyle.firstLineHeadIndent == DocumentTypography.quoteIndent)
            #expect(abs(layout.extraLineFragmentUsedRect.minX - bodyExtraLineX - DocumentTypography.quoteIndent) < 0.5)
            view.insertText("1", replacementRange: view.selectedRange())
            #expect(view.string == "1")
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)

            view.insertNewline(nil)
            coordinator.update(coordinator.parent)
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
            #expect(view.emptyQuoteBarDrawingRect() != nil)
            let quotedSelection = selection
            view.insertNewline(nil)
            let staleParent = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                selection: .constant(quotedSelection)
            )
            coordinator.update(staleParent)
            layout.ensureLayout(for: container)

            #expect(view.string == "1\n")
            #expect(view.selectedRange() == NSRange(location: 2, length: 0))
            #expect(view.typingAttributes[.yoursQuote] == nil)
            #expect(view.emptyQuoteBarDrawingRect() == nil)
            let bodyTypingStyle = try #require(view.typingAttributes[.paragraphStyle] as? NSParagraphStyle)
            #expect(bodyTypingStyle.firstLineHeadIndent == 0)
            #expect(bodyTypingStyle.headIndent == 0)
            view.insertText("Body", replacementRange: view.selectedRange())
            let insertedStyle = try #require(storage.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle)
            #expect(insertedStyle.firstLineHeadIndent == 0)
            #expect(insertedStyle.headIndent == 0)
            layout.ensureLayout(for: container)
            let bodyGlyph = layout.glyphIndexForCharacter(at: 2)
            let bodyLine = layout.lineFragmentRect(forGlyphAt: bodyGlyph, effectiveRange: nil)
            let glyphs = layout.glyphRange(
                forCharacterRange: NSRange(location: 0, length: storage.length),
                actualCharacterRange: nil
            )
            let bars = layout.quoteBarDrawingRects(forGlyphRange: glyphs, at: view.textContainerOrigin)
            #expect(bars.count == 1)
            #expect(bars[0].maxY <= bodyLine.minY + view.textContainerOrigin.y)
        }

        @Test func emptyTaskShortcutInsideQuoteDrawsARealCheckboxWithoutPlaceholderText() throws {
            let source = MarkdownFormatting.render("> 1")
            var text = source
            var selection = AttributedTextSelection(insertionPoint: source.endIndex)
            let editor = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                selection: Binding(get: { selection }, set: { selection = $0 })
            )
            let coordinator = editor.makeCoordinator()
            let native = NativeTextAttributes.native(source, context: EnvironmentValues().fontResolutionContext)
            let storage = NSTextStorage(attributedString: native)
            let layout = CodeLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 500, height: 10_000))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            let view = ReadingMacTextView(
                frame: CGRect(x: 0, y: 0, width: 500, height: 320),
                textContainer: container
            )
            let window = NSWindow(
                contentRect: view.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = view
            view.delegate = coordinator
            coordinator.textView = view
            view.setSelectedRange(NSRange(location: native.length, length: 0))
            view.typingAttributes = native.attributes(at: 0, effectiveRange: nil)

            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            view.insertText("[", replacementRange: view.selectedRange())
            view.insertText("]", replacementRange: view.selectedRange())
            view.insertText(" ", replacementRange: view.selectedRange())
            layout.ensureLayout(for: container)

            let marker = try #require(view.emptyTaskMarkerDrawingRect())
            let quote = try #require(view.emptyQuoteBarDrawingRect())
            #expect(view.string == "1\n")
            #expect(!view.string.contains("☐"))
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "task")
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
            #expect(view.typingAttributes[.yoursTaskChecked] as? Bool == false)
            #expect(marker.minX > quote.maxX)
            #expect(coordinator.toggleEmptyTask())
            #expect(view.typingAttributes[.yoursTaskChecked] as? Bool == true)
        }

        @Test func firstDocumentLineKeepsQuoteBarGeometryWhenAnEmptyTaskGetsText() throws {
            var text = AttributedString()
            var selection = AttributedTextSelection(insertionPoint: text.startIndex)
            let editor = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }),
                selection: Binding(get: { selection }, set: { selection = $0 })
            )
            let coordinator = editor.makeCoordinator()
            let storage = NSTextStorage()
            let layout = CodeLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 500, height: 10_000))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            let view = ReadingMacTextView(
                frame: CGRect(x: 0, y: 0, width: 500, height: 320),
                textContainer: container
            )
            let window = NSWindow(
                contentRect: view.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = view
            var body = AttributedString(" ")
            body.font = .body
            body[ParagraphStyleAttribute.self] = "body"
            view.typingAttributes = NativeTextAttributes.native(
                body,
                context: EnvironmentValues().fontResolutionContext
            ).attributes(at: 0, effectiveRange: nil)
            view.delegate = coordinator
            coordinator.textView = view

            for character in "> [] " {
                view.insertText(String(character), replacementRange: view.selectedRange())
            }
            layout.ensureLayout(for: container)
            let immediateEmptyBar = try #require(view.emptyQuoteBarDrawingRect())
            coordinator.update(coordinator.parent)
            layout.ensureLayout(for: container)
            let emptyBar = try #require(view.emptyQuoteBarDrawingRect())

            view.insertText("1", replacementRange: view.selectedRange())
            layout.ensureLayout(for: container)
            let immediateGlyphs = layout.glyphRange(
                forCharacterRange: NSRange(location: 0, length: storage.length),
                actualCharacterRange: nil
            )
            let immediateFilledBar = layout.quoteBarRect(
                forGlyphRange: immediateGlyphs,
                in: container
            ).offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
            coordinator.update(coordinator.parent)
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(
                forCharacterRange: NSRange(location: 0, length: storage.length),
                actualCharacterRange: nil
            )
            let filledBar = layout.quoteBarRect(forGlyphRange: glyphs, in: container).offsetBy(
                dx: view.textContainerOrigin.x,
                dy: view.textContainerOrigin.y
            )

            #expect(abs(immediateEmptyBar.minY - emptyBar.minY) < 0.01)
            #expect(abs(immediateEmptyBar.maxY - emptyBar.maxY) < 0.01)
            #expect(abs(emptyBar.minY - immediateFilledBar.minY) < 0.01)
            #expect(abs(emptyBar.maxY - immediateFilledBar.maxY) < 0.01)
            #expect(abs(emptyBar.minY - filledBar.minY) < 0.01)
            #expect(abs(emptyBar.maxY - filledBar.maxY) < 0.01)
        }

        @Test func commandBackspaceRestoresEmptyQuoteAfterAppKitChangesTheText() {
            let (view, coordinator) = editor(MarkdownFormatting.render("> 1"))
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: 1, length: 0))

            view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            coordinator.update(coordinator.parent)

            #expect(view.string.isEmpty)
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
        }

        @Test func textDidChangeRestoresQuoteFromThePreviousNativeSnapshot() {
            let (view, coordinator) = editor(MarkdownFormatting.render("> 1"))
            view.delegate = coordinator
            coordinator.update(coordinator.parent)
            view.textStorage?.deleteCharacters(in: NSRange(location: 0, length: 1))
            view.setSelectedRange(NSRange(location: 0, length: 0))
            view.typingAttributes.removeValue(forKey: .yoursQuote)

            coordinator.textDidChange(Notification(name: NSText.didChangeNotification, object: view))
            coordinator.update(coordinator.parent)

            #expect(view.string.isEmpty)
            #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
        }

        @Test(arguments: ["`code`", "**bold**", "*italic*", "~~strike~~"])
        func deletingAnEntireInlineFormatResetsFollowingTyping(source: String) {
            let (view, coordinator) = editor(MarkdownFormatting.render(source))
            view.delegate = coordinator
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))

            while !view.string.isEmpty { view.deleteBackward(nil) }
            #expect(view.string.isEmpty)
            view.insertText("next", replacementRange: view.selectedRange())
            #expect(view.string == "next")
            #expect(view.textStorage?.attribute(.yoursCodeStyle, at: 0, effectiveRange: nil) == nil)
            #expect((view.textStorage?.attribute(.yoursInlineEmphasis, at: 0, effectiveRange: nil) as? Int ?? 0) == 0)
            #expect((view.textStorage?.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int ?? 0) == 0)
        }

        @Test(arguments: [false, true], [" ", "\n"])
        func emptyCodeFenceShowsHeaderBeforeTyping(quoted: Bool, trigger: String) throws {
            var source = AttributedString("```")
            if quoted { source[QuoteAttribute.self] = true }
            let (view, coordinator) = editor(source)
            view.delegate = coordinator
            let window = NSWindow(contentRect: view.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.contentView = view
            view.allowsUndo = true
            let undo = try #require(view.undoManager)
            undo.beginUndoGrouping()
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: trigger))
            undo.endUndoGrouping()
            #expect(view.string == "\n")
            #expect(view.selectedRange() == NSRange(location: 0, length: 0))
            let storage = try #require(view.textStorage)
            let id = try #require(storage.attribute(.yoursCodeStyle, at: 0, effectiveRange: nil) as? String)
            #expect(id.hasPrefix("block:"))
            #expect(view.subviews.contains { $0 is NSHostingView<CodeHeaderView> })
            let restored = NativeTextAttributes.native(
                NativeTextAttributes.rich(storage), context: EnvironmentValues().fontResolutionContext)
            #expect(restored.attribute(.yoursCodeStyle, at: 0, effectiveRange: nil) as? String == id)
            undo.undo()
            #expect(view.string == "```" + trigger)
            undo.redo()
            #expect(view.string == "\n")
            coordinator.changeCodeLanguage(id: id, language: "swift")
            #expect(view.typingAttributes[.yoursCodeLanguage] as? String == "swift")
            view.insertText("let a = 1", replacementRange: view.selectedRange())
            #expect(view.string == "let a = 1\n")
            #expect(storage.attribute(.yoursCodeStyle, at: 0, effectiveRange: nil) as? String == id)
            // Return from the trailing empty code paragraph exits while keeping its quote.
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.typingAttributes[.yoursCodeStyle] == nil)
            #expect((view.typingAttributes[.yoursQuote] as? Bool == true) == quoted)
        }

        @Test func codeEntryAndEmptyLineExitKeepNativeTypingState() {
            let (view, coordinator) = editor(AttributedString("```swift"))
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.string == "\n")
            #expect((view.typingAttributes[.yoursCodeStyle] as? String)?.hasPrefix("block:") == true)
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.typingAttributes[.yoursCodeStyle] == nil)
        }

        @Test func markdownShortcutsInsideQuoteKeepTheOuterQuote() {
            for (syntax, expectedRole) in [("-", "bullet"), ("1.", "numbered"), ("- [ ]", "task")] {
                let (view, coordinator) = editor(AttributedString())
                view.delegate = coordinator
                for character in "> " + syntax + " " {
                    view.insertText(String(character), replacementRange: view.selectedRange())
                }
                #expect(view.typingAttributes[.yoursQuote] as? Bool == true)
                #expect(view.typingAttributes[.yoursParagraphStyle] as? String == expectedRole)
                view.insertText("内容", replacementRange: view.selectedRange())
                #expect(view.textStorage?.attribute(.yoursQuote, at: 0, effectiveRange: nil) as? Bool == true)
                #expect(view.textStorage?.attribute(.yoursParagraphStyle, at: 0, effectiveRange: nil) as? String == expectedRole)
            }

            let (codeView, codeCoordinator) = editor(AttributedString())
            codeView.delegate = codeCoordinator
            for character in "> ```swift" {
                codeView.insertText(String(character), replacementRange: codeView.selectedRange())
            }
            #expect(!codeCoordinator.intercept(range: codeView.selectedRange(), replacement: "\n"))
            #expect(codeView.string == "\n")
            #expect(codeView.typingAttributes[.yoursQuote] as? Bool == true)
            #expect((codeView.typingAttributes[.yoursCodeStyle] as? String)?.hasPrefix("block:") == true)
        }

        @Test func pastedURLKeepsSelectedLabel() {
            let (view, coordinator) = editor(AttributedString("网站"))
            view.setSelectedRange(NSRange(location: 0, length: 2))
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "https://apple.com"))
            #expect(view.string == "网站")
            #expect(view.textStorage?.attribute(.link, at: 0, effectiveRange: nil) as? URL == URL(string: "https://apple.com"))
        }

        @Test func adjacentInlineCodeShortcutPreservesHeadingAndSurroundingText() {
            for role in ["body", "heading:1"] {
                var source = AttributedString("\u{624B}\u{518C}`value\u{540E}")
                source[ParagraphStyleAttribute.self] = role
                source.font = ParagraphEditing.font(for: role)
                let (view, coordinator) = editor(source)
                view.setSelectedRange(NSRange(location: 8, length: 0))
                #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "`"))
                #expect(view.string == "\u{624B}\u{518C}value\u{540E}")
                #expect(view.textStorage!.attribute(.yoursCodeStyle, at: 2, effectiveRange: nil) as? String == "inline")
                #expect(view.textStorage!.attribute(.yoursCodeStyle, at: 0, effectiveRange: nil) == nil)
                #expect(view.textStorage!.attribute(.yoursCodeStyle, at: 7, effectiveRange: nil) == nil)
                #expect(view.textStorage!.attribute(.yoursParagraphStyle, at: 2, effectiveRange: nil) as? String == role)
                #expect(view.typingAttributes[.yoursCodeStyle] == nil)
            }
        }

        @Test func adjacentItalicAndStrikeShortcutsPreserveSurroundingText() {
            for role in ["body", "heading:1"] {
                for marker in ["*", "~~"] {
                    for suffix in ["后文", "`code`"] {
                        let before = "正文😀" + marker + "内容" + marker.dropLast()
                        var source = AttributedString(before + suffix)
                        source[ParagraphStyleAttribute.self] = role
                        source.font = ParagraphEditing.font(for: role)
                        let (view, coordinator) = editor(source)
                        view.setSelectedRange(NSRange(location: before.utf16.count, length: 0))
                        #expect(!coordinator.intercept(range: view.selectedRange(), replacement: String(marker.last!)))
                        #expect(view.string == "正文😀内容" + suffix)
                        #expect(view.selectedRange() == NSRange(location: 6, length: 0))
                        #expect(view.textStorage!.attribute(.yoursParagraphStyle, at: 4, effectiveRange: nil) as? String == role)
                        if marker == "*" {
                            #expect((view.textStorage!.attribute(.yoursInlineEmphasis, at: 4, effectiveRange: nil) as? Int ?? 0) & 2 == 2)
                            #expect((view.typingAttributes[.yoursInlineEmphasis] as? Int ?? 0) & 2 == 0)
                        } else {
                            #expect(
                                view.textStorage!.attribute(.strikethroughStyle, at: 4, effectiveRange: nil) as? Int
                                    == NSUnderlineStyle.single.rawValue)
                            #expect((view.typingAttributes[.strikethroughStyle] as? Int ?? 0) == 0)
                        }
                    }
                }
            }
        }

        @Test func boldShortcutAfterChineseTextOnlyFormatsMarkedContent() throws {
            let (view, coordinator) = editor(AttributedString("正文**加粗*"))
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "*"))
            #expect(view.string == "正文加粗")
            let storage = try #require(view.textStorage)
            let font = try #require(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
            #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
            let bodyFont = try #require(view.typingAttributes[.font] as? NSFont)
            #expect(!NSFontManager.shared.traits(of: bodyFont).contains(.boldFontMask))
        }

        @Test func exitingPopulatedCodeBlockPersistsBodyBoundary() {
            var source = AttributedString("let value = 1\n")
            source.font = .body.monospaced()
            source[CodeStyleAttribute.self] = "block:test"
            source[ParagraphStyleAttribute.self] = "code"
            let (view, coordinator) = editor(source)
            #expect(!coordinator.intercept(range: view.selectedRange(), replacement: "\n"))
            #expect(view.typingAttributes[.yoursCodeStyle] == nil)
            let boundary = view.textStorage!.length - 1
            #expect(view.textStorage!.attribute(.yoursCodeStyle, at: boundary, effectiveRange: nil) == nil)
            #expect(view.textStorage!.attribute(.yoursCodeStyle, at: 0, effectiveRange: nil) as? String == "block:test")
        }
    }
#endif
