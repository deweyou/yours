import SwiftUI

/// Commands describe document semantics; native coordinators own editing transactions.
enum EditorAction: Equatable {
    case paragraph(String)
    case quote
    case emphasis(Int)
    case underline
    case strike
    case inlineCode
    case clear
    case indent(Bool)
    case link(URL?)
    case table(rows: Int, columns: Int)
}

struct EditorCommand: Identifiable {
    let id: String
    let titleKey: String
    let symbol: String
    let category: String
    let aliases: String
    let action: EditorAction
    var title: String { L10n.string(String.LocalizationValue(titleKey)) }
}

enum EditorCommandCatalog {
    static let paragraphs: [EditorCommand] =
        [
            .init(
                id: "body", titleKey: "format.body", symbol: "text.alignleft", category: "editor.category.text",
                aliases: "text paragraph 正文 段落", action: .paragraph("body"))
        ]
        + (1...6).map { level in
            EditorCommand(
                id: "heading-\(level)", titleKey: "editor.heading.level\(level)", symbol: "textformat.size",
                category: "editor.category.text",
                aliases: "h\(level) heading\(level) 标题\(level) 标题\(["一", "二", "三", "四", "五", "六"][level - 1])",
                action: .paragraph("heading:\(level)"))
        } + [
            .init(
                id: "bullet", titleKey: "format.list.bulleted", symbol: "list.bullet", category: "editor.category.lists",
                aliases: "ul bullet unordered 无序 列表", action: .paragraph("bullet")),
            .init(
                id: "numbered", titleKey: "format.list.numbered", symbol: "list.number", category: "editor.category.lists",
                aliases: "ol number ordered 有序 列表", action: .paragraph("numbered")),
            .init(
                id: "task", titleKey: "format.checklist", symbol: "checklist", category: "editor.category.lists",
                aliases: "todo task checklist 待办 勾选 任务", action: .paragraph("task")),
            .init(
                id: "quote", titleKey: "format.quote", symbol: "text.quote", category: "editor.category.blocks", aliases: "quote 引用",
                action: .quote),
            .init(
                id: "code", titleKey: "format.code_block", symbol: "curlybraces.square",
                category: "editor.category.blocks", aliases: "code codeblock 代码", action: .paragraph("code")),
            .init(
                id: "table", titleKey: "table.insert", symbol: "tablecells", category: "editor.category.blocks", aliases: "table 表格",
                action: .table(rows: 3, columns: 3)),
        ]

    static func matching(_ query: String) -> [EditorCommand] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace)
        let matches = paragraphs.filter { command in
            let search = (command.title + " " + command.aliases + " " + command.id).lowercased()
            return tokens.allSatisfy { search.contains($0) }
        }
        let normalized = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        func rank(_ command: EditorCommand) -> Int {
            let words = (command.title + " " + command.aliases + " " + command.id).lowercased().split(separator: " ")
            if words.contains(where: { $0 == normalized }) { return 0 }
            if words.contains(where: { $0.hasPrefix(normalized) }) { return 1 }
            return 2
        }
        return matches.enumerated().sorted {
            let a = rank($0.element)
            let b = rank($1.element)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
}

struct EditorSlashQuery: Equatable {
    let range: NSRange
    let query: String

    static func detect(in text: String, caret: Int) -> Self? {
        let source = text as NSString
        guard caret > 0, caret <= source.length else { return nil }
        let paragraph = source.paragraphRange(for: NSRange(location: caret, length: 0))
        let prefix = source.substring(with: NSRange(location: paragraph.location, length: caret - paragraph.location))
        guard let slash = prefix.lastIndex(of: "/") else { return nil }
        let before = prefix[..<slash]
        guard before.isEmpty || before.last == " " || before.last == "\t" else { return nil }
        let query = String(prefix[prefix.index(after: slash)...])
        guard !query.contains(where: { $0.isWhitespace || $0 == "/" }), query.utf16.count <= 64 else { return nil }
        return Self(range: NSRange(location: paragraph.location + before.utf16.count, length: query.utf16.count + 1), query: query)
    }
}

