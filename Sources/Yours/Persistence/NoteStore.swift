import Foundation
import Observation
import SwiftUI
import UserNotifications

private actor NotePersistenceWriter {
    private let directory: URL
    private var writtenRevision = 0

    init(directory: URL) {
        self.directory = directory
    }

    func write(_ library: NoteLibrary, revision: Int) throws {
        guard revision > writtenRevision else { return }
        let encodedNotes = try JSONEncoder().encode(library)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encodedNotes.write(to: directory.appendingPathComponent("notes.json"), options: .atomic)
        writtenRevision = revision
    }
}

@MainActor
@Observable
final class NoteStore {
    private(set) var notes: [Note] = []
    private(set) var folders: [NoteFolder] = []
    private(set) var todos = TodoLibrary()
    var selectedID: UUID?
    var openTodoID: UUID?
    var todoReviewID: UUID?
    var todoFilter = "all"
    var todoNotice: String?
    var todoReminderError: String?
    private(set) var loadError: String?
    private(set) var saveError: String?
    private(set) var hasUnsavedChanges = false

    private let directory: URL
    private let writer: NotePersistenceWriter
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveRevision = 0
    @ObservationIgnored private var editorSessions: [UUID: UUID] = [:]
    private var notesURL: URL { directory.appendingPathComponent("notes.json") }

    init(directory: URL? = nil) {
        let directory = directory ?? AppStorage.current.directory
        self.directory = directory
        writer = NotePersistenceWriter(directory: directory)
        reload()
    }

    func createNote(title: String = "", richText: AttributedString = AttributedString(), folderID: UUID? = nil) {
        guard loadError == nil, isValidFolder(folderID) else { return }
        let now = Date()
        var note = Note(id: UUID(), text: "", createdAt: now, updatedAt: now, title: title, folderID: folderID)
        note.richText = richText
        notes.insert(note, at: 0)
        selectedID = note.id
        hasUnsavedChanges = true
        scheduleSave()
    }

