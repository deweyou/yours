import CoreText
import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Keep semantic SwiftUI fonts unchanged, but replace opaque platform-font archives
/// with a small descriptor that can be reconstructed on both Apple platforms.
enum PortableFontAttribute: CodableAttributedStringKey {
    typealias Value = Font
    static let name = AttributeScopes.SwiftUIAttributes.FontAttribute.name

    private struct LegacyFont: Encodable {
        let font: Font
        func encode(to encoder: any Encoder) throws {
            try AttributeScopes.SwiftUIAttributes.FontAttribute.encode(font, to: encoder)
        }
    }

    private struct Descriptor: Codable, Hashable {
        var yoursFontVersion: Int
        var name: String
        var size: Double
        var traits: UInt32
        var weight: Double

        init(_ resolved: CTFont) {
            yoursFontVersion = 1
            name = CTFontCopyPostScriptName(resolved) as String
            size = CTFontGetSize(resolved)
            traits = CTFontGetSymbolicTraits(resolved).rawValue
            weight = (CTFontCopyTraits(resolved) as NSDictionary)[kCTFontWeightTrait] as? Double ?? 0
        }

        func font() throws -> Font {
            guard !name.hasPrefix("SourceHanSerif") || BundledSerifFont.isRegistered else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Bundled document font is unavailable."))
            }
            // System font names differ between AppKit and UIKit. Recreate
            // those through the local platform API, retaining size and traits.
            if name.hasPrefix(".SF") || name.hasPrefix("UICTFont") {
                let symbolic = CTFontSymbolicTraits(rawValue: traits)
                let fontWeight = PlatformFont.Weight(rawValue: weight)
                var font =
                    (symbolic.contains(.traitMonoSpace) || name.contains("Mono"))
                    ? PlatformFont.monospacedSystemFont(ofSize: size, weight: fontWeight)
                    : PlatformFont.systemFont(ofSize: size, weight: fontWeight)
                if symbolic.contains(.traitItalic) {
                    #if os(macOS)
                        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    #else
                        if let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
                            font = UIFont(descriptor: descriptor, size: size)
                        }
                    #endif
                }
                return Font(font as CTFont)
            }
            return Font(CTFontCreateWithName(name as CFString, size, nil))
        }
    }

    static func encode(_ value: Font, to encoder: any Encoder) throws {
        // Some fonts decoded from legacy archives cannot be encoded again by
        // SwiftUI (invalidFont). They still resolve through CoreText, so migrate
        // their public font identity instead of embedding font binaries again.
        if let encoded = try? JSONEncoder().encode(LegacyFont(font: value)),
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
            let tag = object["tag"] as? [String: Any], tag["platform"] == nil
        {
            try AttributeScopes.SwiftUIAttributes.FontAttribute.encode(value, to: encoder)
        } else {
            try Descriptor(value.resolve(in: EnvironmentValues().fontResolutionContext).ctFont).encode(to: encoder)
        }
    }

    static func decode(from decoder: any Decoder) throws -> Font {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.yoursFontVersion) {
            let descriptor = try Descriptor(from: decoder)
            guard descriptor.yoursFontVersion == 1, !descriptor.name.isEmpty, descriptor.size.isFinite, descriptor.size > 0,
                descriptor.weight.isFinite
            else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invalid portable font descriptor."))
            }
            return try descriptor.font()
        }
        // Legacy archives remain readable on the originating platform. Their
        // next save migrates platform fonts without changing document content.
        return try AttributeScopes.SwiftUIAttributes.FontAttribute.decode(from: decoder)
    }

    private enum ComparisonFontAttribute: CodableAttributedStringKey {
        typealias Value = Descriptor
        static let name = "yours.comparisonFont"
    }

    private struct ComparisonScope: AttributeScope {
        let original: NoteAttributeScope
        let comparison: ComparisonFontAttribute
    }

    private struct Fingerprint: Encodable {
        let text: AttributedString
        func encode(to encoder: any Encoder) throws {
            try text.encode(to: encoder, configuration: ComparisonScope.encodingConfiguration)
        }
    }

    static func fingerprint(_ text: AttributedString) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Fingerprint(text: comparable(text)))
    }

    /// Font provider identity is platform-specific; compare resolved typography
    /// while retaining every other rich-text attribute and document field.
    static func comparable(_ text: AttributedString) -> AttributedString {
        var result = text
        for run in text.runs {
            guard let font = run.font else { continue }
            var descriptor = Descriptor(font.resolve(in: EnvironmentValues().fontResolutionContext).ctFont)
            let isSystem = descriptor.name.hasPrefix(".SF") || descriptor.name.hasPrefix("UICTFont")
            let monospaced = descriptor.name.contains("Mono")
            if isSystem { descriptor.name = "system" }
            descriptor.traits &= CTFontSymbolicTraits([.traitBold, .traitItalic, .traitMonoSpace]).rawValue
            if monospaced { descriptor.traits |= CTFontSymbolicTraits.traitMonoSpace.rawValue }
            descriptor.weight = isSystem ? (descriptor.weight * 1_000).rounded() / 1_000 : 0
            result[run.range].font = nil
            result[run.range][ComparisonFontAttribute.self] = descriptor
        }
        return result
    }

    private enum CodingKeys: String, CodingKey { case yoursFontVersion }

}

struct NoteSwiftUIAttributes: AttributeScope {
    let font: PortableFontAttribute
    let foregroundColor: AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
    let backgroundColor: AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute
    let strikethroughStyle: AttributeScopes.SwiftUIAttributes.StrikethroughStyleAttribute
    let underlineStyle: AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute
    let kern: AttributeScopes.SwiftUIAttributes.KerningAttribute
    let tracking: AttributeScopes.SwiftUIAttributes.TrackingAttribute
    let baselineOffset: AttributeScopes.SwiftUIAttributes.BaselineOffsetAttribute
    let alignment: AttributeScopes.CoreTextAttributes.TextAlignmentAttribute
    let lineHeight: AttributeScopes.CoreTextAttributes.LineHeightAttribute
    let adaptiveImageGlyph: AttributeScopes.SwiftUIAttributes.AdaptiveImageGlyphAttribute
    let accessibility: AttributeScopes.AccessibilityAttributes
    let foundation: AttributeScopes.FoundationAttributes
}
