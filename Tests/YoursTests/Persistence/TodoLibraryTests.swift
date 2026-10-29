import Foundation
import SwiftUI
import Testing

@testable import Yours

@MainActor
struct TodoLibraryTests {
    private func created(_ library: inout TodoLibrary, title: String, parentID: UUID? = nil, projectID: UUID? = nil) throws -> UUID {
        let id = library.create(title: title, parentID: parentID, projectID: projectID)
        return try #require(id)
    }

    @Test func completingParentRequiresExplicitChoiceAndKeepsAlreadyFinishedChildren() throws {
        var library = TodoLibrary()
        let root = try created(&library, title: "Release")
        let done = try created(&library, title: "Already shipped", parentID: root)
        let pending = try created(&library, title: "Remaining", parentID: root)
        let outcome1 = library.setStatus(done, to: .completed)
        #expect(outcome1)
        let outcome2 = library.setStatus(root, to: .completed)
        #expect(outcome2 == false)
        #expect(library.item(root)?.status == .pending)
        let outcome3 = library.setStatus(root, to: .completed, remaining: .cancelled)
        #expect(outcome3)
        #expect(library.item(done)?.status == .completed)
        #expect(library.item(pending)?.status == .cancelled)
        try library.validate()
    }

    @Test func cancellationLocksWholeBranchAndReopeningLeafRestoresOnlyAncestors() throws {
        var library = TodoLibrary()
        let root = try created(&library, title: "Root")
        let middle = try created(&library, title: "Middle", parentID: root)
        let leaf = try created(&library, title: "Leaf", parentID: middle)
        let sibling = try created(&library, title: "Sibling", parentID: root)
        library.setStatus(leaf, to: .completed)
        library.setStatus(root, to: .cancelled)
        #expect(library.item(leaf)?.status == .completed)
        #expect(library.isReadOnly(leaf))
        library.update(leaf) { $0.content.title = "Must not edit" }
        #expect(library.item(leaf)?.content.title == "Leaf")
        let outcome4 = library.create(title: "Blocked", parentID: leaf)
        #expect(outcome4 == nil)
        library.setStatus(leaf, to: .pending)
        #expect(library.item(root)?.status == .pending)
        #expect(library.item(middle)?.status == .pending)
        #expect(library.item(sibling)?.status == .cancelled)
        try library.validate()
    }

    @Test func movingSubtreeKeepsProjectsAndRejectsCyclesAtAnyDepth() throws {
        var library = TodoLibrary()
        let project = NoteFolder(id: UUID(), name: "Project")
        library.projects.append(project)
        let root = try created(&library, title: "Root")
        var parent = root
        for index in 0..<64 {
            parent = try created(&library, title: String(index), parentID: parent)
        }
        let outcome5 = library.move(root, parentID: parent, projectID: nil)
        #expect(outcome5 == false)
        let outcome6 = library.move(root, parentID: nil, projectID: project.id)
        #expect(outcome6)
        #expect(library.items.allSatisfy { $0.projectID == project.id })
        let outcome7 = library.move(parent, parentID: nil, projectID: nil)
        #expect(outcome7)
        #expect(library.item(parent)?.parentID == nil)
        try library.validate()
    }

    @Test func addingChildReopensCompletedParentWithoutResettingCompletedSiblings() throws {
        var library = TodoLibrary()
        let root = try created(&library, title: "Root")
        let child = try created(&library, title: "Done", parentID: root)
        library.setStatus(root, to: .completed, remaining: .completed)
        let outcome8 = library.create(title: "New", parentID: root)
        #expect(outcome8 != nil)
        #expect(library.item(root)?.status == .pending)
        #expect(library.item(child)?.status == .completed)
        try library.validate()
    }

