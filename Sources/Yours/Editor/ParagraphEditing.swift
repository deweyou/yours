import CoreText
import SwiftUI

enum ParagraphStyleAttribute: CodableAttributedStringKey {
    typealias Value = String
    static let name = "yours.paragraphStyle"
}

enum ListMarkerAttribute: CodableAttributedStringKey {
    typealias Value = String
    static let name = "yours.listMarker"
}

enum TaskStateAttribute: CodableAttributedStringKey {
    typealias Value = Bool
    static let name = "yours.taskChecked"
}

/// Block quote membership is independent from the paragraph's inner role.
enum QuoteAttribute: CodableAttributedStringKey {
    typealias Value = Bool
    static let name = "yours.quote"
}

/// Paragraph appearance and inline emphasis are separate, persisted semantics.
enum InlineEmphasisAttribute: CodableAttributedStringKey {
    typealias Value = Int
    static let name = "yours.inlineEmphasis"
}

enum DocumentTypography {
    static let bodySize: CGFloat = 14
    static let titleScale: CGFloat = 2
    static let titleSize = bodySize * titleScale
    static let titleLineSpacing = titleSize * (3 / 28)
    static let mobileScale: CGFloat = 1.08
    #if os(macOS)
        static let storedBodySize: CGFloat = 13
        static let readingScale = bodySize / storedBodySize
    #else
        static let storedBodySize: CGFloat = 17
        static let readingScale = mobileScale
    #endif
    static let bodyLineSpacing: CGFloat = 6
    static let bodyParagraphSpacing: CGFloat = 8
    static let lineHeightRatio: CGFloat = 1.25
    static let selectionLineSpacingShare: CGFloat = 1 / 3
    static let inlineCodeScale: CGFloat = 0.93
    static let inlineCodePaddingRatio: CGFloat = 0.5
    static let inlineCodeMarginRatio: CGFloat = 0.3
    static let inlineCodeVerticalPaddingRatio: CGFloat = 0.14
    static let inlineCodeRadiusRatio: CGFloat = 0.46
    static let inlineCodeBackgroundRiseRatio: CGFloat = 0.08
    static let codeLineSpacing: CGFloat = 3
    static let codeInset: CGFloat = 16
    static let readingWidth: CGFloat = 728
    static let titleLeadingInset: CGFloat = 5
    static let titleTopInset: CGFloat = 24
    static let titleBottomInset: CGFloat = 4
    static let editorTopInset: CGFloat = 16
    static let controlFontSize: CGFloat = 12
    static let listIndent: CGFloat = 24
    static let listSpacing: CGFloat = 6
    static let quoteIndent: CGFloat = 16
    static let quoteContinuationIndent: CGFloat = 24
    static let quoteSpacing: CGFloat = 8
    static let quoteBarVerticalOvershootRatio: CGFloat = 0.2
    static let quoteBarTerminalBottomOvershootRatio: CGFloat = 0.1
    static let quoteBarOpticalRiseRatio: CGFloat = 0.04
    static let taskIconScale: CGFloat = 1.08
    static let taskTextGapRatio: CGFloat = 0.45
    static let taskCornerRadiusRatio: CGFloat = 0.28
    static let taskBorderWidthRatio: CGFloat = 0.075
    static let taskCheckScale: CGFloat = 0.66
    static let taskCheckHorizontalOffsetRatio: CGFloat = 0.04
    #if os(macOS)
        static let taskIconHitSize: CGFloat = 24
    #else
        static let taskIconHitSize: CGFloat = 44
    #endif
    static let codeBefore: CGFloat = 20
    static let codeAfter: CGFloat = 20
    static let tableRowHeight: CGFloat = 44
    static let tableControlsHeight: CGFloat = 32
    #if os(macOS)
        static let codeHeaderHeight: CGFloat = 32
    #else
        static let codeHeaderHeight: CGFloat = 44
    #endif