    @discardableResult
    func createFolder(name: String) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loadError == nil, !name.isEmpty else { return nil }
        let folder = NoteFolder(id: UUID(), name: name)
        folders.append(folder)
        hasUnsavedChanges = true
        scheduleSave()
        return folder.id
    }

    func renameFolder(id: UUID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard loadError == nil, !name.isEmpty,
            let index = folders.firstIndex(where: { $0.id == id }), folders[index].name != name
        else { return }
        folders[index].name = name
        hasUnsavedChanges = true
        scheduleSave()
    }

    func moveNote(id: UUID, to folderID: UUID?) {
        guard loadError == nil, isValidFolder(folderID),
            let index = notes.firstIndex(where: { $0.id == id }), notes[index].folderID != folderID
        else { return }
        notes[index].folderID = folderID
        hasUnsavedChanges = true
        scheduleSave()
    }

    private func isValidFolder(_ id: UUID?) -> Bool {
        id == nil || folders.contains(where: { $0.id == id })
    }

    func updateTitle(id: UUID, title: String) {
        let normalizedTitle = title.trimmingCharacters(in: .newlines)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        guard loadError == nil,
            let index = notes.firstIndex(where: { $0.id == id }),
            notes[index].title != normalizedTitle
        else { return }
        notes[index].title = normalizedTitle
        notes[index].updatedAt = Date()
        hasUnsavedChanges = true
        scheduleSave()
    }

    func updateText(id: UUID, text: String) {
        updateRichText(id: id, text: AttributedString(text))
    }

    func updateRichText(id: UUID, text: AttributedString) {
        guard loadError == nil,
            let index = notes.firstIndex(where: { $0.id == id }),
            notes[index].richText != text
        else { return }
        notes[index].richText = text
        notes[index].updatedAt = Date()
        hasUnsavedChanges = true
        scheduleSave()
    }

    func applyRichEdit(id: UUID, text: AttributedString, undoManager: UndoManager?) {
        guard loadError == nil,
            let previous = notes.first(where: { $0.id == id })?.richText,
            previous != text
        else { return }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] store in
            // UndoManager invokes this target callback synchronously on the
            // main thread where the MainActor-isolated store was registered.
            MainActor.assumeIsolated {
                store.applyRichEdit(id: id, text: previous, undoManager: undoManager)
            }
        }
        updateRichText(id: id, text: text)
    }

    var library: NoteLibrary { NoteLibrary(folders: folders, notes: notes, todos: todos) }

    func registerEditor(_ session: UUID, noteID: UUID) {
        editorSessions[session] = noteID
    }

    func unregisterEditor(_ session: UUID) {
        editorSessions.removeValue(forKey: session)
    }

    func mergeCloudLibrary(_ remote: NoteLibrary, base: NoteLibrary?) throws {
        guard loadError == nil else { throw LibrarySyncError.localStorage }
        try remote.validate()
        // Native input composition and undo belong to the open editor. Apply incoming edits after it closes.
        let openIDs = Set(editorSessions.values)
        for incoming in remote.notes where openIDs.contains(incoming.id) {
            let local = notes.first { $0.id == incoming.id }
            let previous = base?.notes.first { $0.id == incoming.id }
            if incoming != local && incoming != previous { throw LibrarySyncError.editorOpen }
        }
        for incoming in remote.todos.items where openIDs.contains(incoming.id) {
            if incoming != todos.item(incoming.id) && incoming != base?.todos.item(incoming.id) {
                throw LibrarySyncError.editorOpen
            }
        }
        let merged = try library.merging(remote, base: base)
        guard merged != library else { return }
        folders = merged.folders
        notes = merged.notes
        todos = merged.todos
        hasUnsavedChanges = true
        scheduleSave()
    }

    @discardableResult
    func createTodo(title: String? = nil, openDetails: Bool = true, undoManager: UndoManager? = nil, now: Date = .now) -> UUID? {
        guard loadError == nil else { return nil }
        var next = todos
        let project = UUID(uuidString: todoFilter)
        guard let id = next.create(title: title ?? L10n.string("todo.untitled"), projectID: project, now: now) else { return nil }
        if todoFilter == "today" { next.update(id, now: now) { $0.plannedDate = now } }
        updateTodos(next, undoManager: undoManager)
        if ["trash", "completed"].contains(todoFilter) { todoFilter = "inbox" }
        if openDetails { openTodoID = id }
        return id
    }

    func updateTodos(_ next: TodoLibrary, undoManager: UndoManager? = nil) {
        guard loadError == nil, next != todos else { return }
        do { try next.validate() } catch {
            saveError = error.localizedDescription
            return
        }
        let previous = todos
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] store in
            // UndoManager calls synchronously on the main thread where this target was registered.
            MainActor.assumeIsolated {
                guard let reverted = store.todos.undoing(next, to: previous) else {
                    store.todoNotice = L10n.string("todo.undo_conflict")
                    return
                }
                store.updateTodos(reverted, undoManager: undoManager)
            }
        }
        todos = next
        if let projectID = UUID(uuidString: todoFilter), !next.projects.contains(where: { $0.id == projectID }) {
            todoFilter = "inbox"
        }
        hasUnsavedChanges = true
        scheduleSave()
    }

    func retrySave() {
        scheduleSave()
    }

    private func scheduleSave() {
        guard loadError == nil, hasUnsavedChanges else { return }
        saveRevision &+= 1
        let revision = saveRevision
        let snapshot = NoteLibrary(folders: folders, notes: notes, todos: todos)
        saveTask?.cancel()
        saveTask = Task { [weak self, writer] in
            do {
                try Task.checkCancellation()
                try await writer.write(snapshot, revision: revision)
                try Task.checkCancellation()
                guard let self, self.saveRevision == revision else { return }
                self.hasUnsavedChanges = false
                self.saveError = nil
            } catch is CancellationError {
                // A newer snapshot owns the pending save.
            } catch {
                guard let self, self.saveRevision == revision else { return }
                self.saveError = L10n.saveFailed(error.localizedDescription)
            }
        }
    }

    func flushPendingSave() async {
        var revision: Int
        repeat {
            revision = saveRevision
            await saveTask?.value
        } while revision != saveRevision
    }

    func reload() {
        // Failed writes must not be replaced by an older on-disk snapshot.
        guard !hasUnsavedChanges else { return }
        do {
            let library: NoteLibrary
            do {
                let encodedNotes = try Data(contentsOf: notesURL)
                library = try JSONDecoder().decode(NoteLibrary.self, from: encodedNotes)
            } catch CocoaError.fileReadNoSuchFile {
                library = NoteLibrary()
            }
            guard Set(library.notes.map(\.id)).count == library.notes.count,
                Set(library.folders.map(\.id)).count == library.folders.count
            else {
                loadError = L10n.string("storage.duplicate_identifiers")
                return
            }
            let folderIDs = Set(library.folders.map(\.id))
            guard library.folders.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                library.notes.allSatisfy({ note in note.folderID.map { folderIDs.contains($0) } ?? true })
            else {
                loadError = L10n.string("storage.invalid_folders")
                return
            }
            try library.validate()
            todos = library.todos
            notes = library.notes
            folders = library.folders
            if !notes.contains(where: { $0.id == selectedID }) {
                selectedID = notes.first?.id
            }
            loadError = nil
            saveError = nil
            var cleaned = todos
            cleaned.expireTrash()
            updateTodos(cleaned)
        } catch {
            loadError = L10n.loadFailed(error.localizedDescription)
        }
    }
}

