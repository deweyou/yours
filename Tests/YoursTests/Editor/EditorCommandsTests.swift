import SwiftUI
import Testing

@testable import Yours

@MainActor
struct EditorCommandsTests {
    private let context = EnvironmentValues().fontResolutionContext

    @Test(arguments: [EditorAction.emphasis(1), .emphasis(2), .underline, .strike, .inlineCode])
    func inlineTogglesApplyAcrossMixedRunsAndRestore(action: EditorAction) {
        var text = AttributedString("中🌿文")
        var selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
        EditorCommandEditing.apply(action, text: &text, selection: &selection, context: context)
        #expect(text.runs.allSatisfy { EditorCommandEditing.isActive(action, attributes: $0.attributes, context: context) })
        EditorCommandEditing.apply(action, text: &text, selection: &selection, context: context)
        #expect(text.runs.allSatisfy { EditorCommandEditing.isActive(action, attributes: $0.attributes, context: context) == false })
        #expect(String(text.characters) == "中🌿文")
    }

    @Test func quoteSetIsIdempotentAndExplicitToggleRemovesIt() {
        var text = AttributedString("quote")
        var selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
        EditorCommandEditing.apply(.quote, text: &text, selection: &selection, context: context, setQuote: true)
        EditorCommandEditing.apply(.quote, text: &text, selection: &selection, context: context, setQuote: true)
        #expect(text[QuoteAttribute.self] == true)
        EditorCommandEditing.apply(.quote, text: &text, selection: &selection, context: context)
        #expect(text[QuoteAttribute.self] == nil)
    }

    @Test func tableAppendsAfterNonemptyParagraphWithoutDeletingText() {
        var text = AttributedString("before🌿")
        var selection = AttributedTextSelection(insertionPoint: text.startIndex)
        #expect(EditorCommandEditing.isAllowed(.table(rows: 3, columns: 3), text: text, range: NSRange(location: 0, length: 0)))
        EditorCommandEditing.apply(.table(rows: 3, columns: 3), text: &text, selection: &selection, context: context)
        #expect(String(text.characters).hasPrefix("before🌿\n"))
        let tables = text.runs.compactMap { $0[TableAttribute.self] }
        #expect(tables.first?.rows.count == 3)
        #expect(tables.first?.rows.first?.count == 3)
        #expect(text.characters.last == "\n")
    }

    @Test func tableOnEmptyDocumentAndInvalidDimensions() {
        var text = AttributedString()
        var selection = AttributedTextSelection(insertionPoint: text.startIndex)
        EditorCommandEditing.apply(.table(rows: 0, columns: 2), text: &text, selection: &selection, context: context)
        #expect(text.characters.isEmpty)
        EditorCommandEditing.apply(.table(rows: 2, columns: 2), text: &text, selection: &selection, context: context)
        #expect(text.runs.contains { $0[TableAttribute.self] != nil })
        #expect(EditorCommandEditing.isAllowed(.emphasis(1), text: text, range: NSRange(location: 0, length: 1)) == false)
    }

    @Test func linksRequireOneParagraphAndUniformAddress() throws {
        var text = AttributedString("one two")
        var selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
        let url = try #require(URL(string: "https://example.com"))
        EditorCommandEditing.apply(.link(url), text: &text, selection: &selection, context: context)
        #expect(text.link == url)
        EditorCommandEditing.apply(.link(nil), text: &text, selection: &selection, context: context)
        #expect(text.link == nil)
        #expect(EditorCommandEditing.isAllowed(.link(url), text: text, range: NSRange(location: 0, length: 0)) == false)
        let multiline = AttributedString("one\ntwo")
        #expect(EditorCommandEditing.isAllowed(.link(url), text: multiline, range: NSRange(location: 0, length: 7)) == false)
        #expect(EditorCommandEditing.isAllowed(.clear, text: text, range: NSRange(location: 99, length: 1)) == false)
    }

    @Test func indentAndOutdentPreserveSelectedContent() {
        var text = MarkdownFormatting.render("- first\n- second")
        var selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
        EditorCommandEditing.apply(.indent(false), text: &text, selection: &selection, context: context)
        #expect(String(text.characters).hasPrefix("\tfirst"))
        EditorCommandEditing.apply(.indent(true), text: &text, selection: &selection, context: context)
        #expect(String(text.characters).hasPrefix("first"))
    }

    @Test func codeSetPreservesIdentityAndLanguage() {
        var text = MarkdownFormatting.render("```swift\nlet a = 1\n```")
        let before = text
        var selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
        EditorCommandEditing.apply(.paragraph("code"), text: &text, selection: &selection, context: context)
        #expect(text == before)
    }

    @Test func searchIsStableAndUnknownQueryHasNoCommands() {
        #expect(EditorCommandCatalog.matching("").map(\.id) == EditorCommandCatalog.paragraphs.map(\.id))
        #expect(EditorCommandCatalog.matching("ul").first?.id == "bullet")
        #expect(EditorCommandCatalog.matching("ol").first?.id == "numbered")
        #expect(EditorCommandCatalog.matching("codeblock").first?.id == "code")
        #expect(EditorCommandCatalog.matching("unknown-command").isEmpty)
        #expect(EditorSlashQuery.detect(in: "", caret: 0) == nil)
        #expect(EditorSlashQuery.detect(in: "/h2", caret: 99) == nil)
        #expect(EditorSlashQuery.detect(in: "/" + String(repeating: "a", count: 65), caret: 66) == nil)
    }
}
