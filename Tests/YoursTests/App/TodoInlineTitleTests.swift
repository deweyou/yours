#if os(macOS)
    import AppKit
    import Testing
    @testable import Yours

    @MainActor
    @Suite("Todo inline titles", .serialized)
    struct TodoInlineTitleTests {
        private func editor(_ title: String, width: CGFloat = 240) -> TodoTitleTextView {
            let view = TodoTitleTextView(frame: CGRect(x: 0, y: 0, width: width, height: 100))
            view.font = .preferredFont(forTextStyle: .body)
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
            view.textContainer?.containerSize = NSSize(width: width, height: 1000)
            view.string = title
            view.originalTitle = title
            return view
        }

        @Test func whitespaceFallsThroughWhileTextRemainsEditable() throws {
            let view = editor("中文任务 👨‍👩‍👧‍👦")
            let parent = NSView(frame: view.frame)
            parent.addSubview(view)
            let rect = try #require(view.titleRects().first)
            #expect(view.hitTest(view.convert(CGPoint(x: rect.midX, y: rect.midY), to: parent)) === view)
            #expect(view.hitTest(view.convert(CGPoint(x: 230, y: rect.midY), to: parent)) == nil)
            view.isEditable = false
            #expect(view.hitTest(view.convert(CGPoint(x: rect.midX, y: rect.midY), to: parent)) == nil)
        }

        @Test func wrappedLastLineDoesNotConsumeTrailingWhitespace() throws {
            let view = editor("设计任务详情结构和子任务的编辑操作", width: 95)
            let rects = view.titleRects()
            #expect(rects.count > 1)
            let last = try #require(rects.last)
            #expect(last.width < 95)
            #expect(!rects.contains { $0.contains(CGPoint(x: 94, y: last.midY)) })
        }

        @Test func blurCommitsAndEscapeRestoresOriginal() {
            let view = editor("原始标题")
            var committed: [String] = []
            var cancelled = false
            view.onCommit = { committed.append($0) }
            view.onCancel = { cancelled = true }
            #expect(view.becomeFirstResponder())
            view.string = "修改标题"
            #expect(view.resignFirstResponder())
            #expect(committed == ["修改标题"])
            #expect(view.becomeFirstResponder())
            view.string = "不保存"
            // With no window, cancel marks the draft; resign simulates the subsequent focus change.
            view.cancelOperation(nil)
            #expect(view.resignFirstResponder())
            #expect(cancelled)
            #expect(view.string == "原始标题")
            #expect(committed.count == 1)
        }

        @Test func candidateReturnKeepsTheDraftAndPlainReturnCommits() {
            let view = editor("任务")
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = view
            window.makeFirstResponder(view)
            var committed: String?
            view.onCommit = { committed = $0 }
            view.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 2))
            view.insertNewline(nil)
            #expect(view.hasMarkedText())
            #expect(view.isEditingTitle)
            #expect(committed == nil)
            view.unmarkText()
            view.insertNewline(nil)
            #expect(committed == "中文")
            #expect(view.isEditingTitle == false)
            window.orderOut(nil)
        }

        @Test func titleUndoDoesNotShareWindowUndoHistory() {
            let first = editor("甲")
            let second = editor("乙")
            #expect(first.undoManager !== second.undoManager)
        }
    }
#endif