/// Serial reconciliation also catches changes arriving while notification APIs suspend.
actor TodoNotifications {
    static let shared = TodoNotifications()
    private var latest = TodoLibrary()
    private var revision = 0
    private var isReconciling = false
    private var waiters: [CheckedContinuation<String?, Never>] = []

    static func requestAuthorization() async throws -> Bool {
        guard Bundle.main.bundleIdentifier != nil else { throw CocoaError(.featureUnsupported) }
        return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func reconcile(_ library: TodoLibrary) async -> String? {
        latest = library
        revision += 1
        if isReconciling {
            return await withCheckedContinuation { waiters.append($0) }
        }
        isReconciling = true
        defer { isReconciling = false }
        guard Bundle.main.bundleIdentifier != nil else {
            return latest.reminders(after: .now).isEmpty ? nil : L10n.string("todo.reminder.bundle")
        }
        let center = UNUserNotificationCenter.current()
        await TodoNotificationPresentation.install()
        var failure: String?
        repeat {
            let current = revision
            let snapshot = latest
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("todo-") }.map(\.identifier))
            let delivered = await center.deliveredNotifications()
            center.removeDeliveredNotifications(
                withIdentifiers: delivered.filter { notification in
                    guard let taskID = notification.request.content.userInfo["taskID"] as? String,
                        let id = UUID(uuidString: taskID)
                    else { return false }
                    return snapshot.item(id).map { $0.isDeleted || $0.status != .pending } ?? true
                }.map { $0.request.identifier })
            let settings = await center.notificationSettings()
            failure = nil
            let reminders = snapshot.reminders(after: .now)
            if !reminders.isEmpty {
                if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                    let capacity = max(0, 64 - pending.filter { !$0.identifier.hasPrefix("todo-") }.count)
                    if reminders.count > capacity { failure = L10n.string("todo.reminder.limit") }
                    for reminder in reminders.prefix(capacity) {
                        let content = UNMutableNotificationContent()
                        content.title = reminder.title
                        content.sound = .default
                        content.userInfo = ["taskID": reminder.taskID.uuidString]
                        let components = Calendar.current.dateComponents(
                            [.year, .month, .day, .hour, .minute, .second], from: reminder.date)
                        let request = UNNotificationRequest(
                            identifier: reminder.id, content: content,
                            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
                        do { try await center.add(request) } catch { failure = error.localizedDescription }
                    }
                } else {
                    failure = L10n.string("todo.reminder.denied")
                }
            }
            if current == revision { break }
        } while true
        for waiter in waiters { waiter.resume(returning: failure) }
        waiters.removeAll()
        return failure
    }
}

@MainActor
private final class TodoNotificationPresentation: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TodoNotificationPresentation()

    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