    struct Heading {
        let ratio: CGFloat
        let weight: Font.Weight
        let lineSpacing: CGFloat
        let before: CGFloat
        let after: CGFloat
    }
    static let headings: [Heading] = [
        .init(ratio: 24 / 14, weight: .semibold, lineSpacing: 3, before: 12, after: 8),
        .init(ratio: 20 / 14, weight: .semibold, lineSpacing: 3, before: 12, after: 8),
        .init(ratio: 17 / 14, weight: .semibold, lineSpacing: 3, before: 10, after: 4),
        .init(ratio: 15 / 14, weight: .semibold, lineSpacing: 3, before: 10, after: 4),
        .init(ratio: 1, weight: .semibold, lineSpacing: 3, before: 8, after: 4),
        .init(ratio: 1, weight: .medium, lineSpacing: 3, before: 6, after: 2),
    ]
    static func heading(for role: String) -> Heading? {
        guard role.hasPrefix("heading:"), let level = Int(role.dropFirst(8)), (1...6).contains(level) else { return nil }
        return headings[level - 1]
    }
    static func font(
        for role: String, emphasis: Int = 0, inlineCode: Bool = false, context: Font.Context = EnvironmentValues().fontResolutionContext
    ) -> Font {
        var font: Font
        if inlineCode {
            font = .system(
                size: CTFontGetSize(Font.body.resolve(in: context).ctFont) * (heading(for: role)?.ratio ?? 1) * inlineCodeScale,
                design: .monospaced)
        } else if role == "code" {
            font = .body.monospaced()
        } else if let heading = heading(for: role) {
            font = .system(size: CTFontGetSize(Font.body.resolve(in: context).ctFont) * heading.ratio, weight: heading.weight)
        } else {
            font = .body
        }
        if emphasis & 1 != 0 {
            font = heading(for: role) == nil ? font.bold() : font.weight(.bold)
        }
        if emphasis & 2 != 0 { font = font.italic() }
        return font
    }
    static func legacyFont(for role: String) -> Font {
        switch role {
        case "heading:1": .title
        case "heading:2": .title2
        case "heading:3": .title3
        case "heading:4": .headline
        case "heading:5": .subheadline.bold()
        case "heading:6": .footnote.bold()
        default: .body
        }
    }
    static func emphasis(in attributes: AttributeContainer, context: Font.Context) -> Int {
        if let flags = attributes[InlineEmphasisAttribute.self] { return flags }
        let intent = attributes.inlinePresentationIntent ?? []
        let font = (attributes.font ?? .body).resolve(in: context)
        let legacy = legacyFont(for: attributes[ParagraphStyleAttribute.self] ?? "body").resolve(in: context)
        let bold = intent.contains(.stronglyEmphasized) || (font.isBold && !legacy.isBold)
        return (bold ? 1 : 0) | (intent.contains(.emphasized) || font.isItalic ? 2 : 0)
    }
    static func setEmphasis(_ flag: Int, enabled: Bool, in attributes: inout AttributeContainer, context: Font.Context) {
        let current = emphasis(in: attributes, context: context)
        let flags = enabled ? current | flag : current & ~flag
        attributes[InlineEmphasisAttribute.self] = flags
        attributes.font = font(
            for: attributes[ParagraphStyleAttribute.self] ?? "body", emphasis: flags,
            inlineCode: attributes[CodeStyleAttribute.self] == "inline", context: context)
    }
}

enum ParagraphEditing {
    static func paragraphRange(in text: AttributedString, selection: AttributedTextSelection) -> Range<AttributedString.Index>? {
        let nsRange: NSRange
        switch selection.indices(in: text) {
        case .insertionPoint(let index): nsRange = NSRange(index..<index, in: text)
        case .ranges(let ranges):
            guard let first = ranges.ranges.first, let last = ranges.ranges.last else { return nil }
            nsRange = NSRange(first.lowerBound..<last.upperBound, in: text)
        }
        let source = String(text.characters) as NSString
        guard source.length > 0 else { return nil }
        return Range<AttributedString.Index>(source.paragraphRange(for: nsRange), in: text)
    }

