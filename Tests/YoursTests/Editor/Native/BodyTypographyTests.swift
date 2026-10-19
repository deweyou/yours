import CoreText
import SwiftUI
import Testing

@testable import Yours

#if os(macOS)
    import AppKit
#endif

@MainActor
struct BodyTypographyTests {
    @Test(
        arguments: ["body", "heading:1", "heading:2", "heading:3", "heading:4", "heading:5", "heading:6", "bullet", "task", "quote"],
        [0, 1, 2, 3])
    func displayProjectionPreservesStoredFontAndEmphasis(role: String, emphasis: Int) throws {
        let context = EnvironmentValues().fontResolutionContext
        var text = AttributedString("中文 English 2026 👋")
        text[ParagraphStyleAttribute.self] = role
        text[InlineEmphasisAttribute.self] = emphasis
        text.font = DocumentTypography.font(for: role, emphasis: emphasis, context: context)
        let original = try #require(text.font).resolve(in: context).ctFont
        for _ in 0..<3 {
            let native = NativeTextAttributes.native(text, context: context)
            let display = try #require(native.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont) as CTFont
            let expectedName =
                role.hasPrefix("heading:")
                ? (emphasis & 1 != 0 ? BundledSerifFont.heavyName : BundledSerifFont.mediumName)
                : (emphasis & 1 != 0 ? BundledSerifFont.boldName : BundledSerifFont.lightName)
            #expect(CTFontCopyPostScriptName(display) as String == expectedName)
            #expect(abs(CTFontGetSize(display) - CTFontGetSize(original) * DocumentTypography.readingScale) < 0.001)
            #expect((CTFontGetMatrix(display).c != 0) == (emphasis & 2 != 0))
            text = NativeTextAttributes.rich(native)
            let restored = try #require(text.font).resolve(in: context).ctFont
            #expect(CTFontCopyPostScriptName(restored) == CTFontCopyPostScriptName(original))
            #expect(CTFontGetSymbolicTraits(restored) == CTFontGetSymbolicTraits(original))
            #expect(abs(CTFontGetSize(restored) - CTFontGetSize(original)) < 0.001)
            #expect(text[InlineEmphasisAttribute.self] == emphasis)
        }
        let note = Note(id: UUID(), text: String(text.characters), createdAt: .distantPast, updatedAt: .distantPast)
        var saved = note
        saved.richText = text
        let encoded = try JSONEncoder().encode(saved)
        let payload = String(decoding: encoded, as: UTF8.self)
        #expect(payload.contains("SourceHanSerif") == false)
        #expect(payload.contains("yours.storedFont") == false)
        let decoded = try JSONDecoder().decode(Note.self, from: encoded)
        #expect(decoded.richText[InlineEmphasisAttribute.self] == emphasis)
    }

    @Test(arguments: ["inline", "block:test"])
    func codeKeepsMonospacedFont(style: String) throws {
        let context = EnvironmentValues().fontResolutionContext
        var text = AttributedString("let value = 1")
        text.font = .body.monospaced().bold().italic()
        text[CodeStyleAttribute.self] = style
        text[ParagraphStyleAttribute.self] = style == "inline" ? "body" : "code"
        text[InlineEmphasisAttribute.self] = 3
        let native = NativeTextAttributes.native(text, context: context)
        let font = try #require(native.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont) as CTFont
        #expect(Font(font).resolve(in: context).isMonospaced)
        #expect(CTFontGetSymbolicTraits(font).contains(.traitBold))
        #expect(CTFontGetSymbolicTraits(font).contains(.traitItalic))
        let stored = NativeTextAttributes.rich(native)
        let storedResolved = try #require(stored.font).resolve(in: context)
        #expect(storedResolved.isMonospaced, "Stored font: \(CTFontCopyPostScriptName(storedResolved.ctFont))")
        #expect(stored[CodeStyleAttribute.self] == style)
    }

    @Test(arguments: ["SourceHanSerifCN-Regular", "PingFangSC-Regular", "Georgia"])
    func explicitCustomFontIsNotReplaced(name: String) throws {
        let context = EnvironmentValues().fontResolutionContext
        try #require(BundledSerifFont.isRegistered)
        var text = AttributedString("自选字体 custom")
        text.font = .custom(name, fixedSize: 19)
        let original = try #require(text.font).resolve(in: context).ctFont
        let native = NativeTextAttributes.native(text, context: context)
        let restored = try #require(NativeTextAttributes.rich(native).font).resolve(in: context).ctFont
        #expect(CTFontCopyPostScriptName(restored) == CTFontCopyPostScriptName(original))
        #expect(CTFontGetSize(restored) == CTFontGetSize(original))
    }

