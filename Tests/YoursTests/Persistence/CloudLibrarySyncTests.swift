import Foundation
import Testing

@testable import Yours

@MainActor
struct CloudLibrarySyncTests {
    private func makeNote(_ body: String, id: UUID = UUID()) -> Note {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return Note(id: id, text: body, createdAt: date, updatedAt: date, title: "中文 👋")
    }

    @Test func independentEditsAndConflictsPreserveDocumentsAcrossRetries() throws {
        let first = makeNote("initial")
        let second = makeNote("second")
        let base = NoteLibrary(notes: [first, second])
        var local = first
        local.text = "本机修改"
        var remote = second
        remote.text = "另一台设备"
        let merged = try NoteLibrary(notes: [local, second]).merging(NoteLibrary(notes: [first, remote]), base: base)
        #expect(merged.notes.count == 2)
        #expect(Set(merged.notes.map(\.text)) == ["本机修改", "另一台设备"])
        remote = first
        remote.text = "并发修改"
        let cloud = NoteLibrary(notes: [remote, second])
        let conflict = try NoteLibrary(notes: [local, second]).merging(cloud, base: base)
        #expect(conflict.notes.count == 3)
        #expect(Set(conflict.notes.map(\.text)) == ["本机修改", "并发修改", "second"])
        #expect(try conflict.merging(cloud, base: base) == conflict)
    }

    @Test func malformedRemoteCannotReplaceLocalDocuments() throws {
        let note = makeNote("keep")
        let local = NoteLibrary(notes: [note])
        #expect(throws: (any Error).self) { try local.merging(NoteLibrary(notes: [note, note]), base: nil) }
        #expect(throws: (any Error).self) { try local.merging(local, base: NoteLibrary(notes: [note, note])) }
        var orphan = note
        orphan.folderID = UUID()
        #expect(throws: (any Error).self) { try local.merging(NoteLibrary(notes: [orphan]), base: nil) }
    }