    static func apply(
        _ style: String, to text: inout AttributedString, selection: inout AttributedTextSelection,
        context: Font.Context = EnvironmentValues().fontResolutionContext
    ) {
        let originalSelection: NSRange
        let selectionWasInsertionPoint: Bool
        switch selection.indices(in: text) {
        case .insertionPoint(let caret):
            originalSelection = NSRange(caret..<caret, in: text)
            selectionWasInsertionPoint = true
        case .ranges(let ranges):
            guard let first = ranges.ranges.first, let last = ranges.ranges.last else { return }
            originalSelection = NSRange(first.lowerBound..<last.upperBound, in: text)
            selectionWasInsertionPoint = false
        }
        let isEmptyEnd: Bool
        if case .insertionPoint(let caret) = selection.indices(in: text) {
            isEmptyEnd = caret == text.endIndex && (text.characters.isEmpty || text.characters.last == "\n")
        } else {
            isEmptyEnd = false
        }
        guard !isEmptyEnd, let range = paragraphRange(in: text, selection: selection) else {
            var attributes = selection.typingAttributes(in: text)
            attributes[TableAttribute.self] = nil
            if style == "quote" {
                attributes[QuoteAttribute.self] = true
                let role = attributes[ParagraphStyleAttribute.self] ?? "body"
                attributes.font = DocumentTypography.font(
                    for: role,
                    emphasis: DocumentTypography.emphasis(in: attributes, context: context), context: context)
                selection = AttributedTextSelection(insertionPoint: text.endIndex, typingAttributes: attributes)
                return
            }
            if attributes[ParagraphStyleAttribute.self] == style { return }
            attributes[CodeLanguageAttribute.self] = nil
            let emphasis = DocumentTypography.emphasis(in: attributes, context: context)
            attributes[ParagraphStyleAttribute.self] = style
            attributes[InlineEmphasisAttribute.self] = emphasis
            attributes.font = DocumentTypography.font(for: style, emphasis: emphasis, context: context)
            attributes[CodeStyleAttribute.self] = style == "code" ? "block:" + UUID().uuidString : nil
            attributes[TaskStateAttribute.self] = style == "task" ? false : nil
            attributes[ListMarkerAttribute.self] = style == "bullet" ? "•" : style == "numbered" ? "1." : nil
            selection = AttributedTextSelection(insertionPoint: text.endIndex, typingAttributes: attributes)
            return
        }
        if style == "quote" {
            let quoteIsAppliedToEveryRun = text[range].runs.allSatisfy { $0[QuoteAttribute.self] == true }
            text[range][QuoteAttribute.self] = quoteIsAppliedToEveryRun ? nil : true
            return
        }
        guard !text[range].runs.contains(where: { $0[TableAttribute.self] != nil || $0[RenderedContentAttribute.self] != nil }) else {
            return
        }
        let originalRange = NSRange(range, in: text)
        var content = AttributedString(text[range])
        let source = String(content.characters) as NSString
        var paragraphs: [NSRange] = []
        var prefixEdits: [(location: Int, oldLength: Int, newLength: Int)] = []
        var location = 0
        while location < source.length {
            let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
            paragraphs.append(paragraph)
            location = NSMaxRange(paragraph)
        }
        for paragraph in paragraphs.reversed() {
            let line = source.substring(with: paragraph)
            let paragraphRange = Range<AttributedString.Index>(paragraph, in: content)
            let hasSemanticMarker = paragraphRange.flatMap { content[$0].runs.first?[ListMarkerAttribute.self] } != nil
            let oldPrefix = hasSemanticMarker ? "" : MarkdownShortcut.listPrefix(line)?.prefix ?? ""
            let marker: String
            switch style {
            case "bullet": marker = ""
            case "numbered": marker = ""
            case "task": marker = ""
            default: marker = ""
            }
            prefixEdits.append((paragraph.location, oldPrefix.utf16.count, marker.utf16.count))
            if let prefixRange = Range<AttributedString.Index>(
                NSRange(location: paragraph.location, length: oldPrefix.utf16.count), in: content)
            {
                content.replaceSubrange(prefixRange, with: AttributedString(marker))
            }
        }
        let blockID = style == "code" ? "block:" + UUID().uuidString : nil
        for run in Array(content.runs) {
            // Setting an existing role must preserve task completion and code identity.
            if run[ParagraphStyleAttribute.self] == style { continue }
            content[run.range][TaskStateAttribute.self] = style == "task" ? false : nil
            let emphasis = DocumentTypography.emphasis(in: run.attributes, context: context)
            let inlineCode = run[CodeStyleAttribute.self] == "inline" && style != "code"
            content[run.range][ParagraphStyleAttribute.self] = style
            content[run.range][InlineEmphasisAttribute.self] = emphasis
            content[run.range][CodeLanguageAttribute.self] = nil
            content[run.range][CodeStyleAttribute.self] = inlineCode ? "inline" : blockID
            content[run.range].font = DocumentTypography.font(for: style, emphasis: emphasis, inlineCode: inlineCode, context: context)
        }
        if !content.characters.isEmpty {
            let whole = content.startIndex..<content.endIndex
            content[whole][ListMarkerAttribute.self] = nil
            let plain = String(content.characters) as NSString
            var offset = 0
            var number = 1
            while offset < plain.length {
                let paragraph = plain.paragraphRange(for: NSRange(location: offset, length: 0))
                if let range = Range<AttributedString.Index>(paragraph, in: content) {
                    content[range][ListMarkerAttribute.self] = style == "bullet" ? "•" : style == "numbered" ? "\(number)." : nil
                }
                offset = NSMaxRange(paragraph)
                number += 1
            }
        }
        text.replaceSubrange(range, with: content)
        ListMarkerFormatting.normalizeNestedNumbers(in: &text)
        func mappedOffset(_ offset: Int) -> Int {
            var delta = 0
            for edit in prefixEdits.sorted(by: { $0.location < $1.location }) {
                let location = originalRange.location + edit.location
                if offset < location { break }
                if offset <= location + edit.oldLength {
                    return location + delta + edit.newLength
                }
                delta += edit.newLength - edit.oldLength
            }
            return offset + delta
        }
        let start = mappedOffset(originalSelection.location)
        let end = mappedOffset(NSMaxRange(originalSelection))
        ListMarkerFormatting.normalizeNestedNumbers(in: &text)
        if let restored = Range<AttributedString.Index>(NSRange(location: start, length: max(0, end - start)), in: text) {
            selection =
                selectionWasInsertionPoint || restored.isEmpty
                ? AttributedTextSelection(insertionPoint: restored.lowerBound)
                : AttributedTextSelection(range: restored)
        }
    }

