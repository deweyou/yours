import CloudKit
import Foundation
import Observation

#if os(macOS)
    import Security
#endif

enum LibrarySyncError: LocalizedError {
    case notConfigured, accountUnavailable, accountChanged, invalidLibrary, localStorage, conflict, editorOpen, todoConflict

    var errorDescription: String? {
        switch self {
        case .notConfigured: L10n.string("sync.not_configured")
        case .accountUnavailable: L10n.string("sync.account_unavailable")
        case .accountChanged: L10n.string("sync.account_changed")
        case .invalidLibrary: L10n.string("sync.invalid_library")
        case .localStorage: L10n.string("sync.local_storage")
        case .conflict: L10n.string("sync.conflict_retry")
        case .editorOpen: L10n.string("sync.editor_open")
        case .todoConflict: L10n.string("todo.sync.conflict")
        }
    }
}

@MainActor
protocol CloudLibraryTransport {
    func accountIdentifier() async throws -> String
    func fetch() async throws -> NoteLibrary
    func upload(_ library: NoteLibrary) async throws
}

/// CloudKit stores an asset in the user's private database. Conditional writes prevent whole-library overwrite.
@MainActor
final class CloudKitLibraryTransport: CloudLibraryTransport {
    private let container: CKContainer
    private let recordID = CKRecord.ID(recordName: "library-v1")
    private var fetchedRecord: CKRecord?
    private var account: String?

    init(containerIdentifier: String) {
        container = CKContainer(identifier: containerIdentifier)
    }

    static func configuredContainer(storage: AppStorage, bundle: Bundle = .main) -> String? {
        guard storage.allowsCloudSync,
            let identifier = bundle.object(forInfoDictionaryKey: "YoursCloudContainerIdentifier") as? String,
            identifier == "iCloud.app.yours.editor\(storage.cloudContainerSuffix)"
        else { return nil }
        #if SWIFT_PACKAGE
            return nil
        #elseif os(macOS)
            // Ad-hoc previews cannot use CloudKit even if they carry a container in Info.plist.
            guard let task = SecTaskCreateFromSelf(nil),
                let containers = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil)
                    as? [String],
                containers.contains(identifier),
                let environment = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-environment" as CFString, nil)
                    as? String,
                environment == (storage.profile == .production ? "Production" : "Development")
            else { return nil }
            return identifier
        #else
            return identifier
        #endif
    }

    func accountIdentifier() async throws -> String {
        guard try await container.accountStatus() == .available else { throw LibrarySyncError.accountUnavailable }
        let identifier = try await container.userRecordID().recordName
        account = identifier
        return identifier
    }

    private func checkAccount() async throws {
        let current = try await container.userRecordID().recordName
        guard account == current else { throw LibrarySyncError.accountChanged }
        try Task.checkCancellation()
    }

    func fetch() async throws -> NoteLibrary {
        try await checkAccount()
        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else { throw LibrarySyncError.invalidLibrary }
            let library = try JSONDecoder().decode(NoteLibrary.self, from: Data(contentsOf: url))
            try library.validate()
            try await checkAccount()
            fetchedRecord = record
            return library
        } catch let error as CKError where error.code == .unknownItem {
            fetchedRecord = nil
            return NoteLibrary()
        }
    }

    func upload(_ library: NoteLibrary) async throws {
        try await checkAccount()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("library.json")
        try JSONEncoder().encode(library).write(to: url, options: .atomic)
        let record = fetchedRecord ?? CKRecord(recordType: "YoursLibrary", recordID: recordID)
        record["payload"] = CKAsset(fileURL: url)
        do {
            let result = try await container.privateCloudDatabase.modifyRecords(
                saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
            guard let saved = result.saveResults[recordID] else { throw LibrarySyncError.invalidLibrary }
            fetchedRecord = try saved.get()
            try await checkAccount()
        } catch let error as CKError where error.code == .serverRecordChanged {
            throw LibrarySyncError.conflict
        }
    }
}

@MainActor @Observable
final class CloudLibrarySync {
    private struct Checkpoint: Codable {
        var account: String
        var base: NoteLibrary?
        var lastSync: Date?
    }

    private let store: NoteStore
    private let preferences: AppPreferences
    private let storage: AppStorage
    private let transport: (any CloudLibraryTransport)?
    private var generation = 0
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var errorMessage: String?

    var isAvailable: Bool { transport != nil && storage.allowsCloudSync }
    private var checkpointURL: URL { storage.directory.appendingPathComponent("cloud-sync.json") }

    init(store: NoteStore, preferences: AppPreferences, storage: AppStorage, transport: (any CloudLibraryTransport)? = nil) {
        self.store = store
        self.preferences = preferences
        self.storage = storage
        if let transport {
            self.transport = transport
        } else if let identifier = CloudKitLibraryTransport.configuredContainer(storage: storage) {
            self.transport = CloudKitLibraryTransport(containerIdentifier: identifier)
        } else {
            self.transport = nil
        }
        // A malformed checkpoint is reported by synchronize; it must never reset account ownership.
        if let encoded = try? Data(contentsOf: checkpointURL), let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: encoded) {
            lastSync = checkpoint.lastSync
        }
        #if DEBUG
            // Exercise the native loading layout in an isolated UI-test library;
            // AppStorage still forbids any CloudKit connection for this profile.
            if case .test = storage.profile,
                ProcessInfo.processInfo.environment["YOURS_UI_TEST_SYNC_LOADING"] == "1"
            {
                preferences.iCloudSyncEnabled = true
                isSyncing = true
            }
        #endif
    }

    func stop() {
        generation &+= 1
        errorMessage = nil
    }

    private func checkSession(_ expected: Int) throws {
        try Task.checkCancellation()
        guard generation == expected, preferences.iCloudSyncEnabled else { throw CancellationError() }
    }

    func synchronize() async {
        guard preferences.iCloudSyncEnabled, !isSyncing else { return }
        guard isAvailable, let transport else {
            errorMessage = LibrarySyncError.notConfigured.localizedDescription
            return
        }
        let session = generation
        isSyncing = true
        errorMessage = nil
        defer { isSyncing = false }
        do {
            let account = try await transport.accountIdentifier()
            try checkSession(session)
            var checkpoint: Checkpoint
            do {
                checkpoint = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: checkpointURL))
            } catch CocoaError.fileReadNoSuchFile {
                checkpoint = Checkpoint(account: account)
            }
            guard checkpoint.account == account else { throw LibrarySyncError.accountChanged }
            try saveCheckpoint(checkpoint)
            let remote = try await transport.fetch()
            try checkSession(session)
            try store.mergeCloudLibrary(remote, base: checkpoint.base)
            await store.flushPendingSave()
            try checkSession(session)
            guard store.loadError == nil, store.saveError == nil, !store.hasUnsavedChanges else { throw LibrarySyncError.localStorage }
            let snapshot = store.library
            if !snapshot.hasSameContent(as: remote) {
                try await transport.upload(snapshot)
                try checkSession(session)
            }
            checkpoint.base = snapshot
            checkpoint.lastSync = Date()
            try saveCheckpoint(checkpoint)
            lastSync = checkpoint.lastSync
        } catch is CancellationError {
            // Disabling sync or leaving the active scene invalidates the response.
        } catch {
            guard generation == session, preferences.iCloudSyncEnabled, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func saveCheckpoint(_ checkpoint: Checkpoint) throws {
        try FileManager.default.createDirectory(at: storage.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)
    }
}