    @Test(arguments: ["zh-Hans", "zh-Hant", "zh-HK"], [0, 1, 2, 3])
    func persistedSystemChineseFallbackUsesSerifAndKeepsOriginalFont(language: String, emphasis: Int) throws {
        let context = EnvironmentValues().fontResolutionContext
        let system = try #require(CTFontCreateUIFontForLanguage(.system, 13, language as CFString))
        let fallback = CTFontCreateForString(system, "中文" as CFString, CFRange(location: 0, length: 2))
        var text = AttributedString("正文引用列表中文")
        text.font = Font(fallback)
        text[ParagraphStyleAttribute.self] = "body"
        text[InlineEmphasisAttribute.self] = emphasis
        text[QuoteAttribute.self] = true
        let native = NativeTextAttributes.native(text, context: context)
        let display = try #require(native.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont) as CTFont
        #expect(
            CTFontCopyPostScriptName(display) as String == (emphasis & 1 != 0 ? BundledSerifFont.boldName : BundledSerifFont.lightName))
        #expect((CTFontGetMatrix(display).c != 0) == (emphasis & 2 != 0))
        let restored = NativeTextAttributes.rich(native)
        let original = try #require(restored.font).resolve(in: context).ctFont
        #expect(CTFontCopyPostScriptName(original) as String == CTFontCopyPostScriptName(fallback) as String)
        #expect(restored[InlineEmphasisAttribute.self] == emphasis)
        #expect(restored[QuoteAttribute.self] == true)
    }

    @Test func tableHeaderProjectionUsesRealBoldFace() {
        let context = EnvironmentValues().fontResolutionContext
        let header = NativeTextAttributes.displayFont(Font.body.weight(.semibold).resolve(in: context).ctFont)
        let body = NativeTextAttributes.displayFont(Font.body.resolve(in: context).ctFont)
        #expect(CTFontCopyPostScriptName(header) as String == BundledSerifFont.boldName)
        #expect(CTFontCopyPostScriptName(body) as String == BundledSerifFont.lightName)
        #expect(CTFontGetSize(header) == CTFontGetSize(body))
    }
    @Test(arguments: ["body", "heading:2", "quote"])
    func defaultDisplayColorsDoNotPersistAndCustomColorsSurvive(role: String) throws {
        let context = EnvironmentValues().fontResolutionContext
        var text = AttributedString("默认正文 custom")
        text[ParagraphStyleAttribute.self] = role
        text.font = .body
        if role == "quote" { text[QuoteAttribute.self] = true }
        let native = NativeTextAttributes.native(text, context: context)
        #expect(NativeTextAttributes.rich(native).foregroundColor == nil)
        for color in [Color.red, Color.black, Color(red: 0.2, green: 0.2, blue: 0.2)] {
            text.foregroundColor = color
            let restored = NativeTextAttributes.rich(NativeTextAttributes.native(text, context: context))
            let saved = try #require(restored.foregroundColor)
            let actual = saved.resolve(in: EnvironmentValues())
            let expected = color.resolve(in: EnvironmentValues())
            #expect(abs(actual.red - expected.red) < 0.001)
            #expect(abs(actual.green - expected.green) < 0.001)
            #expect(abs(actual.blue - expected.blue) < 0.001)
            #expect(abs(actual.opacity - expected.opacity) < 0.001)
        }
    }

    #if os(macOS)
        @Test func documentPaletteAdaptsToAppearanceAndContrast() throws {
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try #require(NSAppearance(named: name))
                appearance.performAsCurrentDrawingAppearance {
                    guard let body = AppTheme.documentBody.usingColorSpace(.sRGB),
                        let heading = AppTheme.documentHeading.usingColorSpace(.sRGB),
                        let system = NSColor.textColor.usingColorSpace(.sRGB)
                    else {
                        Issue.record("Cannot resolve document colors in sRGB")
                        return
                    }
                    let highContrast = AppTheme.resolvedDocumentColor(lightWhite: 0.2, appearance: appearance, increasedContrast: true)
                    #expect(highContrast == .textColor)
                    if name == .aqua {
                        #expect(abs(body.redComponent - 0.2) < 0.001)
                        #expect(abs(heading.redComponent - 36.0 / 255.0) < 0.001)
                    } else {
                        #expect(body == system)
                        #expect(heading == system)
                    }
                }
            }
        }
    #endif

}
