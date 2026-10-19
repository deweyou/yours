import SwiftUI
import Testing

@testable import Yours

@MainActor
struct RenderedContentTests {
    private let context = EnvironmentValues().fontResolutionContext

    @Test func sourceEditorPreservesCompositionIndentationAndUndo() throws {
        #if os(macOS)
            var source = "graph LR\n    A"
            let editor = SourceCodeEditor(source: Binding(get: { source }, set: { source = $0 }), kind: .mermaid)
            let scroll = editor.makeEditor()
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: .titled, backing: .buffered, defer: false)
            window.contentView = scroll
            defer { window.orderOut(nil) }
            scroll.tile()
            let view = try #require(scroll.documentView as? NSTextView)
            #expect(view.frame.width > 400)
            #expect(view.frame.height > 200)
            let undo = try #require(view.undoManager)
            undo.groupsByEvent = false
            view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
            undo.beginUndoGrouping()
            view.insertNewline(nil)
            view.insertTab(nil)
            undo.endUndoGrouping()
            #expect(source == "graph LR\n    A\n        ")
            undo.undo()
            #expect(source == "graph LR\n    A")
            undo.beginUndoGrouping()
            view.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0), replacementRange: view.selectedRange())
            #expect(view.hasMarkedText())
            #expect(source == "graph LR\n    A")
            view.insertText("中", replacementRange: view.markedRange())
            undo.endUndoGrouping()
            #expect(!view.hasMarkedText())
            #expect(source == "graph LR\n    A中")
        #endif
    }

    @Test(arguments: [
        "正文 $\\frac{a_1}{b^2}$ 后文", "$$\n\\int_0^1 x^2 dx\n$$", "$$x^2$$",
        "```mermaid\ngraph TD\nA-->B\n```", "> $$\n> x+y\n> $$", "**$a_b$** 和 `$literal$`",
    ])
    func markdownNativeClipboardAndDiskRoundTrip(markdown: String) throws {
        let original = MarkdownFormatting.render(markdown)
        let objects = original.runs.compactMap { $0[RenderedContentAttribute.self] }
        #expect(objects.isEmpty == false)
        let native = NativeTextAttributes.native(original, context: context)
        let restored = NativeTextAttributes.rich(native)
        #expect(restored.runs.compactMap { $0[RenderedContentAttribute.self] } == objects)
        let exported = MarkdownFormatting.serialize(restored, context: context)
        let reparsed = MarkdownFormatting.render(exported).runs.compactMap { $0[RenderedContentAttribute.self] }
        #expect(reparsed.map(\.source) == objects.map(\.source))
        #expect(reparsed.map(\.kind) == objects.map(\.kind))
        let copied = try RichTextClipboard.decode(RichTextClipboard.encode(original))
        let pasted = copied.runs.compactMap { $0[RenderedContentAttribute.self] }
        #expect(pasted.map(\.source) == objects.map(\.source))
        #expect(pasted.map(\.id) != objects.map(\.id))
        #expect(RichTextClipboard.renderMarkdown(markdown) != nil)
        var note = Note(id: UUID(), text: "", createdAt: .now, updatedAt: .now)
        note.richText = original
        let disk = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
        #expect(disk.richText == original)
        #expect(disk.text.contains("\u{FFFC}") == false)
    }

    @Test(arguments: [
        "价格 $20 和 $30", #"转义 \$x\$"#, "`$x$`", "```swift\nlet x = \"$a$\"\n```", "[link](https://example.com/$x$)", "$ unclosed $",
        "$$unclosed", "$x\ny$",
    ])
    func literalDollarsAndCodeAreNotFormulas(source: String) {
        let parsed = MarkdownFormatting.render(source)
        #expect(parsed.runs.allSatisfy { $0[RenderedContentAttribute.self] == nil })
        let exported = MarkdownFormatting.serialize(parsed, context: context)
        #expect(MarkdownFormatting.render(exported).runs.allSatisfy { $0[RenderedContentAttribute.self] == nil })
    }

    @Test(arguments: [
        #"$$\Gamma(z) = \int_0^\infty t^{z-1}e^{-t}dt,.$$"#,
        "$$\n" + #"\Gamma(z) = \int_0^\infty t^{z-1}e^{-t}dt,."# + "\n$$",
        "$$\u{2028}" + #"\Gamma(z) = \int_0^\infty t^{z-1}e^{-t}dt,."# + "\u{2028}$$",
    ])
    func standaloneFormulaOverridesRichClipboard(source: String) throws {
        let parsed = try #require(RichTextClipboard.renderMarkdown(source, hasRichText: true))
        let objects = parsed.runs.compactMap { $0[RenderedContentAttribute.self] }
        #expect(objects.count == 1)
        #expect(objects.first?.kind == .displayMath)
        #expect(objects.first?.source == #"\Gamma(z) = \int_0^\infty t^{z-1}e^{-t}dt,."#)
    }

    @Test(arguments: ["**bold**", "正文 $x$", "价格 $20 和 $30", "$$unclosed", "$x$ and $y$"])
    func richClipboardKeepsNativeFormatting(source: String) {
        #expect(RichTextClipboard.renderMarkdown(source, hasRichText: true) == nil)
    }

    @Test func mixedRichPasteConvertsMathAndPreservesSurroundingAttributes() throws {
        #if os(macOS)
            let source =
                "KaTeX\nThe Gamma function $\\Gamma(n) = (n-1)!$ is an integral\n$$\u{2028}\\Gamma(z) = \\int_0^\\infty t^{z-1}e^{-t}dt,.\u{2028}$$\nMore information here."
            let native = NSMutableAttributedString(string: source, attributes: [.font: NSFont.systemFont(ofSize: 18)])
            let string = source as NSString
            let titleRange = string.range(of: "KaTeX")
            let titleFont = NSFont.boldSystemFont(ofSize: 28)
            native.addAttribute(.font, value: titleFont, range: titleRange)
            let italicRange = string.range(of: "Gamma function")
            let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 18), toHaveTrait: .italicFontMask)
            native.addAttribute(.font, value: italic, range: italicRange)
            let link = URL(string: "https://katex.org")!
            native.addAttribute(.link, value: link, range: string.range(of: "here"))
            let quote = NSMutableParagraphStyle()
            quote.headIndent = 20
            native.addAttribute(.paragraphStyle, value: quote, range: string.range(of: "More information here."))
            let result = try #require(RichTextClipboard.renderFormulas(in: native, context: context))
            let contents = NativeTextAttributes.rich(result).runs.compactMap { $0[RenderedContentAttribute.self] }
            #expect(contents.map(\.kind) == [.inlineMath, .displayMath])
            #expect(contents[1].source == #"\Gamma(z) = \int_0^\infty t^{z-1}e^{-t}dt,."#)
            #expect(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == titleFont)
            #expect(result.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont == italic)
            let output = result.string as NSString
            #expect(result.attribute(.link, at: output.range(of: "here").location, effectiveRange: nil) as? URL == link)
            #expect(
                (result.attribute(.paragraphStyle, at: output.range(of: "More").location, effectiveRange: nil) as? NSParagraphStyle)?
                    .headIndent == 20)
            #expect(RichTextClipboard.renderFormulas(in: result, context: context) == nil)
        #endif
    }

    @Test func richMathConversionDoesNotTouchCodeLinksOrMoney() {
        #if os(macOS)
            let native = NSMutableAttributedString(string: "$code$ $link$ 价格 $20 和 $30", attributes: [.font: NSFont.systemFont(ofSize: 18)])
            let source = native.string as NSString
            native.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular), range: source.range(of: "$code$"))
            native.addAttribute(.link, value: URL(string: "https://example.com")!, range: source.range(of: "$link$"))
            #expect(RichTextClipboard.renderFormulas(in: native, context: context) == nil)
        #endif
    }

    @Test func cutAcrossFormulaAndQuoteRestoresSelectedHostsOnUndo() throws {
        #if os(macOS)
            var text = MarkdownFormatting.render("# KaTeX\n\n正文 $x$\n\n$$y$$\n\n> 引用\n\n后文")
            var selection = AttributedTextSelection(insertionPoint: text.startIndex)
            let editor = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }), selection: Binding(get: { selection }, set: { selection = $0 }))
            let coordinator = editor.makeCoordinator()
            let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 500))
            let original = NativeTextAttributes.native(text, context: context)
            view.textStorage?.setAttributedString(original)
            coordinator.textView = view
            let window = NSWindow(contentRect: view.frame, styleMask: .titled, backing: .buffered, defer: false)
            window.contentView = view
            defer { window.orderOut(nil) }
            view.allowsUndo = true
            let undo = try #require(view.undoManager)
            undo.groupsByEvent = false
            let source = view.string as NSString
            let start = source.range(of: "正文").location
            let end = NSMaxRange(source.range(of: "引用"))
            let range = NSRange(location: start, length: end - start)
            view.setSelectedRange(range)
            undo.beginUndoGrouping()
            #expect(coordinator.copyStructured(cut: true))
            undo.endUndoGrouping()
            #expect(view.textStorage?.attribute(.yoursQuote, at: start, effectiveRange: nil) == nil)
            #expect(view.typingAttributes[.yoursQuote] == nil)
            undo.undo()
            #expect(view.string == original.string)
            #expect(view.selectedRange() == range)
            let models = view.subviews.compactMap { ($0 as? NSHostingView<RenderedContentView>)?.rootView.model }
            #expect(models.count == 2)
            #expect(models.allSatisfy { $0.isSelected && $0.isRangeSelection })
            undo.redo()
            #expect(view.textStorage?.attribute(.yoursQuote, at: start, effectiveRange: nil) == nil)
        #endif
    }

    @Test func backspaceExitsEmptyQuoteWithoutMergingPreviousParagraph() throws {
        #if os(macOS)
            var text = MarkdownFormatting.render("前段\n\n> \n\n后段")
            var selection = AttributedTextSelection(insertionPoint: text.startIndex)
            let editor = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }), selection: Binding(get: { selection }, set: { selection = $0 }))
            let coordinator = editor.makeCoordinator()
            let view = NSTextView()
            let native = NSMutableAttributedString(attributedString: NativeTextAttributes.native(text, context: context))
            let position = (native.string as NSString).range(of: "\n").location + 1
            let paragraph = (native.string as NSString).paragraphRange(for: NSRange(location: position, length: 0))
            native.addAttribute(.yoursQuote, value: true, range: paragraph)
            view.textStorage?.setAttributedString(native)
            coordinator.textView = view
            view.setSelectedRange(NSRange(location: position, length: 0))
            let before = view.string
            #expect(coordinator.backspaceAtParagraphStart())
            #expect(view.string == before)
            #expect(view.selectedRange().location == position)
            #expect(view.textStorage?.attribute(.yoursQuote, at: position, effectiveRange: nil) == nil)
            #expect(view.typingAttributes[.yoursQuote] == nil)
        #endif
    }

    @Test(arguments: ["plain", "richFallback", "nativeRich"])
    func nativePasteAndSourceEditSupportUndo(clipboard: String) throws {
        #if os(macOS)
            var text = AttributedString("前后")
            var selection = AttributedTextSelection(insertionPoint: text.startIndex)
            let editor = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }), selection: Binding(get: { selection }, set: { selection = $0 }))
            let coordinator = editor.makeCoordinator()
            let view = NSTextView()
            view.textStorage?.setAttributedString(NativeTextAttributes.native(text, context: context))
            coordinator.textView = view
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 500, height: 300), styleMask: .titled, backing: .buffered, defer: false)
            window.contentView = view
            defer { window.orderOut(nil) }
            view.allowsUndo = true
            let undo = try #require(view.undoManager)
            undo.groupsByEvent = false
            view.setSelectedRange(NSRange(location: 1, length: 0))
            undo.beginUndoGrouping()
            #expect(
                coordinator.pasteContent(
                    encoded: nil, plainText: "$x^2$", hasRichText: clipboard != "plain",
                    richText: clipboard == "nativeRich" ? NSAttributedString(string: "$x^2$") : nil))
            undo.endUndoGrouping()
            let content = try #require(text.runs.compactMap { $0[RenderedContentAttribute.self] }.first)
            #expect(view.string == "前\u{FFFC}后")
            undo.beginUndoGrouping()
            coordinator.changeRenderedContent(original: content, source: "y^3")
            undo.endUndoGrouping()
            #expect(text.runs.compactMap { $0[RenderedContentAttribute.self]?.source } == ["y^3"])
            // A stale source editor cannot overwrite a newer edit.
            coordinator.changeRenderedContent(original: content, source: "obsolete")
            #expect(text.runs.compactMap { $0[RenderedContentAttribute.self]?.source } == ["y^3"])
            undo.undo()
            #expect(text.runs.compactMap { $0[RenderedContentAttribute.self]?.source } == ["x^2"])
            undo.undo()
            #expect(view.string == "前后")
            undo.redo()
            #expect(view.string == "前\u{FFFC}后")
        #endif
    }

    @Test func blockPasteSeparatesSurroundingProse() {
        #if os(macOS)
            var text = AttributedString("前后")
            var selection = AttributedTextSelection(insertionPoint: text.startIndex)
            let editor = NativeRichTextEditor(
                text: Binding(get: { text }, set: { text = $0 }), selection: Binding(get: { selection }, set: { selection = $0 }))
            let coordinator = editor.makeCoordinator()
            let view = NSTextView()
            view.textStorage?.setAttributedString(NativeTextAttributes.native(text, context: context))
            coordinator.textView = view
            view.setSelectedRange(NSRange(location: 1, length: 0))
            #expect(coordinator.pasteContent(encoded: nil, plainText: "$$\nx^2\n$$", hasRichText: false))
            #expect(view.string == "前\n\u{FFFC}\n后")
            #expect(view.selectedRange().location == 4)
            #expect(MarkdownFormatting.serialize(text, context: context).contains("$$\nx^2\n$$"))
        #endif
    }

    @Test(arguments: [RenderedContent.Kind.inlineMath, .displayMath, .mermaid], [false, true])
    func offlineRendererProducesMeasuredImage(kind: RenderedContent.Kind, dark: Bool) async throws {
        let source = kind == .mermaid ? "graph TD\nA[中文]-->B[End]" : kind == .inlineMath ? "E" : "\\int"
        let content = RenderedContent(kind: kind, source: source)
        let result = try await DocumentContentRenderer.shared.render(.init(content: content, width: 400, fontSize: 18, dark: dark))
        #expect(result.size.width > 0 && result.size.width <= 400)
        #expect(result.size.height > 0)
        if kind == .displayMath {
            let bounds = try #require(result.selectionBounds)
            #expect(bounds.width > 0 && bounds.width < result.size.width / 2)
            #expect(bounds.minX > 0 && bounds.maxX <= result.size.width)
        }
        #if os(macOS)
            let bitmap = try #require(result.image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            var inkPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                        color.alphaComponent > 0.1, dark ? color.redComponent > 0.8 : color.redComponent < 0.8
                    {
                        inkPixels += 1
                    }
                }
            }
            #expect(inkPixels > 20)
        #endif
        #expect(result.baseline > 0 && result.baseline <= result.size.height)
    }

    @Test func draftPreviewPreservesDocumentAndLastValidImage() async throws {
        let original = RenderedContent(kind: .inlineMath, source: "x^2")
        let draft = RenderedContentDraft(content: original)
        await draft.preview(dark: false)
        let image = try #require(draft.result?.image)
        draft.source = "\\notARealCommand{x}"
        await draft.preview(dark: false)
        #expect(draft.error != nil)
        #expect(draft.result?.image === image)
        #expect(draft.original == original)
        #expect(draft.original.source == "x^2")
        draft.source = "y^3"
        let cancelled = Task { await draft.preview(dark: false) }
        cancelled.cancel()
        await cancelled.value
        #expect(draft.result?.image === image)
        await draft.preview(dark: false)
        #expect(draft.error == nil)
        #expect(draft.result?.image !== image)
        #expect(!draft.isRendering)
        #expect(draft.original == original)
    }

    @Test func invalidFormulaRetainsSourceAndReportsError() async throws {
        let content = RenderedContent(kind: .inlineMath, source: "\\notARealCommand{x}")
        await #expect(throws: (any Error).self) {
            try await DocumentContentRenderer.shared.render(.init(content: content, width: 400, fontSize: 18, dark: false))
        }
        #expect(content.markdown == "$\\notARealCommand{x}$")
    }
}