    @Test func trashRestoreKeepsStatesAndExpiredContentCannotReturnFromOfflinePeer() throws {
        let now = Date()
        var library = TodoLibrary()
        let root = try created(&library, title: "Sensitive title")
        let child = try created(&library, title: "Child", parentID: root)
        library.setStatus(child, to: .completed)
        library.delete(root, now: now)
        let deleted = library
        library.restore(root, now: now.addingTimeInterval(14 * 86400))
        #expect(library.item(child)?.status == .completed)
        #expect(library.item(child)?.parentID == root)
        library = deleted
        library.expireTrash(now: now.addingTimeInterval(15 * 86400))
        #expect(library.items.allSatisfy { $0.purgedAt != nil && $0.content.title.isEmpty })
        library.restore(root)
        #expect(library.item(root)?.purgedAt != nil)
        let merged = try library.merging(deleted, base: deleted)
        #expect(merged.items.allSatisfy { $0.purgedAt != nil && $0.content.title.isEmpty })
    }

    @Test func restoreFallsBackWithoutRestoringDeletedParentOrProject() throws {
        var library = TodoLibrary()
        let project = NoteFolder(id: UUID(), name: "Project")
        library.projects = [project]
        let root = try created(&library, title: "Root", projectID: project.id)
        let child = try created(&library, title: "Child", parentID: root)
        let now = Date()
        library.delete(child, now: now)
        library.delete(root, now: now.addingTimeInterval(1))
        library.restore(child, now: now.addingTimeInterval(2))
        #expect(library.item(child)?.parentID == nil)
        #expect(library.item(child)?.projectID == project.id)
        #expect(library.item(root)?.isDeleted == true)
        try library.validate()
    }

    @Test func todayIncludesDeadlineAndCrossMidnightSlotsWithoutRewritingPlans() throws {
        var library = TodoLibrary()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let day = calendar.startOfDay(for: today)
        let id = try created(&library, title: "Scheduled")
        library.update(id) {
            $0.plannedDate = day.addingTimeInterval(-86400)
            $0.deadline = day
            $0.slots = [TodoTimeSlot(start: day.addingTimeInterval(-3600), end: day.addingTimeInterval(3600))]
        }
        let task = try #require(library.item(id))
        #expect(library.isToday(task, now: today, calendar: calendar))
        #expect(task.plannedDate == day.addingTimeInterval(-86400))
    }