    static func indentList(in text: inout AttributedString, selection: inout AttributedTextSelection, outdent: Bool) {
        guard let range = paragraphRange(in: text, selection: selection) else { return }
        let source = String(text.characters) as NSString
        let selected: NSRange
        switch selection.indices(in: text) {
        case .insertionPoint(let caret): selected = NSRange(caret..<caret, in: text)
        case .ranges(let ranges):
            guard let first = ranges.ranges.first, let last = ranges.ranges.last else { return }
            selected = NSRange(first.lowerBound..<last.upperBound, in: text)
        }
        var start = selected.location
        var end = NSMaxRange(selected)
        let affected = NSRange(range, in: text)
        var location = affected.location
        var edits: [NSRange] = []
        while location < NSMaxRange(affected) {
            let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
            let line = source.substring(with: paragraph)
            let depth = line.prefix(while: { $0 == "\t" }).count
            let paragraphRole = Range<AttributedString.Index>(paragraph, in: text)
                .flatMap { text[$0].runs.first?[ParagraphStyleAttribute.self] }
            if MarkdownShortcut.listPrefix(line)?.style != .quote && MarkdownShortcut.listPrefix(line) != nil
                || ["task", "bullet", "numbered"].contains(paragraphRole ?? ""),
                outdent ? depth > 0 : depth < 8
            {
                edits.append(NSRange(location: location, length: outdent ? 1 : 0))
            }
            location = NSMaxRange(paragraph)
        }
        for edit in edits.reversed() {
            guard let target = Range<AttributedString.Index>(edit, in: text) else { continue }
            let attributes = text[target.lowerBound..<text.endIndex].runs.first?.attributes ?? AttributeContainer()
            text.replaceSubrange(target, with: AttributedString(outdent ? "" : "\t", attributes: attributes))
            let delta = outdent ? -1 : 1
            if edit.location <= start { start = max(edit.location, start + delta) }
            if edit.location <= end { end = max(edit.location, end + delta) }
        }
        ListMarkerFormatting.normalizeNestedNumbers(in: &text)
        if let restored = Range<AttributedString.Index>(NSRange(location: start, length: max(0, end - start)), in: text) {
            selection =
                restored.isEmpty ? AttributedTextSelection(insertionPoint: restored.lowerBound) : AttributedTextSelection(range: restored)
        }
    }