    @Test func remoteChangesWaitForEveryOpenEditorWithoutBlockingLocalUploads() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.preferences.iCloudSyncEnabled = true
        fixture.store.createNote(title: "open document")
        let original = try #require(fixture.store.notes.first)
        let firstWindow = UUID()
        let secondWindow = UUID()
        fixture.store.registerEditor(firstWindow, noteID: original.id)
        fixture.store.registerEditor(secondWindow, noteID: original.id)
        await fixture.sync.synchronize()
        #expect(fixture.sync.errorMessage == nil)
        var incoming = original
        incoming.text = "remote edit"
        fixture.transport.remote = NoteLibrary(notes: [incoming])
        await fixture.sync.synchronize()
        #expect(fixture.sync.errorMessage == LibrarySyncError.editorOpen.localizedDescription)
        #expect(fixture.store.notes == [original])
        fixture.store.unregisterEditor(firstWindow)
        await fixture.sync.synchronize()
        #expect(fixture.store.notes == [original])
        fixture.store.unregisterEditor(secondWindow)
        await fixture.sync.synchronize()
        #expect(fixture.sync.errorMessage == nil)
        #expect(fixture.store.notes == [incoming])
    }

    @Test func syncSavesLocallyBeforeUploadAndRestoresCheckpoint() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.preferences.iCloudSyncEnabled = true
        fixture.store.createNote(title: "local")
        let remote = makeNote("cloud")
        fixture.transport.remote = NoteLibrary(notes: [remote])
        fixture.transport.beforeUpload = { library in
            #expect(NoteStore(directory: fixture.storage.directory).library == library)
        }
        await fixture.sync.synchronize()
        #expect(fixture.sync.errorMessage == nil)
        #expect(fixture.store.notes.count == 2)
        #expect(fixture.transport.remote == fixture.store.library)
        #expect(fixture.sync.lastSync != nil)
        let restarted = CloudLibrarySync(
            store: fixture.store, preferences: fixture.preferences,
            storage: fixture.storage, transport: fixture.transport)
        #expect(restarted.lastSync == fixture.sync.lastSync)
        fixture.preferences.iCloudSyncEnabled = false
        fixture.sync.stop()
        await fixture.sync.synchronize()
        #expect(fixture.store.notes.count == 2)
        #expect(fixture.transport.remote.notes.count == 2)
        #expect(fixture.transport.uploads == 1)
    }

    @Test func disablingWhileFetchingDiscardsLateResponse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.preferences.iCloudSyncEnabled = true
        fixture.transport.remote = NoteLibrary(notes: [makeNote("cloud")])
        fixture.transport.beforeFetchReturns = {
            fixture.preferences.iCloudSyncEnabled = false
            fixture.sync.stop()
        }
        await fixture.sync.synchronize()
        #expect(fixture.store.notes.isEmpty)
        #expect(fixture.transport.uploads == 0)
        #expect(fixture.sync.lastSync == nil)
    }

    @Test func accountChangeAndCorruptCheckpointPreventCrossAccountUpload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.preferences.iCloudSyncEnabled = true
        fixture.store.createNote(title: "private")
        await fixture.sync.synchronize()
        fixture.transport.account = "different-account"
        await fixture.sync.synchronize()
        #expect(fixture.sync.errorMessage == LibrarySyncError.accountChanged.localizedDescription)
        #expect(fixture.transport.uploads == 1)
        #expect(fixture.store.notes.count == 1)
        let checkpoint = fixture.storage.directory.appendingPathComponent("cloud-sync.json")
        try Data("invalid".utf8).write(to: checkpoint)
        await fixture.sync.synchronize()
        #expect(fixture.sync.errorMessage != nil)
        #expect(fixture.transport.uploads == 1)
        #expect(try String(contentsOf: checkpoint, encoding: .utf8) == "invalid")
    }

    @Test func editsDuringFetchAreIncludedAndFailedUploadRetriesWithoutLoss() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.preferences.iCloudSyncEnabled = true
        fixture.store.createNote(title: "original")
        let id = try #require(fixture.store.selectedID)
        fixture.transport.beforeFetchReturns = { fixture.store.updateText(id: id, text: "edited during fetch") }
        fixture.transport.rejectUpload = true
        await fixture.sync.synchronize()
        #expect(fixture.sync.lastSync == nil)
        #expect(fixture.sync.errorMessage != nil)
        #expect(NoteStore(directory: fixture.storage.directory).notes.first?.text == "edited during fetch")
        fixture.transport.rejectUpload = false
        await fixture.sync.synchronize()
        #expect(fixture.sync.errorMessage == nil)
        #expect(fixture.transport.remote.notes.first?.text == "edited during fetch")
    }

    @Test func testProfileCannotContactCloudEvenWithSavedOptIn() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.preferences.iCloudSyncEnabled = true
        let isolated = AppStorage(profile: .test(UUID()), root: fixture.storage.root)
        let sync = CloudLibrarySync(store: fixture.store, preferences: fixture.preferences, storage: isolated, transport: fixture.transport)
        await sync.synchronize()
        #expect(!sync.isAvailable)
        #expect(fixture.transport.accountRequests == 0)
    }

    @MainActor
    private struct Fixture {
        let storage: AppStorage
        let preferences: AppPreferences
        let store: NoteStore
        let transport: MemoryCloudTransport
        let sync: CloudLibrarySync
        let suite = "CloudLibrarySyncTests.\(UUID().uuidString)"

        init() throws {
            storage = AppStorage(
                profile: .development, root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            let defaults = try #require(UserDefaults(suiteName: suite))
            preferences = AppPreferences(defaults: defaults)
            store = NoteStore(directory: storage.directory)
            transport = MemoryCloudTransport()
            sync = CloudLibrarySync(store: store, preferences: preferences, storage: storage, transport: transport)
        }

        func remove() {
            try? FileManager.default.removeItem(at: storage.root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }
}

@MainActor
private final class MemoryCloudTransport: CloudLibraryTransport {
    var remote = NoteLibrary()
    var account = "original-account"
    var accountRequests = 0
    var uploads = 0
    var rejectUpload = false
    var beforeFetchReturns: (() -> Void)?
    var beforeUpload: ((NoteLibrary) -> Void)?

    func accountIdentifier() async throws -> String {
        accountRequests += 1
        return account
    }

    func fetch() async throws -> NoteLibrary {
        beforeFetchReturns?()
        return remote
    }

    func upload(_ library: NoteLibrary) async throws {
        if rejectUpload { throw LibrarySyncError.conflict }
        beforeUpload?(library)
        uploads += 1
        remote = library
    }
}