@MainActor
enum EditorCommandEditing {
    static func isAllowed(_ action: EditorAction, text: AttributedString, range: NSRange) -> Bool {
        guard let selected = Range<AttributedString.Index>(range, in: text) else { return false }
        let source = String(text.characters) as NSString
        let paragraph = source.paragraphRange(for: range)
        guard let block = Range<AttributedString.Index>(paragraph, in: text) else { return false }
        let runs = text[block].runs
        if runs.contains(where: { $0[TableAttribute.self] != nil }) { return false }
        let code = runs.filter { $0[CodeStyleAttribute.self]?.hasPrefix("block:") == true }
        if !code.isEmpty {
            guard action == .paragraph("body"), !selected.isEmpty,
                code.count == runs.count,
                range.location <= paragraph.location, NSMaxRange(range) >= NSMaxRange(paragraph)
            else { return false }
            let ids = Set(code.compactMap { $0[CodeStyleAttribute.self] })
            for run in text.runs where ids.contains(run[CodeStyleAttribute.self] ?? "") {
                let blockRange = NSRange(run.range, in: text)
                if blockRange.location < range.location || NSMaxRange(blockRange) > NSMaxRange(range) { return false }
            }
        }
        if case .indent = action {
            return !runs.isEmpty && runs.allSatisfy { ["bullet", "numbered", "task"].contains($0[ParagraphStyleAttribute.self] ?? "body") }
        }
        if case .link(let url) = action {
            if let url, !["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { return false }
            return !selected.isEmpty && !text[selected].characters.contains(where: \.isNewline)
                && Set(text[selected].runs.compactMap(\.link)).count <= 1
        }
        if case .table = action {
            return range.length == 0
        }
        return true
    }

    static func apply(
        _ action: EditorAction, text: inout AttributedString, selection: inout AttributedTextSelection, context: Font.Context,
        setQuote: Bool = false
    ) {
        switch action {
        case .paragraph(let role):
            ParagraphEditing.apply(role, to: &text, selection: &selection, context: context)
        case .quote:
            if setQuote, selection.attributes(in: text).allSatisfy({ $0[QuoteAttribute.self] == true }) { return }
            ParagraphEditing.apply("quote", to: &text, selection: &selection, context: context)
        case .indent(let outdent):
            ParagraphEditing.indentList(in: &text, selection: &selection, outdent: outdent)
        case .table(let rows, let columns):
            guard (1...8).contains(rows), (1...8).contains(columns) else { return }
            var body = AttributedString("\n")
            body[ParagraphStyleAttribute.self] = "body"
            body.font = .body
            let table = TableData(
                rows: Array(repeating: Array(repeating: "", count: columns), count: rows),
                alignments: Array(repeating: .left, count: columns))
            let plain = String(text.characters) as NSString
            let insertion: Int
            if case .insertionPoint(let caret) = selection.indices(in: text) {
                insertion = NSRange(caret..<caret, in: text).location
            } else {
                return
            }
            let paragraph = plain.paragraphRange(for: NSRange(location: insertion, length: 0))
            let empty = plain.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let offset = empty ? insertion : NSMaxRange(paragraph)
            guard let index = Range<AttributedString.Index>(NSRange(location: offset, length: 0), in: text)?.lowerBound else { return }
            selection = AttributedTextSelection(insertionPoint: index)
            let prefix = !empty && offset == plain.length && !plain.hasSuffix("\n") ? body : AttributedString()
            text.replaceSelection(&selection, with: prefix + table.attributedText + body)
        default:
            let attributes = Array(selection.attributes(in: text))
            let remove = !attributes.isEmpty && attributes.allSatisfy { isActive(action, attributes: $0, context: context) }
            func update(_ value: inout AttributeContainer) {
                switch action {
                case .emphasis(let flag): DocumentTypography.setEmphasis(flag, enabled: !remove, in: &value, context: context)
                case .underline: value.underlineStyle = remove ? nil : .single
                case .strike: value.strikethroughStyle = remove ? nil : .single
                case .inlineCode: value[CodeStyleAttribute.self] = remove ? nil : "inline"
                case .link(let url): value.link = url
                case .clear:
                    value[InlineEmphasisAttribute.self] = 0
                    value.inlinePresentationIntent = nil
                    value.underlineStyle = nil
                    value.strikethroughStyle = nil
                    value.foregroundColor = nil
                    value.backgroundColor = nil
                    value.link = nil
                    value[CodeStyleAttribute.self] = nil
                default: break
                }
                value.font = DocumentTypography.font(
                    for: value[ParagraphStyleAttribute.self] ?? "body", emphasis: DocumentTypography.emphasis(in: value, context: context),
                    inlineCode: value[CodeStyleAttribute.self] == "inline", context: context)
            }
            switch selection.indices(in: text) {
            case .insertionPoint:
                text.transformAttributes(in: &selection, body: update)
            case .ranges(let ranges):
                let selectedOffsets = ranges.ranges.map { NSRange($0, in: text) }
                // Transform each original run, preserving attributes that differ within the selection.
                // Applying the selection's common attributes would erase unrelated inline formatting.
                let runs = ranges.ranges.flatMap { range in
                    text[range].runs.map { (range: $0.range, attributes: $0.attributes) }
                }
                for run in runs {
                    var attributes = run.attributes
                    update(&attributes)
                    text[run.range].setAttributes(attributes)
                }
                selection = AttributedTextSelection(
                    ranges: RangeSet(selectedOffsets.compactMap { Range<AttributedString.Index>($0, in: text) }))
            }
        }
    }

    static func isActive(_ action: EditorAction, attributes: AttributeContainer, context: Font.Context) -> Bool {
        switch action {
        case .emphasis(let flag): DocumentTypography.emphasis(in: attributes, context: context) & flag != 0
        case .underline: attributes.underlineStyle != nil
        case .strike: attributes.strikethroughStyle != nil
        case .inlineCode: attributes[CodeStyleAttribute.self] == "inline"
        case .quote: attributes[QuoteAttribute.self] == true
        case .paragraph(let role): (attributes[ParagraphStyleAttribute.self] ?? "body") == role
        default: false
        }
    }
}

@MainActor
final class EditorCommandBridge {
    var perform: ((EditorAction) -> Void)?
    var openLink: (() -> Void)?
    var insertTable: (() -> Void)?
}
