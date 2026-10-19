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

    @Test func relaunchTokenIsOneShotAndBoundToTheAppBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = UUID()
        let app = root.appendingPathComponent("Yours.app")
        let storage = AppStorage(profile: .test(session), root: root)
        let now = Date()
        try storage.prepareTestRelaunch(bundleURL: app, now: now)
        #expect(try AppStorage.consumeTestRelaunch(root: root, bundleURL: root.appendingPathComponent("Other.app"), now: now) == nil)
        let restored = try #require(try AppStorage.consumeTestRelaunch(root: root, bundleURL: app, now: now))
        let reopened = try AppStorage.resolve(isDebug: true, environment: ["YOURS_UI_TEST_SESSION": restored.uuidString], root: root)
        #expect(reopened == storage)
        #expect(!reopened.allowsCloudSync)
        #expect(try AppStorage.consumeTestRelaunch(root: root, bundleURL: app, now: now) == nil)
    }

    @Test func expiredCancelledAndNonTestRelaunchesCannotSelectAnotherLibrary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Yours.app")
        let now = Date()
        let test = AppStorage(profile: .test(UUID()), root: root)
        try test.prepareTestRelaunch(bundleURL: app, now: now)
        #expect(try AppStorage.consumeTestRelaunch(root: root, bundleURL: app, now: now.addingTimeInterval(61)) == nil)
        try test.prepareTestRelaunch(bundleURL: app)
        try test.cancelTestRelaunch(bundleURL: app)
        #expect(try AppStorage.consumeTestRelaunch(root: root, bundleURL: app) == nil)
        for profile in [AppStorage.Profile.development, .production] {
            try AppStorage(profile: profile, root: root).prepareTestRelaunch(bundleURL: app)
            #expect(try AppStorage.consumeTestRelaunch(root: root, bundleURL: app) == nil)
        }
        let token = root.appendingPathComponent("YoursUITests/language-relaunch.json")
        try Data("invalid".utf8).write(to: token)
        #expect(throws: DecodingError.self) { try AppStorage.consumeTestRelaunch(root: root, bundleURL: app) }
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
