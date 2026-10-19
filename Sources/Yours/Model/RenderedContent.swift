import SwiftUI

/// Source is the durable document value; rendered pixels and dimensions are disposable.
struct RenderedContent: Codable, Equatable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case inlineMath, displayMath, mermaid }
    var id = UUID()
    var kind: Kind
    var source: String

    var isBlock: Bool { kind != .inlineMath }
    var markdown: String {
        switch kind {
        case .inlineMath: return "$" + source + "$"
        case .displayMath: return "$$\n" + source + "\n$$"
        case .mermaid:
            let longest = source.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
            let fence = String(repeating: "`", count: max(3, longest + 1))
            return fence + "mermaid\n" + source + "\n" + fence
        }
    }
    var attributedText: AttributedString {
        var text = AttributedString("\u{FFFC}")
        text[RenderedContentAttribute.self] = self
        text[ParagraphStyleAttribute.self] = isBlock ? "rendered" : "body"
        text.font = .body
        return text
    }
}

enum RenderedContentAttribute: CodableAttributedStringKey {
    typealias Value = RenderedContent
    static let name = "yours.renderedContent"
}

/// Protect math before Foundation interprets backslashes, underscores, or emphasis.
/// Code spans, escaped dollars and link destinations remain ordinary Markdown.
enum MathMarkdown {
    static func protect(_ source: String) -> (text: String, expressions: [(String, RenderedContent)], ranges: [(NSRange, RenderedContent)])
    {
        let chars = Array(source)
        var output = ""
        var expressions: [(String, RenderedContent)] = []
        var ranges: [(NSRange, RenderedContent)] = []
        var offsets = [0]
        var offset = 0
        for character in chars {
            offset += String(character).utf16.count
            offsets.append(offset)
        }
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                output += String(chars[i...i + 1])
                i += 2
                continue
            }
            if chars[i] == "`" {
                let start = i
                while i < chars.count && chars[i] == "`" { i += 1 }
                let count = i - start
                var end = i
                while end < chars.count {
                    if chars[end] == "`" {
                        let begin = end
                        while end < chars.count && chars[end] == "`" { end += 1 }
                        if end - begin == count { break }
                    } else {
                        end += 1
                    }
                }
                output += String(chars[start..<end])
                i = end
                continue
            }
            if chars[i] == "]", i + 1 < chars.count, chars[i + 1] == "(" {
                var end = i + 2
                var depth = 1
                while end < chars.count && depth > 0 {
                    if chars[end] == "\\" {
                        end = min(chars.count, end + 2)
                        continue
                    }
                    if chars[end] == "(" { depth += 1 }
                    if chars[end] == ")" { depth -= 1 }
                    end += 1
                }
                output += String(chars[i..<end])
                i = end
                continue
            }
            if chars[i] == "$", i + 1 < chars.count, chars[i + 1] != "$", !chars[i + 1].isWhitespace,
                i == 0 || chars[i - 1] != "$"
            {
                var end = i + 1
                while end < chars.count && !chars[end].isNewline {
                    if chars[end] == "\\" {
                        end += 2
                        continue
                    }
                    if chars[end] == "$" { break }
                    end += 1
                }
                if end < chars.count, chars[end] == "$", end > i + 1, !chars[end - 1].isWhitespace,
                    end + 1 == chars.count || (!chars[end + 1].isNumber && chars[end + 1] != "$")
                {
                    let token = "YORSMATH" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    let content = RenderedContent(kind: .inlineMath, source: String(chars[(i + 1)..<end]))
                    expressions.append((token, content))
                    ranges.append((NSRange(location: offsets[i], length: offsets[end + 1] - offsets[i]), content))
                    output += token
                    i = end + 1
                    continue
                }
            }
            output.append(chars[i])
            i += 1
        }
        return (output, expressions, ranges)
    }
}
