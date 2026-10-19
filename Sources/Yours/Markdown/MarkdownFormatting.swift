import SwiftUI

/// Markdown interchange for the editor's supported paragraph and inline styles.
enum MarkdownFormatting {
    /// Reformat literal Markdown without erasing already-structured tables or code.
    static func renderKeepingBlocks(_ text: AttributedString) -> AttributedString {
        var result = AttributedString()
        var literal = ""
        for run in text.runs {
            if run[TableAttribute.self] != nil || run[CodeStyleAttribute.self] != nil || run[RenderedContentAttribute.self] != nil {
                if !literal.isEmpty {
                    result += render(literal)
                    literal = ""
                }
                result += AttributedString(text[run.range])
            } else {
                literal += String(text[run.range].characters)
            }
        }
        if !literal.isEmpty { result += render(literal) }
        return result
    }

    static func render(_ source: String) -> AttributedString {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var paragraphs: [AttributedString] = []
        var hardBreaks: Set<Int> = []
        var index = 0
        while index < lines.count {
            let original = lines[index]
            let outer = quoteContent(original)
            if let fence = openingFence(outer.content),
                let closing = lines.indices.dropFirst(index + 1).first(where: {
                    let candidate = quoteContent(lines[$0])
                    return candidate.quoted == outer.quoted && closesFence(candidate.content, fence: fence)
                }),
                closing > index + 1,
                !outer.quoted || (index...closing).allSatisfy({ quoteContent(lines[$0]).quoted })
            {
                let codeID = "block:" + UUID().uuidString
                let literal = lines[(index + 1)..<closing].map { line in
                    outer.quoted ? quoteContent(line).content : line
                }.joined(separator: "\n")
                if CodeBlockEditing.languageTag(from: outer.content) == "mermaid" {
                    var rendered = RenderedContent(kind: .mermaid, source: literal).attributedText
                    rendered[QuoteAttribute.self] = outer.quoted ? true : nil
                    paragraphs.append(rendered)
                    index = closing + 1
                    continue
                }
                var block = AttributedString(literal)
                block.font = .body.monospaced()
                block[CodeStyleAttribute.self] = codeID
                block[CodeLanguageAttribute.self] = CodeBlockEditing.languageTag(from: outer.content)
                block[ParagraphStyleAttribute.self] = "code"
                block[QuoteAttribute.self] = outer.quoted ? true : nil
                paragraphs.append(block)
                index = closing + 1
                continue
            }
            let trimmed = outer.content.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("$$") {
                var formula: String?
                var next = index + 1
                if trimmed.count > 4, trimmed.hasSuffix("$$") {
                    formula = String(trimmed.dropFirst(2).dropLast(2))
                } else if trimmed == "$$",
                    let closing = lines.indices.dropFirst(index + 1).first(where: {
                        let candidate = quoteContent(lines[$0])
                        return candidate.quoted == outer.quoted && candidate.content.trimmingCharacters(in: .whitespaces) == "$$"
                    }), !outer.quoted || (index...closing).allSatisfy({ quoteContent(lines[$0]).quoted })
                {
                    formula = lines[(index + 1)..<closing].map { outer.quoted ? quoteContent($0).content : $0 }.joined(separator: "\n")
                    next = closing + 1
                }
                if let formula, !formula.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var rendered = RenderedContent(kind: .displayMath, source: formula).attributedText
                    rendered[QuoteAttribute.self] = outer.quoted ? true : nil
                    paragraphs.append(rendered)
                    index = next
                    continue
                }
            }
            let tableLines = outer.quoted ? lines.map { quoteContent($0).content } : lines
            if let parsed = TableData.parse(lines: tableLines, at: index),
                !outer.quoted || (index..<(index + parsed.count)).allSatisfy({ quoteContent(lines[$0]).quoted })
            {
                var table = parsed.table.attributedText
                table[QuoteAttribute.self] = outer.quoted ? true : nil
                paragraphs.append(table)
                index += parsed.count
                continue
            }
            var content = outer.content
            let quoted = outer.quoted
            var style = "body"
            var prefix = ""
            var taskChecked: Bool?
            var listMarker: String?
            let indentation = String(content.prefix(while: { $0 == " " || $0 == "\t" }))
            let unindented = String(content.dropFirst(indentation.count))
            let listIndentation = String(
                repeating: "\t", count: indentation.filter { $0 == "\t" }.count + (indentation.filter { $0 == " " }.count + 3) / 4)
            let hashes = content.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), content.dropFirst(hashes).hasPrefix(" ") {
                style = "heading:\(hashes)"
                content = String(content.dropFirst(hashes + 1))
            } else if unindented.hasPrefix("- [ ] ") || unindented.hasPrefix("- [x] ") || unindented.hasPrefix("- [X] ") {
                prefix = listIndentation
                content = String(unindented.dropFirst(6))
                style = "task"
                taskChecked = !unindented.hasPrefix("- [ ] ")
            } else if ["- ", "* ", "+ "].contains(where: unindented.hasPrefix) {
                prefix = listIndentation
                listMarker = "•"
                content = String(unindented.dropFirst(2))
                style = "bullet"
            } else if let range = unindented.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                prefix = listIndentation
                listMarker = String(unindented[range]).trimmingCharacters(in: .whitespaces)
                content = String(unindented[range.upperBound...])
                style = "numbered"
            }
            // Markdown hard breaks are represented by U+2028 inside a native paragraph.
            if index + 1 < lines.count, !lines[index + 1].isEmpty || index + 1 == lines.count - 1,
                content.hasSuffix("  ")
            {
                hardBreaks.insert(paragraphs.count)
                content.removeLast(2)
            }
            var line = inline(content, baseFont: ParagraphEditing.font(for: style))
            if !prefix.isEmpty {
                var marker = AttributedString(prefix)
                marker.font = .body
                line = marker + line
            }
            line[ParagraphStyleAttribute.self] = style
            line[QuoteAttribute.self] = quoted ? true : nil
            line[TaskStateAttribute.self] = taskChecked
            line[ListMarkerAttribute.self] = listMarker
            paragraphs.append(line)
            index += 1
        }
        paragraphs = documentParagraphs(from: paragraphs, hardBreaks: hardBreaks)
        var result = AttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            result += paragraph
            if index < paragraphs.count - 1 {
                var newline = AttributedString("\n")
                let role = paragraph.runs.first?[ParagraphStyleAttribute.self] ?? "body"
                newline[ParagraphStyleAttribute.self] = role
                let quoted = paragraph.runs.first?[QuoteAttribute.self] == true
                newline[QuoteAttribute.self] = quoted ? true : nil
                newline[TaskStateAttribute.self] = paragraph.runs.first?[TaskStateAttribute.self]
                newline[ListMarkerAttribute.self] = paragraph.runs.first?[ListMarkerAttribute.self]
                newline[InlineEmphasisAttribute.self] = 0
                newline.font = ParagraphEditing.font(for: role)
                // Inline marks must not cover the paragraph break or leak into a blank line.
                if paragraph.runs.first?[CodeStyleAttribute.self]?.hasPrefix("block:") == true {
                    // The closing fence ends the block; the following paragraph is body text.
                    newline[ParagraphStyleAttribute.self] = "body"
                    newline.font = .body
                    let nextQuoted = paragraphs[index + 1].runs.first?[QuoteAttribute.self] == true
                    newline[QuoteAttribute.self] = quoted && nextQuoted ? true : nil
                }
                result += newline
            }
        }
        ListMarkerFormatting.normalizeNestedNumbers(in: &result)
        return result
    }

    /// Consume one Markdown separator, retaining any additional explicit blank paragraphs.
    /// Adjacent body source lines stay in one paragraph with a visible line break.
    private static func documentParagraphs(from lines: [AttributedString], hardBreaks: Set<Int>) -> [AttributedString] {
        let first = lines.firstIndex { !$0.characters.isEmpty }
        let last = lines.lastIndex { !$0.characters.isEmpty }
        var paragraphs: [AttributedString] = []
        for (index, line) in lines.enumerated() {
            if line.characters.isEmpty, !hardBreaks.contains(index), !hardBreaks.contains(index - 1),
                let first, let last, index > first, index < last,
                !lines[index - 1].characters.isEmpty
            {
                continue
            }
            let continuesBody =
                index > 0 && !line.characters.isEmpty && !lines[index - 1].characters.isEmpty
                && line.runs.first?[ParagraphStyleAttribute.self] == "body"
                && lines[index - 1].runs.first?[ParagraphStyleAttribute.self] == "body"
                && line.runs.first?[QuoteAttribute.self] != true
                && lines[index - 1].runs.first?[QuoteAttribute.self] != true
            let continuesHardBreak =
                index > 0 && hardBreaks.contains(index - 1)
                && (line.characters.isEmpty || line.runs.first?[ParagraphStyleAttribute.self] == "body")
            if continuesBody || continuesHardBreak {
                let role = paragraphs.last?.runs.first?[ParagraphStyleAttribute.self] ?? "body"
                var lineBreak = AttributedString("\u{2028}")
                lineBreak.font = ParagraphEditing.font(for: role)
                lineBreak[ParagraphStyleAttribute.self] = role
                lineBreak[QuoteAttribute.self] = paragraphs.last?.runs.first?[QuoteAttribute.self]
                lineBreak[InlineEmphasisAttribute.self] = 0
                var continuation = line
                for run in Array(continuation.runs) {
                    continuation[run.range][ParagraphStyleAttribute.self] = role
                    continuation[run.range][QuoteAttribute.self] = paragraphs.last?.runs.first?[QuoteAttribute.self]
                    continuation[run.range].font = DocumentTypography.font(
                        for: role,
                        emphasis: run[InlineEmphasisAttribute.self] ?? 0,
                        inlineCode: run[CodeStyleAttribute.self] == "inline")
                }
                paragraphs[paragraphs.count - 1] += lineBreak + continuation
            } else {
                paragraphs.append(line)
            }
        }
        return paragraphs
    }

    static func serialize(_ text: AttributedString, context: Font.Context) -> String {
        let source = String(text.characters)
        var offset = 0
        var roles: [String?] = []
        var languages: [String?] = []
        var quotes: [Bool] = []
        let paragraphs = source.components(separatedBy: "\n").map { line -> AttributedString in
            let start = text.characters.index(text.startIndex, offsetBy: offset)
            let end = text.characters.index(start, offsetBy: line.count)
            roles.append(
                start < text.endIndex ? text[start..<text.characters.index(after: start)].runs.first?[CodeStyleAttribute.self] : nil)
            languages.append(
                start < text.endIndex ? text[start..<text.characters.index(after: start)].runs.first?[CodeLanguageAttribute.self] : nil)
            quotes.append(
                start < text.endIndex ? text[start..<text.characters.index(after: start)].runs.first?[QuoteAttribute.self] == true : false)
            offset += line.count + 1
            return AttributedString(text[start..<end])
        }
        var output: [String] = []
        var outputStyles: [String] = []
        var index = 0
        while index < paragraphs.count {
            let paragraph = paragraphs[index]
            let role = roles[index]
            if let rendered = paragraph.runs.first?[RenderedContentAttribute.self], rendered.isBlock {
                output.append(quotes[index] ? quotedMarkdown(rendered.markdown) : rendered.markdown)
                outputStyles.append(quotes[index] ? "quote" : "rendered")
                index += 1
                continue
            }
            if let table = paragraph.runs.first?[TableAttribute.self] {
                let markdown = quotes[index] ? quotedMarkdown(table.markdown) : table.markdown
                output.append(markdown)
                outputStyles.append(quotes[index] ? "quote" : "table")
                index += 1
                continue
            }
            if let role, role.hasPrefix("block:") {
                let quoted = quotes[index]
                let language = languages[index] ?? ""
                var code = [String(paragraph.characters)]
                index += 1
                while index < paragraphs.count,
                    roles[index] == role
                {
                    code.append(String(paragraphs[index].characters))
                    index += 1
                }
                let literal = code.joined(separator: "\n")
                let fence = String(repeating: "`", count: max(3, longestBacktickRun(literal) + 1))
                let markdown = fence + language + "\n" + literal + "\n" + fence
                output.append(quoted ? quotedMarkdown(markdown) : markdown)
                outputStyles.append(quoted ? "quote" : "code")
                continue
            }
            let style = paragraph.runs.first?[ParagraphStyleAttribute.self] ?? "body"
            let quoted = quotes[index] || style == "quote"
            let literal = String(paragraph.characters)
            let indentation = String(literal.prefix(while: { $0 == " " || $0 == "\t" }))
            let body = String(literal.dropFirst(indentation.count))
            var prefix = ""
            var skip = 0
            if style.hasPrefix("heading:"), let level = Int(style.dropFirst(8)), (1...6).contains(level) {
                prefix = String(repeating: "#", count: level) + " "
            } else if body.hasPrefix("│ ") {
                skip = body.hasPrefix("│ ") ? indentation.count + 2 : 0
            } else if style == "task" {
                prefix = indentation + ((paragraph.runs.first?[TaskStateAttribute.self] ?? false) ? "- [x] " : "- [ ] ")
                skip = indentation.count
            } else if let marker = paragraph.runs.first?[ListMarkerAttribute.self], ["bullet", "numbered"].contains(style) {
                prefix = indentation + (style == "bullet" ? "-" : marker) + " "
                skip = indentation.count
            } else if body.hasPrefix("• ") || body.hasPrefix("☐ ") || body.hasPrefix("☑ ") {
                prefix = indentation + (body.hasPrefix("• ") ? "- " : body.hasPrefix("☐ ") ? "- [ ] " : "- [x] ")
                skip = indentation.count + 2
            } else if style == "numbered" || paragraph.runs.first?[ParagraphStyleAttribute.self] == "body",
                let range = body.range(of: #"^\d+[.)] "#, options: .regularExpression)
            {
                prefix = indentation + String(body[range])
                skip = prefix.count
            }
            let start = paragraph.characters.index(paragraph.startIndex, offsetBy: skip)
            output.append(
                (quoted ? "> " : "") + prefix + serializeInline(AttributedString(paragraph[start...]), style: style, context: context))
            outputStyles.append(quoted ? "quote" : prefix.hasSuffix("- ") || prefix.contains("- [") ? "list" : style)
            index += 1
        }
        var markdown = ""
        let lastContent = output.lastIndex { !$0.isEmpty } ?? -1
        for (index, paragraph) in output.enumerated() {
            if index > 0 {
                markdown += "\n"
                let previous = output[index - 1]
                if !previous.isEmpty, !paragraph.isEmpty {
                    let style = outputStyles[index]
                    let sameList =
                        ["list", "bullet", "task", "numbered", "quote"].contains(style)
                        && style == outputStyles[index - 1]
                    if !sameList { markdown += "\n" }
                } else if !previous.isEmpty, paragraph.isEmpty, index < lastContent {
                    // One extra source blank line is syntax; the remaining ones are content.
                    markdown += "\n"
                }
            }
            markdown += paragraph
        }
        return markdown
    }

    private static func serializeInline(_ text: AttributedString, style: String, context: Font.Context) -> String {
        if text.characters.contains("\u{2028}") {
            var lines: [String] = []
            var start = text.startIndex
            for index in text.characters.indices where text.characters[index] == "\u{2028}" {
                lines.append(serializeInline(AttributedString(text[start..<index]), style: style, context: context))
                start = text.characters.index(after: index)
            }
            lines.append(serializeInline(AttributedString(text[start...]), style: style, context: context))
            return lines.joined(separator: "  \n")
        }
        // Coalesce runs that differ only in editor-only attributes before writing delimiters.
        var normalized = AttributedString()
        for run in text.runs {
            var segment = AttributedString(text[run.range].characters)
            var intent: InlinePresentationIntent = []
            let emphasis = DocumentTypography.emphasis(in: run.attributes, context: context)
            if emphasis & 1 != 0 { intent.insert(.stronglyEmphasized) }
            if emphasis & 2 != 0 { intent.insert(.emphasized) }
            if run.strikethroughStyle != nil { intent.insert(.strikethrough) }
            if run[CodeStyleAttribute.self] == "inline" { intent.insert(.code) }
            segment.inlinePresentationIntent = intent
            segment.link = run.link
            segment[RenderedContentAttribute.self] = run[RenderedContentAttribute.self]
            normalized += segment
        }
        return normalized.runs.map { run in
            if let rendered = run[RenderedContentAttribute.self] { return rendered.markdown }
            let literal = String(normalized[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var content: String
            if intent.contains(.code) {
                let delimiter = String(repeating: "`", count: longestBacktickRun(literal) + 1)
                let pad =
                    literal.hasPrefix("`") || literal.hasSuffix("`")
                    || (literal.hasPrefix(" ") && literal.hasSuffix(" ") && !literal.allSatisfy({ $0 == " " }))
                content = delimiter + (pad ? " " : "") + literal + (pad ? " " : "") + delimiter
            } else {
                let leading = String(literal.prefix(while: { $0.isWhitespace }))
                let remainder = String(literal.dropFirst(leading.count))
                let trailing = String(remainder.reversed().prefix(while: { $0.isWhitespace }).reversed())
                content = escape(String(remainder.dropLast(trailing.count)))
                if !content.isEmpty {
                    if intent.contains(.stronglyEmphasized) { content = "**" + content + "**" }
                    if intent.contains(.emphasized) { content = "*" + content + "*" }
                    if intent.contains(.strikethrough) { content = "~~" + content + "~~" }
                }
                content = leading + content + trailing
            }
            if let link = run.link {
                let destination = link.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                    .replacingOccurrences(of: " ", with: "%20")
                content = "[" + content + "](" + destination + ")"
            }
            return content
        }.joined()
    }

    private static func escape(_ source: String) -> String {
        source.reduce(into: "") { result, character in
            if "\\`*_{}[]<>()#+-.!|~>$".contains(character) { result.append("\\") }
            result.append(character)
        }
    }

    private static func longestBacktickRun(_ source: String) -> Int {
        var longest = 0
        var current = 0
        for character in source {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }

    private static func openingFence(_ line: String) -> String? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let fence = String(line.prefix(while: { $0 == first }))
        return fence.count >= 3 ? fence : nil
    }

    private static func quoteContent(_ line: String) -> (quoted: Bool, content: String) {
        guard line.hasPrefix(">") else { return (false, line) }
        let remainder = line.dropFirst()
        return (true, remainder.first == " " ? String(remainder.dropFirst()) : String(remainder))
    }

    private static func quotedMarkdown(_ source: String) -> String {
        source.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
    }

    private static func closesFence(_ line: String, fence: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= fence.count && trimmed.allSatisfy { $0 == fence.first }
    }

    private static func preservingUnsupportedSyntax(_ source: String) -> String {
        var result = ""
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "\\" {
                result.append(character)
                index = source.index(after: index)
                if index < source.endIndex {
                    result.append(source[index])
                    index = source.index(after: index)
                }
                continue
            }
            if character == "`" {
                let delimiter = String(source[index...].prefix(while: { $0 == "`" }))
                let afterOpening = source.index(index, offsetBy: delimiter.count)
                if let closing = source.range(of: delimiter, range: afterOpening..<source.endIndex) {
                    result += source[index..<closing.upperBound]
                    index = closing.upperBound
                    continue
                }
            }
            if source[index...].hasPrefix("!["),
                let ending = source[index...].firstIndex(of: "]")
            {
                let end = source.index(after: ending)
                result += escape(String(source[index..<end]))
                index = end
                continue
            }
            if character == "<" { result.append("\\") }
            result.append(character)
            index = source.index(after: index)
        }
        return result
    }

    private static func inline(_ source: String, baseFont: Font) -> AttributedString {
        // Images are not part of the text data model. Keep their complete syntax visible.
        let protected = MathMarkdown.protect(source)
        let safeSource = preservingUnsupportedSyntax(protected.text)
        var text =
            (try? AttributedString(markdown: safeSource, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = baseFont
            if intent.contains(.stronglyEmphasized) { font = baseFont == .body ? font.bold() : font.weight(.bold) }
            if intent.contains(.emphasized) { font = font.italic() }
            if intent.contains(.code) {
                font = .body.monospaced()
                text[run.range][CodeStyleAttribute.self] = "inline"
            }
            text[run.range].font = font
            text[run.range][InlineEmphasisAttribute.self] =
                (intent.contains(.stronglyEmphasized) ? 1 : 0) | (intent.contains(.emphasized) ? 2 : 0)
            if intent.contains(.strikethrough) { text[run.range].strikethroughStyle = .single }
        }
        // Foundation can omit presentation intents inside a link label. Recover them
        // from the label itself before the native bridge converts semantic fonts.
        if let links = try? NSRegularExpression(pattern: #"(?<!!|\\)\[([^\n]*?)\]\(([^ \n]+?)\)"#) {
            let nsSource = safeSource as NSString
            for match in links.matches(in: safeSource, range: NSRange(location: 0, length: nsSource.length)) {
                let labelSource = nsSource.substring(with: match.range(at: 1))
                let label = inline(labelSource, baseFont: baseFont)
                let labelString = String(label.characters)
                let destination = nsSource.substring(with: match.range(at: 2))
                for run in Array(text.runs)
                where run.link?.absoluteString == destination && String(text[run.range].characters) == labelString {
                    var replacement = label
                    replacement.link = run.link
                    text.replaceSubrange(run.range, with: replacement)
                    break
                }
            }
        }
        for (token, expression) in protected.expressions {
            if let range = text.range(of: token) {
                var replacement = expression.attributedText
                if let attributes = text[range].runs.first?.attributes { replacement.mergeAttributes(attributes) }
                replacement[RenderedContentAttribute.self] = expression
                text.replaceSubrange(range, with: replacement)
            }
        }
        return text
    }
}