    static func font(for style: String, context: Font.Context = EnvironmentValues().fontResolutionContext) -> Font {
        DocumentTypography.font(for: style, context: context)
    }

    /// Read-time migration uses explicit old semantic fonts, never displayed sizes.
    static func migrateLegacyAttributes(_ text: inout AttributedString, context: Font.Context = EnvironmentValues().fontResolutionContext) {
        func paragraphRanges() -> [NSRange] {
            let source = String(text.characters) as NSString
            var result: [NSRange] = []
            var location = 0
            while location < source.length {
                let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
                result.append(paragraph)
                location = NSMaxRange(paragraph)
            }
            return result
        }
        // Old list markers were selectable text. Migrate only explicitly styled lists,
        // and only once; a new list item may legitimately begin with "1. ".
        for paragraph in paragraphRanges().reversed() {
            guard let range = Range<AttributedString.Index>(paragraph, in: text),
                let first = text[range].runs.first,
                ["bullet", "numbered"].contains(first[ParagraphStyleAttribute.self] ?? ""),
                first[ListMarkerAttribute.self] == nil
            else { continue }
            let line = String(text[range].characters)
            guard let prefix = MarkdownShortcut.listPrefix(line) else { continue }
            let indent = line.prefix(while: { $0 == "\t" }).count
            let marker = String(prefix.prefix.dropFirst(indent)).trimmingCharacters(in: .whitespaces)
            text[range][ListMarkerAttribute.self] = marker
            let start = text.characters.index(range.lowerBound, offsetBy: indent)
            let end = text.characters.index(start, offsetBy: prefix.prefix.count - indent)
            text.removeSubrange(start..<end)
        }
        for paragraph in paragraphRanges().reversed() {
            guard let range = Range<AttributedString.Index>(paragraph, in: text),
                text[range].runs.first?[ParagraphStyleAttribute.self] == "quote"
            else { continue }
            text[range][QuoteAttribute.self] = true
            text[range][ParagraphStyleAttribute.self] = "body"
            let line = String(text[range].characters)
            let indentation = line.prefix(while: { $0 == "\t" }).count
            let markerStart = text.characters.index(range.lowerBound, offsetBy: indentation)
            guard text[markerStart...].characters.starts(with: "│ ") else { continue }
            let markerEnd = text.characters.index(markerStart, offsetBy: 2)
            text.removeSubrange(markerStart..<markerEnd)
        }
        for paragraph in paragraphRanges().reversed() {
            guard let range = Range<AttributedString.Index>(paragraph, in: text),
                text[range].runs.first?[ParagraphStyleAttribute.self] == "task"
            else { continue }
            let line = String(text[range].characters)
            let indentation = line.prefix(while: { $0 == "\t" }).count
            let markerStart = text.characters.index(range.lowerBound, offsetBy: indentation)
            let markerEnd = text.characters.index(
                markerStart, offsetBy: min(2, text.characters.distance(from: markerStart, to: range.upperBound)))
            let marker = String(text[markerStart..<markerEnd].characters)
            guard marker == "☐ " || marker == "☑ " else { continue }
            let checked = marker.hasPrefix("☑")
            text.removeSubrange(markerStart..<markerEnd)
            let migratedSource = String(text.characters) as NSString
            let anchor = min(paragraph.location, max(0, migratedSource.length - 1))
            guard migratedSource.length > 0,
                let migratedRange = Range<AttributedString.Index>(
                    migratedSource.paragraphRange(for: NSRange(location: anchor, length: 0)), in: text)
            else { continue }
            text[migratedRange][TaskStateAttribute.self] = checked
        }
        let source = String(text.characters) as NSString
        var location = 0
        while location < source.length {
            let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
            if let range = Range<AttributedString.Index>(paragraph, in: text), let first = text[range].runs.first,
                first[ParagraphStyleAttribute.self] == nil
            {
                let role: String
                if first.font == .title {
                    role = "heading:1"
                } else if first.font == .title2 {
                    role = "heading:2"
                } else if first.font == .title3 {
                    role = "heading:3"
                } else {
                    location = NSMaxRange(paragraph)
                    continue
                }
                text[range][ParagraphStyleAttribute.self] = role
            }
            location = NSMaxRange(paragraph)
        }
        for run in Array(text.runs)
        where run[InlineEmphasisAttribute.self] == nil && run[ParagraphStyleAttribute.self]?.hasPrefix("heading:") == true {
            text[run.range][InlineEmphasisAttribute.self] = DocumentTypography.emphasis(in: run.attributes, context: context)
        }
    }

