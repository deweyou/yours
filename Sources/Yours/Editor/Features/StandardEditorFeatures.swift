import Foundation

extension EditorFeatureRegistry {
    static let standardFeatures: [any EditorInputFeature] = [
        LinkInputFeature(),
        QuoteEmptyDeletionFeature(),
        CodeBlockInputFeature(),
        QuotedMarkdownShortcutFeature(),
        HeadingInputFeature(),
        TaskInputFeature(),
        QuoteInputFeature(),
        InlineCodeInputFeature(),
        QuoteMergeInputFeature(),
        SemanticBackspaceFeature(),
        ListIndentInputFeature(),
        MarkdownShortcutInputFeature(),
        ParagraphBreakInputFeature(),
    ]
}

private enum StandardFeaturePriority: Int {
    case link = 100
    case quoteEmptyDeletion = 200
    case codeBlock = 300
    case quotedMarkdownShortcut = 400
    case heading = 500
    case task = 600
    case quote = 700
    case inlineCode = 800
    case quoteMerge = 900
    case semanticBackspace = 1_000
    case listIndent = 1_100
    case markdownShortcut = 1_200
    case paragraphBreak = 1_300
}

private struct LinkInputFeature: EditorInputFeature {
    let id = "link"
    let priority = StandardFeaturePriority.link.rawValue

    func command(for context: EditorInputContext) -> EditorInputCommand? {
        guard context.range.length > 0, context.codeStyle == nil,
            let url = URL(string: context.replacement),
            ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
            url.host != nil,
            !context.replacement.contains(where: { $0.isWhitespace })
        else { return nil }
        return .applyLink(url)
    }
}

private struct QuoteEmptyDeletionFeature: EditorInputFeature {
    let id = "quote-empty-deletion"
    let priority = StandardFeaturePriority.quoteEmptyDeletion.rawValue

    func command(for context: EditorInputContext) -> EditorInputCommand? {
        guard context.isQuoted, context.replacement.isEmpty, context.range.length > 0,
            NSIntersectionRange(context.range, context.paragraph).length == context.range.length
        else { return nil }
        let local = NSRange(location: context.range.location - context.paragraph.location, length: context.range.length)
        let remaining = NSMutableString(string: context.line)
        guard NSMaxRange(local) <= remaining.length else { return nil }
        remaining.deleteCharacters(in: local)
        return remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .preserveEmptyQuote : nil
    }
}

private struct CodeBlockInputFeature: EditorInputFeature {
    let id = "code-block"
    let priority = StandardFeaturePriority.codeBlock.rawValue

    func command(for context: EditorInputContext) -> EditorInputCommand? {
        guard context.codeStyle?.hasPrefix("block:") == true else { return nil }
        if context.replacement == "\t" || context.replacement == "\u{19}" {
            return .indentCode(outdent: context.replacement == "\u{19}")
        }
        guard context.replacement == "\n", context.range.length == 0 else { return nil }
        if context.line.trimmingCharacters(in: .whitespaces).isEmpty {
            let insertion = context.paragraph.length == 0 ? NSRange(location: context.paragraph.location, length: 0) : context.range
            let blankCode =
                context.paragraph.length == 0
                ? insertion
                : NSRange(
                    location: context.paragraph.location,
                    length: max(0, context.selection.location - context.paragraph.location))
            return .edit(
                .init(range: blankCode, replacement: "", style: context.isQuoted ? .quote : .body),
                origin: .feature)
        }
        let prefix = context.source.substring(
            with: NSRange(location: context.paragraph.location, length: context.selection.location - context.paragraph.location)
        ).prefix(while: { $0 == " " || $0 == "\t" })
        return .continueCodeLine(String(prefix))
    }
}

private struct QuotedMarkdownShortcutFeature: EditorInputFeature {
    let id = "quoted-markdown-shortcut"
    let priority = StandardFeaturePriority.quotedMarkdownShortcut.rawValue

