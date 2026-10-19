import SwiftUI

/// Private clipboard representation; pasted document objects always receive fresh identities.
enum RichTextClipboard {
    enum ClipboardError: Error, Equatable {
        case unsupportedVersion(Int)
        case invalidTableRange
    }

    private struct Payload: Codable {
        let richText: AttributedString
        private enum CodingKeys: String, CodingKey { case version, richText }

        init(richText: AttributedString) { self.richText = richText }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let version = try container.decode(Int.self, forKey: .version)
            guard version == 1 else { throw ClipboardError.unsupportedVersion(version) }
            richText = try container.decode(AttributedString.self, forKey: .richText, configuration: NoteAttributeScope.self)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(1, forKey: .version)
            try container.encode(richText, forKey: .richText, configuration: NoteAttributeScope.self)
        }
    }

    static func encode(_ text: AttributedString) throws -> Data {
        try validateTables(in: text)
        return try JSONEncoder().encode(Payload(richText: text))
    }

    static func decode(_ data: Data) throws -> AttributedString {
        let original = try JSONDecoder().decode(Payload.self, from: data).richText
        try validateTables(in: original)
        var pasted = original
        ParagraphEditing.migrateLegacyAttributes(&pasted)
        var codeIDs: [String: String] = [:]
        let migrated = pasted
        for run in migrated.runs {
            if var rendered = run[RenderedContentAttribute.self] {
                rendered.id = UUID()
                pasted[run.range][RenderedContentAttribute.self] = rendered
            }
            if var table = run[TableAttribute.self] {
                table.id = UUID()
                pasted[run.range][TableAttribute.self] = table
            }
            if let id = run[CodeStyleAttribute.self], id.hasPrefix("block:") {
                let replacement = codeIDs[id] ?? "block:" + UUID().uuidString
                codeIDs[id] = replacement
                pasted[run.range][CodeStyleAttribute.self] = replacement
            }
        }
        return pasted
    }

    /// Only intercept text with supported Markdown semantics. Ordinary text keeps native
    /// paste behavior, including its exact line breaks and the current typing attributes.
    static func renderMarkdown(_ source: String, hasRichText: Bool = false) -> AttributedString? {
        // Preserve the native selected-label + URL command instead of replacing its label.
        if !source.contains(where: { $0.isWhitespace }), let url = URL(string: source),
            ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
        {
            return nil
        }
        let normalized = source.replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        let rendered = MarkdownFormatting.render(normalized)
        if hasRichText {
            // Browsers also put HTML on the clipboard for literal LaTeX. Only
            // override native rich paste for a complete, standalone formula.
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            let objects = rendered.runs.compactMap { $0[RenderedContentAttribute.self] }
            guard trimmed.hasPrefix("$"), trimmed.hasSuffix("$"), objects.count == 1,
                objects[0].kind != .mermaid,
                rendered.runs.allSatisfy({ run in
                    run[RenderedContentAttribute.self] != nil
                        || rendered[run.range].characters.allSatisfy(\.isWhitespace)
                })
            else { return nil }
        }
        let hasFormatting = rendered.runs.contains { run in
            (run[ParagraphStyleAttribute.self] ?? "body") != "body"
                || run[QuoteAttribute.self] == true
                || run[CodeStyleAttribute.self] != nil
                || run[RenderedContentAttribute.self] != nil
                || (run[InlineEmphasisAttribute.self] ?? 0) != 0
                || run.strikethroughStyle != nil
                || run.link != nil
        }
        return hasFormatting ? rendered : nil
    }

    /// Convert only formula ranges; retain the native attributes of all surrounding text.
    @MainActor static func renderFormulas(in original: NSAttributedString, context: Font.Context) -> NSAttributedString? {
        let normalized = original.string.replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
        let source = normalized as NSString
        let pattern = #"(?m)^[\t ]*\$\$(?:([^\n]+?)\$\$[\t ]*$|[\t ]*\n([\s\S]*?)^[\t ]*\$\$[\t ]*$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        var matches: [(NSRange, RenderedContent)] = regex.matches(in: normalized, range: NSRange(location: 0, length: source.length))
            .compactMap { match in
                let range = match.range(at: match.range(at: 1).location != NSNotFound ? 1 : 2)
                let formula = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                return formula.isEmpty ? nil : (match.range, RenderedContent(kind: .displayMath, source: formula))
            }
        matches += MathMarkdown.protect(normalized).ranges.filter { candidate in
            !matches.contains { NSIntersectionRange($0.0, candidate.0).length > 0 }
        }
        let result = NSMutableAttributedString(attributedString: original)
        var converted = false
        for (range, content) in matches.sorted(by: { $0.0.location > $1.0.location }) {
            var protected = false
            original.enumerateAttributes(in: range) { attributes, _, stop in
                let font = attributes[.font] as? PlatformFont
                #if os(macOS)
                    let codeFont = font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true
                #else
                    let codeFont = font?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true
                #endif
                if attributes[.link] != nil || attributes[.attachment] != nil || attributes[.yoursCodeStyle] != nil || codeFont {
                    protected = true
                    stop.pointee = true
                }
            }
            guard !protected else { continue }
            let replacement = NSMutableAttributedString(
                attributedString: NativeTextAttributes.native(content.attributedText, context: context))
            if let font = original.attribute(.font, at: range.location, effectiveRange: nil) {
                replacement.addAttributes([.font: font, .yoursStoredFont: font], range: NSRange(location: 0, length: replacement.length))
            }
            if let paragraph = original.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) {
                replacement.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: replacement.length))
            }
            result.replaceCharacters(in: range, with: replacement)
            converted = true
        }
        return converted ? result : nil
    }

    private static func validateTables(in text: AttributedString) throws {
        for run in text.runs where run[TableAttribute.self] != nil || run[RenderedContentAttribute.self] != nil {
            guard String(text[run.range].characters) == "\u{FFFC}" else {
                throw ClipboardError.invalidTableRange
            }
        }
    }
}
