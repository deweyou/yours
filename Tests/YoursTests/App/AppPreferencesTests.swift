import Foundation
import Testing

@testable import Yours

@MainActor
struct AppPreferencesTests {
    @Test func restoresChoicesWithoutChangingActiveLanguage() throws {
        let suite = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults, activeLanguage: .chinese)
        #expect(preferences.theme == .system)
        #expect(preferences.language == .chinese)

        preferences.theme = .dark
        preferences.language = .english
        #expect(preferences.activeLanguage == .chinese)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])

        let restored = AppPreferences(defaults: defaults, activeLanguage: .english)
        #expect(restored.theme == .dark)
        #expect(restored.language == .english)
        #expect(restored.activeLanguage == .english)
        restored.theme = .system
        #expect(AppPreferences(defaults: defaults, activeLanguage: .english).theme.colorScheme == nil)
    }

    @Test func languageChangeSavesBeforeRestartAndRollsBackOnFailure() async throws {
        let suite = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults, activeLanguage: .chinese)
        var saved = false
        var restarted = false
        try await preferences.changeLanguage(
            to: .english,
            save: {
                saved = true
                return true
            },
            restart: {
                #expect(saved)
                #expect(preferences.language == .english)
                restarted = true
            })
        #expect(restarted)
        #expect(preferences.activeLanguage == .chinese)
        preferences.cancelPendingLanguageChange()
        #expect(preferences.language == .chinese)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])

        await #expect(throws: (any Error).self) {
            try await preferences.changeLanguage(
                to: .english, save: { false },
                restart: {
                    Issue.record("Must not restart when saving fails")
                })
        }
        #expect(preferences.language == .chinese)
        await #expect(throws: (any Error).self) {
            try await preferences.changeLanguage(
                to: .english, save: { true },
                restart: {
                    throw CocoaError(.executableNotLoadable)
                })
        }
        #expect(preferences.language == .chinese)
    }

    @Test func invalidPreferencesFallBackWithoutTouchingOtherDefaults() throws {
        let suite = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid", forKey: "appearance.theme")
        defaults.set("invalid", forKey: "appearance.language")
        defaults.set("keep", forKey: "unrelated")
        let preferences = AppPreferences(defaults: defaults, activeLanguage: .english)
        #expect(preferences.theme == .system)
        #expect(preferences.language == .english)
        preferences.language = .chinese
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
        #expect(defaults.string(forKey: "unrelated") == "keep")
    }

    @Test(arguments: AppPreferences.Language.allCases)
    func bundledTranslationsAndInterpolation(language: AppPreferences.Language) {
        #expect(L10n.bundle(for: language).bundleURL.lastPathComponent.lowercased() == "\(language.rawValue.lowercased()).lproj")
        #expect(L10n.string("settings.title", language: language) == (language == .chinese ? "设置" : "Settings"))
        let column = 3
        #expect(
            L10n.tableHeader(column, language: language)
                == (language == .chinese ? "第 3 列表头" : "Column 3 Header"))
        let content = "中文 👋 title"
        #expect(
            L10n.markComplete(content, language: language)
                == (language == .chinese ? "将“中文 👋 title”标记为已完成" : "Mark “中文 👋 title” as Complete"))
    }

    @Test(arguments: AppPreferences.Language.allCases)
    func semanticMessagesPreserveArguments(language: AppPreferences.Language) {
        let content = "中文 👋 100%\nsettings.title"
        let chinese = language == .chinese
        #expect(L10n.mixedFormat(content, language: language) == content + (chinese ? "（混合）" : " (Mixed)"))
        #expect(L10n.searchNotes(content, language: language) == (chinese ? "搜索" : "Search ") + content)
        #expect(L10n.unsaved(content, language: language) == (chinese ? "尚未保存：" : "Not saved: ") + content)
        #expect(
            L10n.originalPreserved(content, language: language)
                == (chinese ? "原文件已保留。\n" : "The original file has been preserved.\n") + content)
        #expect(
            L10n.markIncomplete(content, language: language)
                == (chinese ? "将“\(content)”标记为未完成" : "Mark “\(content)” as Incomplete"))
        #expect(L10n.heading(6, language: language) == (chinese ? "标题 6" : "Heading 6"))
        #expect(L10n.tableCell(2, 3, language: language) == (chinese ? "第 2 行第 3 列" : "Row 2, Column 3"))
        #expect(
            L10n.saveFailed(content, language: language)
                == (chinese
                    ? "无法保存记录。内容仍保留在当前窗口，请重试。\n"
                    : "Unable to save notes. Your content is still in this window. Please try again.\n") + content)
        #expect(
            L10n.loadFailed(content, language: language)
                == (chinese
                    ? "无法读取记录，已暂停编辑以保护原始内容。请恢复文件后重新读取。\n"
                    : "Unable to load notes. Editing is paused to protect your content. Restore the file, then reload.\n") + content)
        #expect(
            L10n.formatFailed(content, language: language)
                == (chinese ? "无法格式化，原文已保留。\n" : "Unable to format. Your original code has been preserved.\n") + content)
    }

    @Test(arguments: [0, 1, 2])
    func localizedCountsUseCorrectPlural(count: Int) {
        #expect(L10n.noteCount(count, language: .english) == "\(count) " + (count == 1 ? "note" : "notes"))
        #expect(L10n.noteCount(count, language: .chinese) == "\(count) 条记录")
        #expect(L10n.characterCount(count, language: .chinese) == "\(count) 字符")
        #expect(L10n.characterCount(count, language: .english) == "\(count) " + (count == 1 ? "character" : "characters"))
    }

    @Test func translationCatalogsHaveMatchingKeysAndFormatArguments() throws {
        func catalog(_ language: AppPreferences.Language) throws -> [String: String] {
            let url = try #require(L10n.bundle(for: language).url(forResource: "Localizable", withExtension: "strings"))
            let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            return try #require(value as? [String: String])
        }
        let chinese = try catalog(.chinese)
        let english = try catalog(.english)
        #expect(chinese.count > 150)
        #expect(Set(chinese.keys) == Set(english.keys))
        let placeholders = /%(?:\d+\$)?(?:lld|@)/
        for (key, value) in chinese {
            #expect(key.wholeMatch(of: /[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+/) != nil, "Nonsemantic key: \(key)")
            let translation = try #require(english[key])
            #expect(
                value.matches(of: placeholders).map { String($0.output) }
                    == translation.matches(of: placeholders).map { String($0.output) },
                "Mismatched placeholders for \(key)")
            #expect(!translation.isEmpty)
        }
    }
}