    func command(for context: EditorInputContext) -> EditorInputCommand? {
        guard context.isQuoted, context.codeStyle == nil,
            var shortcut = MarkdownShortcut.match(
                text: context.source as String,
                range: context.range,
                replacement: context.replacement,
                hasMarkedText: false)
        else { return nil }
        if context.replacement == "\n", shortcut.style == .body {
            shortcut = .init(range: shortcut.range, replacement: shortcut.replacement, style: .quote)
        }
        return .edit(shortcut, origin: .markdownShortcut)
    }
}

private struct HeadingInputFeature: EditorInputFeature {
    let id = "heading"
    let priority = StandardFeaturePriority.heading.rawValue

    func command(for context: EditorInputContext) -> EditorInputCommand? {
        guard context.replacement == "\n", context.range.length == 0,
            context.role?.hasPrefix("heading:") == true
        else { return nil }
        return .edit(.init(range: context.range, replacement: "\n", style: .body), origin: .feature)
    }
}

private struct TaskInputFeature: EditorInputFeature {
    let id = "task"
    let priority = StandardFeaturePriority.task.rawValue

    func command(for context: EditorInputContext) -> EditorInputCommand? {
        guard context.replacement == "\n", context.range.length == 0, ["task", "bullet", "numbered"].contains(context.role ?? "") else {
            return nil
        }
        let edit =
            context.line.trimmingCharacters(in: .whitespaces).isEmpty
            ? MarkdownShortcut.Edit(
                range: NSRange(location: context.paragraph.location, length: context.line.utf16.count),
                replacement: "", style: context.isQuoted ? .quote : .body)
            : MarkdownShortcut.Edit(
                range: context.range,
                replacement: "\n" + context.line.prefix(while: { $0 == "\t" }),
                style: context.role == "bullet" ? .bullet : context.role == "numbered" ? .numbered : .task,
                listMarker: context.role == "numbered"
                    ? "\((Int((context.listMarker ?? "1.").dropLast()) ?? 1) + 1)." : context.role == "bullet" ? "•" : nil)
        return .edit(edit, origin: .feature)
    }
}

private struct QuoteInputFeature: EditorInputFeature {
    let id = "quote"
    let priority = StandardFeaturePriority.quote.rawValue

    func command(for context: EditorInputContext) -> EditorInputCommand? {
        guard context.replacement == "\n", context.range.length == 0, context.isQuoted else { return nil }
        let insertion = context.paragraph.length == 0 ? NSRange(location: context.paragraph.location, length: 0) : context.range
        let edit =
            context.line.trimmingCharacters(in: .whitespaces).isEmpty
            ? MarkdownShortcut.Edit(range: insertion, replacement: "", style: .body)
            : MarkdownShortcut.Edit(range: context.range, replacement: "\n", style: .quote)
        return .edit(edit, origin: .feature)
    }
}

private struct InlineCodeInputFeature: EditorInputFeature {
    let id = "inline-code"
    let priority = StandardFeaturePriority.inlineCode.rawValue

    func command(for context: EditorInputContext) -> EditorInputCommand? {
        guard context.replacement == "\n", context.range.length == 0, context.codeStyle == "inline" else { return nil }
        return .edit(.init(range: context.range, replacement: "\n", style: .body), origin: .feature)
    }
}

private struct QuoteMergeInputFeature: EditorInputFeature {
    let id = "quote-merge"
    let priority = StandardFeaturePriority.quoteMerge.rawValue

    func command(for context: EditorInputContext) -> EditorInputCommand? {
        guard context.replacement.isEmpty, context.range.length > 0,
            let item = MarkdownShortcut.listPrefix(context.line), item.style == .quote,
            context.line.dropFirst(item.prefix.count).isEmpty,
            NSMaxRange(context.range) == context.paragraph.location + item.prefix.utf16.count,
            context.range.location >= context.paragraph.location,
            context.paragraph.location > 0
        else { return nil }
        let previousRange = context.source.paragraphRange(for: NSRange(location: context.paragraph.location - 1, length: 0))
        let previousLine = context.source.substring(with: previousRange).trimmingCharacters(in: .newlines)
        guard MarkdownShortcut.listPrefix(previousLine)?.style == .quote else { return nil }
        return .edit(
            .init(
                range: NSRange(location: context.paragraph.location - 1, length: item.prefix.utf16.count + 1),
                replacement: "",
                style: .quote),
            origin: .feature)
    }
}

