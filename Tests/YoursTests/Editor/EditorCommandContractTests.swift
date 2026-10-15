import SwiftUI
import Testing

@testable import Yours

@MainActor
struct EditorCommandContractTests {
    @Test func paragraphMenuKeyboardSkipsDisabledAndAppliesOnce() {
        let state = EditorControlsState()
        state.items = [
            EditorControlItem(id: "paragraph-body", title: "正文", symbol: "text.alignleft", action: .paragraph("body"), active: true),
            EditorControlItem(
                id: "paragraph-heading-1", title: "标题1", symbol: "textformat", action: .paragraph("heading:1"), enabled: false),
            EditorControlItem(id: "paragraph-heading-2", title: "标题2", symbol: "textformat", action: .paragraph("heading:2")),
        ]
        var selections = 0
        state.choose = { action in
            if case .paragraph("heading:2") = action { selections += 1 }
        }
        state.toggleParagraphMenu()
        #expect(state.paragraphHighlight == 0)
        #expect(state.handleParagraphKey("down"))
        #expect(state.paragraphHighlight == 2)
        #expect(state.handleParagraphKey("down"))
        #expect(state.paragraphHighlight == 0)
        #expect(state.handleParagraphKey("up"))
        #expect(state.paragraphHighlight == 2)
        #expect(state.handleParagraphKey("return"))
        #expect(selections == 1)
        #expect(state.paragraphExpanded == false)
        #expect(state.handleParagraphKey("return") == false)
        state.toggleParagraphMenu()
        #expect(state.handleParagraphKey("escape"))
        #expect(state.paragraphExpanded == false)
        #expect(selections == 1)
    }

    @Test(arguments: ["h2", "H2", "heading2", "标题二"])
    func headingAliasesResolveToTheSameCommand(query: String) {
        #expect(EditorCommandCatalog.matching(query).first?.id == "heading-2")
    }

    @Test(arguments: ["a/b", "https://example.com", "/usr/bin", "/h2 ", "/h2\t", "/h2\n", "／h2"])
    func literalInputDoesNotRemainAnActiveQuery(text: String) {
        #expect(EditorSlashQuery.detect(in: text, caret: text.utf16.count) == nil)
    }

    @Test func slashRangeUsesUTF16AfterEmoji() throws {
        let text = "中文🌿 /h2"
        let query = try #require(EditorSlashQuery.detect(in: text, caret: text.utf16.count))
        #expect(query.query == "h2")
        #expect((text as NSString).substring(with: query.range) == "/h2")
        #expect(query.range.location == "中文🌿 ".utf16.count)
    }

    @Test func reapplyingTaskPreservesCompletionInMixedSelection() throws {
        let context = EnvironmentValues().fontResolutionContext
        var text = MarkdownFormatting.render("- [x] Done\n\nPlain")
        var selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
        EditorCommandEditing.apply(.paragraph("task"), text: &text, selection: &selection, context: context)
        let done = try #require(text.range(of: "Done"))
        let plain = try #require(text.range(of: "Plain"))
        #expect(text[done][TaskStateAttribute.self] == true)
        #expect(text[plain][TaskStateAttribute.self] == false)
        let first = text
        EditorCommandEditing.apply(.paragraph("task"), text: &text, selection: &selection, context: context)
        #expect(text == first)
    }

    @Test func partialCodeBlockCannotBeConvertedAsAWholeBlock() throws {
        let text = MarkdownFormatting.render("```swift\nfirst\nsecond\n```")
        let range = (String(text.characters) as NSString).range(of: "first\n")
        #expect(range.location != NSNotFound)
        #expect(EditorCommandEditing.isAllowed(.paragraph("body"), text: text, range: range) == false)
        let all = NSRange(location: 0, length: String(text.characters).utf16.count)
        #expect(EditorCommandEditing.isAllowed(.paragraph("body"), text: text, range: all))
    }

    @Test func paragraphConversionExcludesNextParagraphAtSelectionEnd() throws {
        let context = EnvironmentValues().fontResolutionContext
        var text = AttributedString("First\nSecond")
        let second = try #require(text.range(of: "Second"))
        var selection = AttributedTextSelection(range: text.startIndex..<second.lowerBound)
        EditorCommandEditing.apply(.paragraph("heading:2"), text: &text, selection: &selection, context: context)
        let updatedFirst = try #require(text.range(of: "First"))
        let updatedSecond = try #require(text.range(of: "Second"))
        #expect(text[updatedFirst][ParagraphStyleAttribute.self] == "heading:2")
        #expect(text[updatedSecond][ParagraphStyleAttribute.self] != "heading:2")
    }

    @Test func clearTextFormattingRetainsParagraphAndQuoteAfterStorageRoundTrip() throws {
        let context = EnvironmentValues().fontResolutionContext
        var text = MarkdownFormatting.render("> ## **中文🌿** [link](https://example.com)")
        var selection = AttributedTextSelection(range: text.startIndex..<text.endIndex)
        EditorCommandEditing.apply(.clear, text: &text, selection: &selection, context: context)
        #expect(text.runs.allSatisfy { $0[ParagraphStyleAttribute.self] == "heading:2" })
        #expect(text.runs.allSatisfy { $0[QuoteAttribute.self] == true })
        #expect(text.runs.allSatisfy { DocumentTypography.emphasis(in: $0.attributes, context: context) == 0 })
        #expect(text.runs.allSatisfy { $0.link == nil })
        var note = Note(id: UUID(), text: "", createdAt: Date(), updatedAt: Date())
        note.richText = text
        let restored = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(note))
        #expect(restored.richText == text)
    }
}