    static func toggleTask(in text: inout AttributedString, selection: inout AttributedTextSelection) {
        guard let range = paragraphRange(in: text, selection: selection) else { return }
        let selected: NSRange
        switch selection.indices(in: text) {
        case .insertionPoint(let caret): selected = NSRange(caret..<caret, in: text)
        case .ranges(let ranges):
            guard let first = ranges.ranges.first else { return }
            selected = NSRange(first, in: text)
        }
        guard text[range].runs.first?[ParagraphStyleAttribute.self] == "task" else { return }
        let checked = text[range].runs.first?[TaskStateAttribute.self] ?? false
        text[range][TaskStateAttribute.self] = !checked
        if let restored = Range<AttributedString.Index>(selected, in: text) {
            selection =
                restored.isEmpty ? AttributedTextSelection(insertionPoint: restored.lowerBound) : AttributedTextSelection(range: restored)
        }
    }
}

/// Marker presentation is independent of the numeric Markdown representation.
enum ListMarkerFormatting {
    struct Counter {
        private var values: [Int: Int] = [:]

        mutating func marker(_ marker: String?, depth: Int) -> String? {
            guard let marker else {
                values.removeAll()
                return nil
            }
            values = values.filter { $0.key <= depth }
            guard marker != "•" else {
                values.removeValue(forKey: depth)
                return marker
            }
            if depth == 0 { return marker }
            let number = (values[depth] ?? 0) + 1
            values[depth] = number
            return "\(number)."
        }
    }

    static func normalizeNestedNumbers(in text: inout AttributedString) {
        let source = String(text.characters) as NSString
        var location = 0
        var counter = Counter()
        while location < source.length {
            let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
            if let range = Range<AttributedString.Index>(paragraph, in: text) {
                let raw = text[range].runs.first?[ListMarkerAttribute.self]
                let depth = source.substring(with: paragraph).prefix(while: { $0 == "\t" }).count
                let marker = counter.marker(raw, depth: depth)
                if marker != raw { text[range][ListMarkerAttribute.self] = marker }
            }
            location = NSMaxRange(paragraph)
        }
    }

    static func label(for marker: String, depth: Int) -> String {
        let level = max(0, depth) % 3
        if marker == "•" { return ["•", "○", "▪"][level] }
        let number = max(1, Int(marker.dropLast()) ?? 1)
        switch level {
        case 1:
            var value = number
            var letters = ""
            while value > 0 {
                value -= 1
                // The remainder always indexes one of the 26 ASCII lowercase letters.
                let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
                letters = String(alphabet[value % 26]) + letters
                value /= 26
            }
            return letters + "."
        case 2:
            // Bound Roman output for unusually large imported values.
            guard number < 4000 else { return "\(number)." }
            var value = number
            var roman = ""
            for (amount, symbol) in [
                (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"),
                (5, "v"), (4, "iv"), (1, "i"),
            ] {
                while value >= amount {
                    roman += symbol
                    value -= amount
                }
            }
            return roman + "."
        default: return "\(number)."
        }
    }
}
