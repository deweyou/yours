import SwiftUI

/// Preferences are independent of note storage and isolated for each UI-test session.
@Observable @MainActor
final class AppPreferences {
    enum Theme: String, CaseIterable {
        case system, light, dark

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    enum Language: String, CaseIterable, Sendable {
        case chinese = "zh-Hans"
        case english = "en"

        var locale: Locale { Locale(identifier: rawValue) }
    }

    private let defaults: UserDefaults
    private var previousLanguage: Language?
    let activeLanguage: Language
    var iCloudSyncEnabled: Bool {
        didSet { defaults.set(iCloudSyncEnabled, forKey: "sync.icloud.enabled") }
    }
    var theme: Theme {
        didSet { defaults.set(theme.rawValue, forKey: "appearance.theme") }
    }
    var language: Language {
        didSet {
            defaults.set(language.rawValue, forKey: "appearance.language")
            // App-scoped only. Native system menus adopt this on the next launch.
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    init(defaults: UserDefaults = PreferenceStorage.defaults, activeLanguage: Language = L10n.language) {
        self.defaults = defaults
        iCloudSyncEnabled = defaults.bool(forKey: "sync.icloud.enabled")
        self.activeLanguage = activeLanguage
        theme = Theme(rawValue: defaults.string(forKey: "appearance.theme") ?? "") ?? .system
        language = Language(rawValue: defaults.string(forKey: "appearance.language") ?? "") ?? activeLanguage
    }

    func changeLanguage(to language: Language, save: () async -> Bool, restart: () throws -> Void) async throws {
        guard language != self.language else { return }
        guard await save() else { throw LibrarySyncError.localStorage }
        previousLanguage = self.language
        self.language = language
        defaults.synchronize()
        do {
            try restart()
        } catch {
            cancelPendingLanguageChange()
            throw error
        }
    }

    func cancelPendingLanguageChange() {
        guard let previousLanguage else { return }
        language = previousLanguage
        self.previousLanguage = nil
        defaults.synchronize()
    }
}

enum PreferenceStorage {
    static var defaults: UserDefaults {
        guard let suite = AppStorage.current.preferenceSuite else { return .standard }
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Cannot open isolated preferences.")
        }
        return defaults
    }
}

/// The active language is frozen for the process lifetime so changing it never rebuilds an editor.
enum L10n {
    static let language: AppPreferences.Language = {
        if let saved = PreferenceStorage.defaults.string(forKey: "appearance.language"),
            let language = AppPreferences.Language(rawValue: saved)
        {
            return language
        }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == false ? .english : .chinese
    }()

    static let resources: Bundle = {
        #if SWIFT_PACKAGE
            Bundle.module
        #else
            Bundle.main
        #endif
    }()

    static func bundle(for language: AppPreferences.Language) -> Bundle {
        // SwiftPM can normalize localization directory names to lowercase.
        // Resolve the actual entry instead of falling back to the host's preferred language.
        guard
            let localization = resources.localizations.first(where: {
                $0.caseInsensitiveCompare(language.rawValue) == .orderedSame
            }), let url = resources.resourceURL?.appendingPathComponent("\(localization).lproj"),
            let bundle = Bundle(url: url)
        else { return resources }
        return bundle
    }

    static func string(_ value: String.LocalizationValue, language: AppPreferences.Language = language) -> String {
        String(localized: value, bundle: bundle(for: language), locale: language.locale)
    }

    // Explicit keys stay stable; default values supply typed interpolation and missing-resource fallback.
    static func mixedFormat(_ title: String, language: AppPreferences.Language = language) -> String {
        String(localized: "format.mixed", defaultValue: "\(title)（混合）", bundle: bundle(for: language), locale: language.locale)
    }

    static func characterCount(_ count: Int, language: AppPreferences.Language = language) -> String {
        String(localized: "note.character_count", defaultValue: "\(count) 字符", bundle: bundle(for: language), locale: language.locale)
    }

    static func noteCount(_ count: Int, language: AppPreferences.Language = language) -> String {
        String(localized: "note.count", defaultValue: "\(count) 条记录", bundle: bundle(for: language), locale: language.locale)
    }

    static func originalPreserved(_ details: String, language: AppPreferences.Language = language) -> String {
        String(
            localized: "storage.original_preserved", defaultValue: "原文件已保留。\n\(details)", bundle: bundle(for: language),
            locale: language.locale)
    }

    static func markComplete(_ content: String, language: AppPreferences.Language = language) -> String {
        String(
            localized: "checklist.mark_complete", defaultValue: "将“\(content)”标记为已完成", bundle: bundle(for: language),
            locale: language.locale)
    }

    static func markIncomplete(_ content: String, language: AppPreferences.Language = language) -> String {
        String(
            localized: "checklist.mark_incomplete", defaultValue: "将“\(content)”标记为未完成", bundle: bundle(for: language),
            locale: language.locale)
    }

    static func unsaved(_ details: String, language: AppPreferences.Language = language) -> String {
        String(localized: "storage.unsaved", defaultValue: "尚未保存：\(details)", bundle: bundle(for: language), locale: language.locale)
    }

    static func searchNotes(_ title: String, language: AppPreferences.Language = language) -> String {
        String(localized: "note.search", defaultValue: "搜索\(title)", bundle: bundle(for: language), locale: language.locale)
    }

    static func saveFailed(_ details: String, language: AppPreferences.Language = language) -> String {
        String(
            localized: "storage.save_failed", defaultValue: "无法保存记录。内容仍保留在当前窗口，请重试。\n\(details)", bundle: bundle(for: language),
            locale: language.locale)
    }

    static func formatFailed(_ details: String, language: AppPreferences.Language = language) -> String {
        String(
            localized: "code.format.failed_details", defaultValue: "无法格式化，原文已保留。\n\(details)", bundle: bundle(for: language),
            locale: language.locale)
    }

    static func loadFailed(_ details: String, language: AppPreferences.Language = language) -> String {
        String(
            localized: "storage.load_failed.description", defaultValue: "无法读取记录，已暂停编辑以保护原始内容。请恢复文件后重新读取。\n\(details)",
            bundle: bundle(for: language), locale: language.locale)
    }

    static func heading(_ level: Int, language: AppPreferences.Language = language) -> String {
        String(localized: "format.heading", defaultValue: "标题 \(level)", bundle: bundle(for: language), locale: language.locale)
    }

    static func tableHeader(_ column: Int, language: AppPreferences.Language = language) -> String {
        String(
            localized: "table.header.accessibility_label", defaultValue: "第 \(column) 列表头", bundle: bundle(for: language),
            locale: language.locale)
    }

    static func tableCell(_ row: Int, _ column: Int, language: AppPreferences.Language = language) -> String {
        String(
            localized: "table.cell.accessibility_label", defaultValue: "第 \(row) 行第 \(column) 列", bundle: bundle(for: language),
            locale: language.locale)
    }
}
