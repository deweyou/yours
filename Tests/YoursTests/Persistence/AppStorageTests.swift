import Foundation
import Testing

@testable import Yours

@MainActor
struct AppStorageTests {
    @Test func buildsAndTestSessionsUseIndependentDurableLibraries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let production = try AppStorage.resolve(isDebug: false, environment: ["YOURS_UI_TEST_SESSION": id.uuidString], root: root)
        let development = try AppStorage.resolve(isDebug: true, environment: [:], root: root)
        let test = try AppStorage.resolve(isDebug: true, environment: ["YOURS_UI_TEST_SESSION": id.uuidString], root: root)
        #expect(Set([production.directory, development.directory, test.directory]).count == 3)
        #expect(production.profile == .production)
        #expect(test.profile == .test(id))
        #expect(production.preferenceSuite == nil)
        #expect(development.preferenceSuite != test.preferenceSuite)
        for storage in [production, development, test] {
            let store = NoteStore(directory: storage.directory)
            store.createNote(title: storage.directory.lastPathComponent)
            await store.flushPendingSave()
            #expect(NoteStore(directory: storage.directory).notes == store.notes)
            #expect(store.notes.count == 1)
        }
        #expect(try AppStorage.resolve(isDebug: true, environment: [:], root: root) == development)
        #expect(throws: AppStorage.ConfigurationError.self) {
            try AppStorage.resolve(isDebug: true, environment: ["YOURS_UI_TEST_SESSION": "invalid"], root: root)
        }
    }

    @Test func restartArgumentsPreserveTestIsolationAndFailClosed() throws {
        let id = UUID().uuidString
        let arguments = ["Yours", "-YoursUITestSession", id]
        let storage = try AppStorage.resolve(isDebug: true, environment: [:], arguments: arguments)
        #expect(storage.profile == .test(try #require(UUID(uuidString: id))))
        #expect(!storage.allowsCloudSync)
        #expect(try AppStorage.resolve(isDebug: false, environment: [:], arguments: arguments).profile == .production)
        for invalid in [["-YoursUITestSession"], ["-YoursUITestSession", "invalid"]] {
            #expect(throws: AppStorage.ConfigurationError.self) {
                try AppStorage.resolve(isDebug: true, environment: [:], arguments: invalid)
            }
        }
        #expect(throws: AppStorage.ConfigurationError.self) {
            try AppStorage.resolve(isDebug: true, environment: ["YOURS_UI_TEST_SESSION": UUID().uuidString], arguments: arguments)
        }
    }

    @Test func syncPreferenceDefaultsOffAndSurvivesRestart() throws {
        let suite = "AppStorageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        #expect(!preferences.iCloudSyncEnabled)
        preferences.iCloudSyncEnabled = true
        #expect(AppPreferences(defaults: defaults).iCloudSyncEnabled)
    }
}
