#if os(macOS)
    import AppKit
    import SwiftUI
    import Testing
    @testable import Yours

    @MainActor
    struct NativeCommandTests {
        @Test func slashConversionRestoresTextSelectionAndTypingWithOneUndo() throws {
            let (view, coordinator, window) = editor(AttributedString("中文🌿 /h2"))
            defer { window.orderOut(nil) }
            let undo = try #require(view.undoManager)
            let before = view.selectedRange()
            let slash = (view.string as NSString).range(of: "/h2")
            undo.beginUndoGrouping()
            coordinator.performControlAction(.paragraph("heading:2"), range: before, slash: slash)
            undo.endUndoGrouping()
            #expect(view.string == "中文🌿 ")
            #expect(view.textStorage?.attribute(.yoursParagraphStyle, at: 0, effectiveRange: nil) as? String == "heading:2")
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "heading:2")
            undo.undo()
            #expect(view.string == "中文🌿 /h2")
            #expect(view.selectedRange() == before)
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String != "heading:2")
            undo.redo()
            #expect(view.string == "中文🌿 ")
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "heading:2")
        }

        @Test func emptySlashKeepsStyleForSubsequentInput() {
            let (view, coordinator, window) = editor(AttributedString("/h1"))
            defer { window.orderOut(nil) }
            coordinator.performControlAction(.paragraph("heading:1"), range: view.selectedRange(), slash: NSRange(location: 0, length: 3))
            #expect(view.string.isEmpty)
            #expect(view.typingAttributes[.yoursParagraphStyle] as? String == "heading:1")
            view.insertText("输入🌿", replacementRange: view.selectedRange())
            #expect(view.textStorage?.attribute(.yoursParagraphStyle, at: 0, effectiveRange: nil) as? String == "heading:1")
        }

        @Test func consecutiveInlineActionsPreserveNativeSelection() {
            let (view, coordinator, window) = editor(AttributedString("中文🌿 text"))
            defer { window.orderOut(nil) }
            let range = NSRange(location: 0, length: 4)
            view.setSelectedRange(range)
            coordinator.performControlAction(.emphasis(1), range: range)
            coordinator.performControlAction(.emphasis(2), range: range)
            #expect(view.selectedRange() == range)
            #expect(view.textStorage?.attribute(.yoursInlineEmphasis, at: 0, effectiveRange: nil) as? Int == 3)
            #expect(view.textStorage?.attribute(.yoursInlineEmphasis, at: 5, effectiveRange: nil) as? Int != 3)
        }

        @Test func unsupportedConversionLeavesSlashLiteral() {
            let source = MarkdownFormatting.render("```swift\n/h2\n```")
            let (view, coordinator, window) = editor(source)
            defer { window.orderOut(nil) }
            let before = view.string
            let slash = (before as NSString).range(of: "/h2")
            coordinator.performControlAction(.paragraph("heading:2"), range: view.selectedRange(), slash: slash)
            #expect(view.string == before)
        }

        private final class ComposingTextView: NSTextView {
            override func hasMarkedText() -> Bool { true }
        }

        @Test func markedTextPreventsSlashAndSelectionCommandsFromMutating() {
            let composing = ComposingTextView()
            let (view, coordinator, window) = editor(AttributedString("拼音 /h2"), view: composing)
            defer { window.orderOut(nil) }
            let before = NSAttributedString(attributedString: view.textStorage ?? NSTextStorage())
            let slash = (view.string as NSString).range(of: "/h2")
            coordinator.performControlAction(.paragraph("heading:2"), range: view.selectedRange(), slash: slash)
            view.setSelectedRange(NSRange(location: 0, length: 2))
            coordinator.performControlAction(.emphasis(1), range: view.selectedRange())
            coordinator.controlsAfterTyping()
            coordinator.controlsAfterSelection()
            #expect(coordinator.handleControlKey("return") == false)
            #expect(coordinator.handleControlKey("down") == false)
            #expect(view.textStorage?.isEqual(to: before) == true)
            #expect(view.selectedRange() == NSRange(location: 0, length: 2))
        }

        private func editor(_ source: AttributedString, view: NSTextView = NSTextView()) -> (
            NSTextView, NativeRichTextEditor.Coordinator, NSWindow
        ) {
            var text = source
            var selection = AttributedTextSelection(insertionPoint: source.endIndex)
            let parent = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }), selection: Binding(get: { selection }, set: { selection = $0 }))
            let coordinator = parent.makeCoordinator()
            let native = NativeTextAttributes.native(source, context: EnvironmentValues().fontResolutionContext)
            view.textStorage?.setAttributedString(native)
            view.setSelectedRange(NSRange(location: native.length, length: 0))
            if native.length > 0 { view.typingAttributes = native.attributes(at: native.length - 1, effectiveRange: nil) }
            view.allowsUndo = true
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            coordinator.textView = view
            return (view, coordinator, window)
        }
    }
#endif
