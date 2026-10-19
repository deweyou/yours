import CoreText
import SwiftUI
import Testing

@testable import Yours

@MainActor
struct PortableFontTests {
    private struct LegacyRichText: Encodable {
        var text: AttributedString
        func encode(to encoder: any Encoder) throws {
            try text.encode(to: encoder, configuration: AttributeScopes.SwiftUIAttributes.encodingConfiguration)
        }
    }

    @Test(arguments: ["SourceHanSerifCN-Light", "SourceHanSerifCN-Bold", "Georgia-Italic"])
    func platformFontSurvivesRepeatedSavesWithoutEmbeddingFontFile(name: String) throws {
        try #require(BundledSerifFont.isRegistered)
        var note = Note(id: UUID(), text: "中文 English", createdAt: .distantPast, updatedAt: .distantPast)
        note.richText.font = Font(CTFontCreateWithName(name as CFString, 19, nil))
        note.richText.foregroundColor = .red
        note.richText.underlineStyle = .single
        note.richText[InlineEmphasisAttribute.self] = 2
        for _ in 0..<3 {
            let encoded = try JSONEncoder().encode(note)
            #expect(encoded.count < 2_048)
            #expect(!String(decoding: encoded, as: UTF8.self).contains("\"platform\""))
            note = try JSONDecoder().decode(Note.self, from: encoded)
            let font = try #require(note.richText.font).resolve(in: EnvironmentValues().fontResolutionContext).ctFont
            #expect(CTFontCopyPostScriptName(font) as String == name)
            #expect(CTFontGetSize(font) == 19)
            #expect(note.text == "中文 English")
            #expect(note.richText.foregroundColor == .red)
            #expect(note.richText.underlineStyle == .single)
            #expect(note.richText[InlineEmphasisAttribute.self] == 2)
        }
    }

    @Test func legacyEmbeddedFontMigratesWithoutLosingTextOrFontIdentity() throws {
        try #require(BundledSerifFont.isRegistered)
        var note = Note(id: UUID(), text: "旧格式中文", createdAt: .distantPast, updatedAt: .distantPast)
        note.richText.font = Font(CTFontCreateWithName("SourceHanSerifCN-Light" as CFString, 14, nil))
        let legacy = try JSONEncoder().encode(LegacyRichText(text: note.richText))
        var envelope = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(note)) as? [String: Any])
        envelope["richText"] = try JSONSerialization.jsonObject(with: legacy)
        let migrated = try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: envelope))
        let encoded = try JSONEncoder().encode(migrated)
        #expect(encoded.count < 2_048)
        let restored = try JSONDecoder().decode(Note.self, from: encoded)
        #expect(restored.text == note.text)
        let font = try #require(restored.richText.font).resolve(in: EnvironmentValues().fontResolutionContext).ctFont
        #expect(CTFontCopyPostScriptName(font) as String == "SourceHanSerifCN-Light")
        #expect(CTFontGetSize(font) == 14)
    }
    @Test func equivalentPlatformAndNamedFontsDoNotCreateConflictCopies() throws {
        try #require(BundledSerifFont.isRegistered)
        var local = Note(id: UUID(), text: "Same document", createdAt: .distantPast, updatedAt: .distantPast)
        local.richText.font = .custom("SourceHanSerifCN-Light", fixedSize: 14)
        var remote = local
        remote.richText.font = Font(CTFontCreateWithName("SourceHanSerifCN-Light" as CFString, 14, nil))
        #expect(NoteLibrary(notes: [local]).hasSameContent(as: NoteLibrary(notes: [remote])))
        let merged = try NoteLibrary(notes: [local]).merging(NoteLibrary(notes: [remote]), base: nil)
        #expect(merged.notes.count == 1)
        remote.richText.font = .custom("SourceHanSerifCN-Bold", fixedSize: 14)
        #expect(!NoteLibrary(notes: [local]).hasSameContent(as: NoteLibrary(notes: [remote])))
        let conflict = try NoteLibrary(notes: [local]).merging(NoteLibrary(notes: [remote]), base: nil)
        #expect(conflict.notes.count == 2)
        let restored = try JSONDecoder().decode(NoteLibrary.self, from: JSONEncoder().encode(conflict))
        let retried = try restored.merging(NoteLibrary(notes: [remote]), base: nil)
        #expect(retried.notes.count == 2)
        #expect(Set(retried.notes.map(\.id)) == Set(conflict.notes.map(\.id)))
    }

}
