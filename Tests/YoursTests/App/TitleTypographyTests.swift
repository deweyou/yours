import CoreText
import SwiftUI
import Testing

@testable import Yours

@MainActor
struct TitleTypographyTests {
    @Test func bundledFontRegistersAndCoversChineseAndLatinWithoutFallback() throws {
        try #require(TitleTypography.isRegistered)
        let context = EnvironmentValues().fontResolutionContext
        let font = TitleTypography.document.resolve(in: context).ctFont
        #expect(CTFontCopyPostScriptName(font) as String == BundledSerifFont.heavyName)
        #expect(CTFontGetSize(font) == DocumentTypography.titleSize)
        let characters = Array("思源宋体，记录生活。Yours 2026!?".utf16)
        var glyphs = Array(repeating: CGGlyph(0), count: characters.count)
        for name in BundledSerifFont.allNames {
            let face = CTFontCreateWithName(name as CFString, 18, nil)
            #expect(CTFontCopyPostScriptName(face) as String == name)
            #expect(CTFontGetGlyphsForCharacters(face, characters, &glyphs, characters.count))
        }
        let license = try #require(
            TitleTypography.resourceBundle.url(forResource: "SourceHanSerif-LICENSE", withExtension: "txt", subdirectory: "Fonts"))
        #expect(try String(contentsOf: license, encoding: .utf8).contains("SIL OPEN FONT LICENSE"))
    }

    @Test(arguments: [DynamicTypeSize.small, .large, .xxxLarge, .accessibility3])
    func cardFontKeepsSemanticHeadlineSize(size: DynamicTypeSize) {
        var environment = EnvironmentValues()
        environment.dynamicTypeSize = size
        let context = environment.fontResolutionContext
        let font = TitleTypography.card(in: context).resolve(in: context).ctFont
        #expect(CTFontCopyPostScriptName(font) as String == BundledSerifFont.mediumName)
        #expect(CTFontGetSize(font) == CTFontGetSize(Font.headline.resolve(in: context).ctFont))
        #expect(CTFontCopyPostScriptName(Font.body.resolve(in: context).ctFont) as String != TitleTypography.postScriptName)
    }
}