    @Test func richNotesAndTaskLibrarySurviveSaveRestartAlongsideDocuments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(directory: directory)
        store.createNote(title: "Document", richText: MarkdownFormatting.render("Keep this"))
        var library = store.todos
        let id = try created(&library, title: "Task")
        library.update(id) { $0.content.richText = MarkdownFormatting.render("**Strong**\n- [x] Checklist") }
        store.updateTodos(library)
        await store.flushPendingSave()
        let restored = NoteStore(directory: directory)
        #expect(restored.loadError == nil)
        #expect(restored.todos == library)
        #expect(restored.notes == store.notes)
        #expect(restored.todos.item(id)?.content.text.contains("Checklist") == true)
    }

    @Test func statusUndoRestoresExactMixedStatesAndDoesNotOverwriteLaterChanges() throws {
        let store = NoteStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let undo = UndoManager()
        var next = store.todos
        let root = try created(&next, title: "Root")
        let child = try created(&next, title: "Done", parentID: root)
        next.setStatus(child, to: .completed)
        store.updateTodos(next)
        let before = store.todos
        next.setStatus(root, to: .cancelled)
        undo.beginUndoGrouping()
        store.updateTodos(next, undoManager: undo)
        undo.endUndoGrouping()
        undo.undo()
        #expect(store.todos == before)
        undo.redo()
        #expect(store.todos.item(root)?.status == .cancelled)
        #expect(store.todos.item(child)?.status == .completed)
    }

    @Test func creationUsesTodayAndProjectContextAndQuickAddKeepsListOpen() throws {
        let store = NoteStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.todoFilter = "today"
        let today = try #require(store.createTodo(title: "Today", openDetails: false, now: now))
        #expect(store.todos.item(today)?.plannedDate == now)
        #expect(store.openTodoID == nil)
        let project = NoteFolder(id: UUID(), name: "Project")
        var next = store.todos
        next.projects.append(project)
        store.updateTodos(next)
        store.todoFilter = project.id.uuidString
        let task = try #require(store.createTodo(now: now))
        #expect(store.todos.item(task)?.projectID == project.id)
        #expect(store.openTodoID == task)
    }

    @Test func undoProjectCreationFallsBackToInboxAndNewTasksRemainVisible() throws {
        let store = NoteStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let undo = UndoManager()
        var next = store.todos
        let project = NoteFolder(id: UUID(), name: "Temporary")
        next.projects.append(project)
        undo.beginUndoGrouping()
        store.updateTodos(next, undoManager: undo)
        undo.endUndoGrouping()
        store.todoFilter = project.id.uuidString
        undo.undo()
        #expect(store.todoFilter == "inbox")
        store.todoFilter = "trash"
        let id = try #require(store.createTodo())
        #expect(store.todoFilter == "inbox")
        #expect(store.todos.item(id)?.projectID == nil)
    }

    @Test func undoStatusPreservesLaterNotesAndOtherTasksAndSupportsRedo() throws {
        let store = NoteStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let undo = UndoManager()
        var next = store.todos
        let root = try created(&next, title: "Root")
        let other = try created(&next, title: "Other")
        store.updateTodos(next)
        next.setStatus(root, to: .completed)
        undo.beginUndoGrouping()
        store.updateTodos(next, undoManager: undo)
        undo.endUndoGrouping()
        next.update(root) { $0.content.richText = AttributedString("Later notes") }
        next.update(other) { $0.content.title = "Renamed" }
        store.updateTodos(next)
        undo.undo()
        #expect(store.todos.item(root)?.status == .pending)
        #expect(store.todos.item(root)?.content.text == "Later notes")
        #expect(store.todos.item(other)?.content.title == "Renamed")
        undo.redo()
        #expect(store.todos.item(root)?.status == .completed)
        #expect(store.todos.item(root)?.content.text == "Later notes")
    }

    @Test func undoConflictingStatePreservesCurrentContentAndReportsConflict() throws {
        let store = NoteStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let undo = UndoManager()
        var next = store.todos
        let id = try created(&next, title: "Task")
        store.updateTodos(next)
        next.setStatus(id, to: .completed)
        undo.beginUndoGrouping()
        store.updateTodos(next, undoManager: undo)
        undo.endUndoGrouping()
        next.setStatus(id, to: .cancelled)
        store.updateTodos(next)
        undo.undo()
        #expect(store.todos.item(id)?.status == .cancelled)
        #expect(store.todoNotice != nil)
    }

    @Test func duplicateDestinationsIncludeStableIdentityAndParentPath() throws {
        var library = TodoLibrary()
        let parent = try created(&library, title: "Parent")
        let first = try created(&library, title: "Same", parentID: parent)
        let second = try created(&library, title: "Same", parentID: parent)
        #expect(library.path(to: first).contains("Parent / Same"))
        #expect(library.destinationTitle(try #require(library.item(first))) != library.destinationTitle(try #require(library.item(second))))
        #expect(library.path(to: first, includingTask: false).hasSuffix("Parent"))
    }

    @Test func independentCloudEditsMergeButSameTaskConflictsNeverSilentlyOverwrite() throws {
        var base = TodoLibrary()
        let first = try created(&base, title: "First")
        let second = try created(&base, title: "Second")
        var local = base
        var remote = base
        local.update(first) { $0.content.title = "Local" }
        remote.update(second) { $0.content.title = "Remote" }
        let merged = try local.merging(remote, base: base)
        #expect(merged.item(first)?.content.title == "Local")
        #expect(merged.item(second)?.content.title == "Remote")
        remote.update(first) { $0.content.title = "Concurrent" }
        #expect(throws: LibrarySyncError.self) { try local.merging(remote, base: base) }
    }

    @Test func legacyVersionOneLoadsAndVersionTwoRequiresTasksPayload() throws {
        let legacy = Data("{\"version\":1,\"folders\":[],\"notes\":[]}".utf8)
        let library = try JSONDecoder().decode(NoteLibrary.self, from: legacy)
        #expect(library.todos.items.isEmpty)
        #expect(library.version == 2)
        let invalid = Data("{\"version\":2,\"folders\":[],\"notes\":[]}".utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(NoteLibrary.self, from: invalid) }
    }
}