private struct SemanticBackspaceFeature: EditorInputFeature {
    let id = "semantic-backspace"
    let priority = StandardFeaturePriority.semanticBackspace.rawValue

    func command(for context: EditorInputContext) -> EditorInputCommand? {
        guard context.replacement.isEmpty, context.selection.length == 0 else { return nil }
        if ["bullet", "numbered", "task"].contains(context.role ?? ""),
            context.selection.location == context.paragraph.location + context.line.prefix(while: { $0 == "\t" }).utf16.count
        {
            let indented = context.line.hasPrefix("\t")
            return .edit(
                .init(
                    range: NSRange(location: context.paragraph.location, length: indented ? 1 : 0),
                    replacement: "",
                    style: indented ? (context.role == "bullet" ? .bullet : context.role == "numbered" ? .numbered : .task) : .body),
                origin: .feature)
        }
        if context.range.length > 0, let item = MarkdownShortcut.listPrefix(context.line),
            context.selection.location == context.paragraph.location + item.prefix.utf16.count,
            NSMaxRange(context.range) == context.selection.location,
            context.range.location >= context.paragraph.location
        {
            return .edit(
                .init(
                    range: NSRange(location: context.paragraph.location, length: item.prefix.utf16.count),
                    replacement: "",
                    style: .body),
                origin: .feature)
        }
        guard context.selection.location == context.paragraph.location,
            context.role?.hasPrefix("heading:") == true || context.role == "quote"
                || ["task", "bullet", "numbered"].contains(context.role ?? "")
                || context.codeStyle?.hasPrefix("block:") == true,
            context.range.length <= 1 || context.line.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return .edit(
            .init(range: NSRange(location: context.selection.location, length: 0), replacement: "", style: .body),
            origin: .feature)
    }
}

private struct ListIndentInputFeature: EditorInputFeature {
    let id = "list-indent"
    let priority = StandardFeaturePriority.listIndent.rawValue

    func command(for context: EditorInputContext) -> EditorInputCommand? {
        guard context.replacement == "\t" || context.replacement == "\u{19}", context.selection.length == 0,
            let item = MarkdownShortcut.listPrefix(context.line)
                ?? (["task", "bullet", "numbered"].contains(context.role ?? "")
                    ? ("", "", context.role == "bullet" ? MarkdownShortcut.Style.bullet : context.role == "numbered" ? .numbered : .task)
                    : nil)
        else { return nil }
        if context.replacement == "\t", context.line.prefix(while: { $0 == "\t" }).count < 8 {
            return .edit(
                .init(range: NSRange(location: context.paragraph.location, length: 0), replacement: "\t", style: item.style),
                origin: .feature)
        }
        if context.replacement == "\u{19}", context.line.hasPrefix("\t") {
            return .edit(
                .init(range: NSRange(location: context.paragraph.location, length: 1), replacement: "", style: item.style),
                origin: .feature)
        }
        return .consume
    }
}

private struct MarkdownShortcutInputFeature: EditorInputFeature {
    let id = "markdown-shortcut"
    let priority = StandardFeaturePriority.markdownShortcut.rawValue

    func command(for context: EditorInputContext) -> EditorInputCommand? {
        guard context.codeStyle == nil,
            let edit = MarkdownShortcut.match(
                text: context.source as String,
                range: context.range,
                replacement: context.replacement,
                hasMarkedText: false)
        else { return nil }
        return .edit(edit, origin: .markdownShortcut)
    }
}

/// A normal Return starts fresh inline formatting after structural features have
/// handled list, quote, heading, and fenced-code continuation.
private struct ParagraphBreakInputFeature: EditorInputFeature {
    let id = "paragraph-break"
    let priority = StandardFeaturePriority.paragraphBreak.rawValue

    func command(for context: EditorInputContext) -> EditorInputCommand? {
        guard context.replacement == "\n", context.codeStyle?.hasPrefix("block:") != true else { return nil }
        return .edit(.init(range: context.range, replacement: "\n", style: .body), origin: .feature)
    }
}