extension TodoLibraryTests {
    @Test func legacyScheduleMigratesWithoutLosingDatesOrSlotIdentity() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        var item = TodoItem(title: "Legacy")
        item.plannedDate = day
        let slot = TodoTimeSlot(start: day.addingTimeInterval(86400), end: day.addingTimeInterval(90000))
        item.slots = [slot]
        let encoded = try JSONEncoder().encode(item)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "arrangements")
        let legacy = try JSONDecoder().decode(TodoItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.schedule.count == 2)
        #expect(legacy.schedule.last?.id == slot.id)
        var migrated = legacy
        migrated.schedule = legacy.schedule
        #expect(migrated.plannedDate == nil)
        #expect(migrated.slots.isEmpty)
        #expect(try JSONDecoder().decode(TodoItem.self, from: JSONEncoder().encode(migrated)).schedule == legacy.schedule)
    }

    @Test func multipleArrangementsSupportDaysCrossMidnightAndIndependentReminder() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        var library = TodoLibrary()
        let id = try created(&library, title: "Write")
        library.update(id) { item in
            item.schedule = [
                TodoArrangement(date: day, reminder: day.addingTimeInterval(-3600)),
                TodoArrangement(date: day.addingTimeInterval(86400 + 23 * 3600), end: day.addingTimeInterval(2 * 86400 + 3600)),
            ]
            item.deadline = day.addingTimeInterval(4 * 86400)
        }
        let task = try #require(library.item(id))
        for offset in [0, 1, 2, 4] {
            #expect(library.isToday(task, now: day.addingTimeInterval(Double(offset) * 86400), calendar: calendar))
        }
        #expect(library.isToday(task, now: day.addingTimeInterval(3 * 86400), calendar: calendar) == false)
        let reminder = try #require(library.reminders(after: day.addingTimeInterval(-7200)).first)
        #expect(reminder.date == day.addingTimeInterval(-3600))
        library.setStatus(id, to: .completed)
        #expect(library.reminders(after: .distantPast).isEmpty)
        library.setStatus(id, to: .pending)
        library.delete(id)
        #expect(library.reminders(after: .distantPast).isEmpty)
        try library.validate()
    }

    @Test func outlineUsesDisclosureAndRevealsAncestorContextForDateMatches() throws {
        var library = TodoLibrary()
        let parent = try created(&library, title: "Parent")
        let child = try created(&library, title: "Child", parentID: parent)
        let leaf = try created(&library, title: "Leaf", parentID: child)
        let all = Set([parent, child, leaf])
        #expect(library.outline(matching: all, expanded: []).map(\.id) == [parent])
        let expanded = library.outline(matching: all, expanded: [parent, child])
        #expect(expanded.map(\.id) == [parent, child, leaf])
        #expect(expanded.map(\.depth) == [0, 1, 2])
        #expect(expanded.map(\.isExpanded) == [true, true, false])
        #expect(library.outline(matching: [leaf], expanded: [], collapsed: [parent]).map(\.id) == [parent])
        #expect(library.outline(matching: [leaf], expanded: []).map(\.id) == [parent, child, leaf])
    }

    @Test func scheduleUndoPreservesLaterNotesAndRejectsInvalidRange() throws {
        var library = TodoLibrary()
        let id = try created(&library, title: "Schedule")
        let previous = library
        library.update(id) { $0.schedule = [TodoArrangement(date: .now)] }
        let applied = library
        library.update(id) { $0.content.richText = AttributedString("Keep this note") }
        let undone = try #require(library.undoing(applied, to: previous))
        #expect(undone.item(id)?.schedule.isEmpty == true)
        #expect(String(undone.item(id)?.content.richText.characters ?? AttributedString().characters) == "Keep this note")
        library.update(id) { $0.schedule = [TodoArrangement(date: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 99))] }
        #expect(throws: LibrarySyncError.self) { try library.validate() }
    }
}
