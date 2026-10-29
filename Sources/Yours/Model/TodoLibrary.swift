import Foundation

enum TodoStatus: String, Codable, CaseIterable, Sendable {
    case pending, completed, cancelled

    var title: String { L10n.string(String.LocalizationValue("todo.status." + rawValue)) }
    var symbol: String {
        switch self {
        case .pending: "square"
        case .completed: "checkmark.square.fill"
        case .cancelled: "minus.square"
        }
    }
}

struct TodoTimeSlot: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var start: Date
    var end: Date
}

/// One arrangement begins as a day; an optional end turns it into an execution block.
struct TodoArrangement: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var date: Date
    var end: Date?
    var reminder: Date?

    func includes(_ day: Date, calendar: Calendar) -> Bool {
        guard let end else { return calendar.isDate(date, inSameDayAs: day) }
        let startOfDay = calendar.startOfDay(for: day)
        let next = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        return date < next && end > startOfDay
    }
}

/// Reuse the document's portable rich-text codec without putting tasks in the document gallery.
struct TodoItem: Identifiable, Codable, Equatable, Sendable {
    var content: Note
    var parentID: UUID?
    var projectID: UUID?
    var status: TodoStatus = .pending
    var plannedDate: Date?
    var deadline: Date?
    var slots: [TodoTimeSlot] = []
    // nil decodes older libraries; the first schedule edit migrates legacy fields atomically.
    var arrangements: [TodoArrangement]?
    var schedule: [TodoArrangement] {
        get {
            if let arrangements { return arrangements }
            var result = slots.map { TodoArrangement(id: $0.id, date: $0.start, end: $0.end) }
            if let plannedDate, !result.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: plannedDate) }) {
                result.insert(TodoArrangement(id: id, date: plannedDate), at: 0)
            }
            return result
        }
        set {
            arrangements = newValue
            plannedDate = nil
            slots = []
        }
    }
    var deletedAt: Date?
    // Retain identity only after expiry, so an offline peer cannot resurrect removed content.
    var purgedAt: Date?

    var id: UUID { content.id }
    var isDeleted: Bool { deletedAt != nil || purgedAt != nil }

    init(title: String = "", parentID: UUID? = nil, projectID: UUID? = nil, now: Date = .now) {
        content = Note(id: UUID(), text: "", createdAt: now, updatedAt: now, title: title)
        self.parentID = parentID
        self.projectID = projectID
    }
}

struct TodoLibrary: Codable, Equatable, Sendable {
    var projects: [NoteFolder] = []
    var items: [TodoItem] = []

    private static func equivalent(_ first: TodoItem?, _ second: TodoItem?) -> Bool {
        guard var first, var second else { return first == second }
        first.content.richText = PortableFontAttribute.comparable(first.content.richText)
        second.content.richText = PortableFontAttribute.comparable(second.content.richText)
        return first == second
    }

    func hasSameContent(as other: TodoLibrary) -> Bool {
        guard
            projects.sorted(by: { $0.id.uuidString < $1.id.uuidString })
                == other.projects.sorted(by: { $0.id.uuidString < $1.id.uuidString }),
            items.count == other.items.count
        else { return false }
        let lookup = Dictionary(other.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return items.allSatisfy { Self.equivalent($0, lookup[$0.id]) }
    }

    func item(_ id: UUID) -> TodoItem? { items.first { $0.id == id } }

    func descendants(of id: UUID) -> Set<UUID> {
        var found: Set<UUID> = [id]
        var frontier = [id]
        while let parent = frontier.popLast() {
            for child in items where child.parentID == parent && found.insert(child.id).inserted {
                frontier.append(child.id)
            }
        }
        return found
    }

    func isReadOnly(_ id: UUID) -> Bool {
        var current = item(id)
        var visited: Set<UUID> = []
        while let task = current, visited.insert(task.id).inserted {
            if task.isDeleted || task.status == .cancelled { return true }
            current = task.parentID.flatMap(item)
        }
        return false
    }

    func unfinishedDescendants(_ id: UUID) -> [TodoItem] {
        let ids = descendants(of: id).subtracting([id])
        return items.filter { ids.contains($0.id) && !$0.isDeleted && $0.status == .pending }
    }

    struct Reminder: Equatable, Sendable {
        let id: String
        let taskID: UUID
        let title: String
        let date: Date
    }

    func reminders(after now: Date) -> [Reminder] {
        items.filter { !$0.isDeleted && $0.status == .pending }.flatMap { task in
            task.schedule.compactMap { entry -> Reminder? in
                guard let date = entry.reminder, date > now else { return nil }
                return Reminder(id: "todo-\(task.id)-\(entry.id)", taskID: task.id, title: task.content.displayTitle, date: date)
            }
        }.sorted { $0.date < $1.date }
    }

    struct OutlineRow: Identifiable {
        let id: UUID
        let depth: Int
        let hasChildren: Bool
        let isExpanded: Bool
    }

    /// Include ancestor context for date-filtered children without duplicating a task.
    func outline(matching matches: Set<UUID>, expanded: Set<UUID>, collapsed: Set<UUID> = []) -> [OutlineRow] {
        let live = items.filter { !$0.isDeleted }
        let lookup = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0) })
        var included = matches
        for id in matches {
            var parent = lookup[id]?.parentID
            var visited: Set<UUID> = [id]
            while let id = parent, visited.insert(id).inserted {
                included.insert(id)
                parent = lookup[id]?.parentID
            }
        }
        let children = Dictionary(grouping: live.filter { included.contains($0.id) }, by: \.parentID)
        var result: [OutlineRow] = []
        var visited: Set<UUID> = []
        func append(_ task: TodoItem, depth: Int) {
            guard visited.insert(task.id).inserted else { return }
            let nested = children[task.id] ?? []
            // Reveal matched descendants initially, while preserving an explicit user collapse.
            let isExpanded = expanded.contains(task.id) || (!matches.contains(task.id) && !collapsed.contains(task.id))
            result.append(OutlineRow(id: task.id, depth: depth, hasChildren: !nested.isEmpty, isExpanded: isExpanded))
            if isExpanded {
                for child in nested { append(child, depth: depth + 1) }
            }
        }
        for task in children[nil] ?? [] { append(task, depth: 0) }
        return result
    }

    func isToday(_ task: TodoItem, now: Date, calendar: Calendar = .current) -> Bool {
        task.schedule.contains { $0.includes(now, calendar: calendar) }
            || task.deadline.map { calendar.isDate($0, inSameDayAs: now) } == true
    }

    @discardableResult
    mutating func create(title: String, parentID: UUID? = nil, projectID: UUID? = nil, now: Date = .now) -> UUID? {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let parentID { guard item(parentID) != nil, !isReadOnly(parentID) else { return nil } }
        let project = parentID.flatMap(item)?.projectID ?? projectID
        guard project == nil || projects.contains(where: { $0.id == project }) else { return nil }
        let task = TodoItem(title: title, parentID: parentID, projectID: project, now: now)
        items.append(task)
        if let parentID { reopenAncestors(startingAt: parentID, now: now) }
        return task.id
    }

    mutating func update(_ id: UUID, now: Date = .now, edit: (inout TodoItem) -> Void) {
        guard !isReadOnly(id), let index = items.firstIndex(where: { $0.id == id }) else { return }
        edit(&items[index])
        items[index].content.updatedAt = now
    }

    @discardableResult
    mutating func setStatus(_ id: UUID, to status: TodoStatus, remaining: TodoStatus? = nil, now: Date = .now) -> Bool {
        guard let task = item(id), !task.isDeleted else { return false }
        if status != .pending && isReadOnly(id) { return false }
        let pending = Set(unfinishedDescendants(id).map(\.id))
        if status == .completed && !pending.isEmpty && (remaining == nil || remaining == .pending) { return false }
        for index in items.indices {
            if items[index].id == id {
                items[index].status = status
                items[index].content.updatedAt = now
            } else if pending.contains(items[index].id), status != .pending {
                items[index].status = status == .cancelled ? .cancelled : (remaining ?? .completed)
                items[index].content.updatedAt = now
            }
        }
        if status == .pending { reopenAncestors(startingAt: id, now: now) }
        return true
    }

    private mutating func reopenAncestors(startingAt id: UUID, now: Date) {
        var next: UUID? = id
        var visited: Set<UUID> = []
        while let current = next, visited.insert(current).inserted,
            let index = items.firstIndex(where: { $0.id == current })
        {
            items[index].status = .pending
            items[index].content.updatedAt = now
            next = items[index].parentID
        }
    }

    @discardableResult
    mutating func move(_ id: UUID, parentID: UUID?, projectID: UUID?, now: Date = .now) -> Bool {
        guard let task = item(id), !task.isDeleted, !isReadOnly(id) else { return false }
        let subtree = descendants(of: id)
        if let parentID {
            guard !subtree.contains(parentID), let parent = item(parentID), !isReadOnly(parentID) else { return false }
            return moveSubtree(id, subtree: subtree, parentID: parentID, projectID: parent.projectID, now: now)
        }
        guard projectID == nil || projects.contains(where: { $0.id == projectID }) else { return false }
        return moveSubtree(id, subtree: subtree, parentID: nil, projectID: projectID, now: now)
    }

    private mutating func moveSubtree(_ id: UUID, subtree: Set<UUID>, parentID: UUID?, projectID: UUID?, now: Date) -> Bool {
        for index in items.indices where subtree.contains(items[index].id) {
            items[index].projectID = projectID
            if items[index].id == id { items[index].parentID = parentID }
            items[index].content.updatedAt = now
        }
        if let parentID, item(id)?.status == .pending || !unfinishedDescendants(id).isEmpty {
            reopenAncestors(startingAt: parentID, now: now)
        }
        return true
    }

    mutating func delete(_ id: UUID, now: Date = .now) {
        guard let task = item(id), !task.isDeleted else { return }
        let subtree = descendants(of: id)
        for index in items.indices where subtree.contains(items[index].id) && !items[index].isDeleted {
            items[index].deletedAt = now
            items[index].content.updatedAt = now
        }
    }

    mutating func restore(_ id: UUID, now: Date = .now) {
        guard let task = item(id), task.deletedAt != nil, task.purgedAt == nil else { return }
        expireTrash(now: now)
        guard item(id)?.purgedAt == nil else { return }
        let batch = task.deletedAt
        let subtree = descendants(of: id)
        let parent = task.parentID.flatMap(item)
        let usableParent = parent.flatMap { !$0.isDeleted && !isReadOnly($0.id) ? $0 : nil }
        let project = task.projectID.flatMap { id in projects.contains { $0.id == id } ? id : nil }
        for index in items.indices
        where subtree.contains(items[index].id)
            && items[index].deletedAt == batch && items[index].purgedAt == nil
        {
            items[index].deletedAt = nil
            items[index].projectID = usableParent?.projectID ?? project
            items[index].content.updatedAt = now
            if items[index].id == id { items[index].parentID = usableParent?.id }
        }
        if let parentID = usableParent?.id, item(id)?.status == .pending || !unfinishedDescendants(id).isEmpty {
            reopenAncestors(startingAt: parentID, now: now)
        }
    }

    mutating func expireTrash(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-15 * 24 * 60 * 60)
        let roots = items.filter { $0.purgedAt == nil && $0.deletedAt.map { $0 <= cutoff } == true }
        let expired = roots.reduce(into: Set<UUID>()) { $0.formUnion(descendants(of: $1.id)) }
        for index in items.indices where expired.contains(items[index].id) {
            let id = items[index].id
            var tombstone = TodoItem(now: now)
            tombstone.content.id = id
            tombstone.status = .cancelled
            tombstone.deletedAt = items[index].deletedAt ?? now
            tombstone.purgedAt = now
            items[index] = tombstone
        }
    }

    /// Reverse only fields touched by an operation, preserving subsequent unrelated edits.
    func undoing(_ applied: TodoLibrary, to previous: TodoLibrary) -> TodoLibrary? {
        var result = self
        do {
            for id in Set(previous.items.map(\.id) + applied.items.map(\.id)) {
                let before = previous.item(id)
                let after = applied.item(id)
                guard before != after else { continue }
                if let before, let after, var current = result.item(id) {
                    guard current.purgedAt == nil else { return nil }
                    func revert<Value: Equatable>(_ key: WritableKeyPath<TodoItem, Value>) throws {
                        guard before[keyPath: key] != after[keyPath: key] else { return }
                        guard current[keyPath: key] == after[keyPath: key] else { throw TodoUndoConflict.changed }
                        current[keyPath: key] = before[keyPath: key]
                    }
                    try revert(\.status)
                    try revert(\.parentID)
                    try revert(\.projectID)
                    try revert(\.plannedDate)
                    try revert(\.deadline)
                    try revert(\.slots)
                    try revert(\.arrangements)
                    try revert(\.deletedAt)
                    try revert(\.purgedAt)
                    try revert(\.content.title)
                    try revert(\.content.richText)
                    if current.content.updatedAt == after.content.updatedAt { current.content.updatedAt = before.content.updatedAt }
                    guard let index = result.items.firstIndex(where: { $0.id == id }) else { return nil }
                    result.items[index] = current
                } else if before == nil, let after, result.item(id) == after {
                    result.items.removeAll { $0.id == id }
                } else if let before, after == nil, result.item(id) == nil {
                    result.items.append(before)
                } else {
                    return nil
                }
            }
            for id in Set(previous.projects.map(\.id) + applied.projects.map(\.id)) {
                let before = previous.projects.first { $0.id == id }
                let after = applied.projects.first { $0.id == id }
                guard before != after else { continue }
                guard result.projects.first(where: { $0.id == id }) == after else { return nil }
                result.projects.removeAll { $0.id == id }
                if let before { result.projects.append(before) }
            }
            try result.validate()
            return result
        } catch { return nil }
    }

    func projectTitle(_ project: NoteFolder) -> String {
        projects.filter { $0.name == project.name }.count > 1 ? "\(project.name) · \(project.id.uuidString.prefix(6))" : project.name
    }

    func path(to id: UUID, includingTask: Bool = true) -> String {
        guard let task = item(id) else { return "" }
        var parts: [String] = []
        var current: TodoItem? = includingTask ? task : task.parentID.flatMap(item)
        var visited: Set<UUID> = []
        while let node = current, visited.insert(node.id).inserted {
            parts.insert(node.content.displayTitle, at: 0)
            current = node.parentID.flatMap(item)
        }
        let project = projects.first { $0.id == task.projectID }.map(projectTitle) ?? L10n.string("todo.view.inbox")
        return ([project] + parts).joined(separator: " / ")
    }

    func destinationTitle(_ task: TodoItem) -> String {
        let path = path(to: task.id)
        return items.filter { !$0.isDeleted && self.path(to: $0.id) == path }.count > 1
            ? "\(path) · \(task.id.uuidString.prefix(6))" : path
    }

    func validate() throws {
        let lookup = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projectIDs = Set(projects.map(\.id))
        guard lookup.count == items.count, projectIDs.count == projects.count,
            projects.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw LibrarySyncError.invalidLibrary }
        for task in items where task.purgedAt == nil {
            guard task.projectID.map({ projectIDs.contains($0) }) ?? true,
                task.content.folderID == nil,
                Set(task.slots.map(\.id)).count == task.slots.count,
                task.slots.allSatisfy({ $0.start < $0.end }),
                Set(task.schedule.map(\.id)).count == task.schedule.count,
                task.schedule.allSatisfy({ entry in entry.end.map { $0 > entry.date } ?? true })
            else { throw LibrarySyncError.invalidLibrary }
            var visited: Set<UUID> = [task.id]
            var next = task.parentID
            while let id = next {
                guard visited.insert(id).inserted, let parent = lookup[id], parent.purgedAt == nil,
                    parent.projectID == task.projectID,
                    task.isDeleted || !parent.isDeleted,
                    task.status != .pending || parent.status == .pending || task.isDeleted
                else { throw LibrarySyncError.invalidLibrary }
                next = parent.parentID
            }
        }
    }

    /// Merge disjoint edits. Concurrent edits to the same task pause sync rather than silently losing rich text.
    func merging(_ remote: TodoLibrary, base: TodoLibrary?) throws -> TodoLibrary {
        if hasSameContent(as: remote) { return self }
        var merged = self
        for project in remote.projects where !merged.projects.contains(where: { $0.id == project.id }) {
            merged.projects.append(project)
        }
        for incoming in remote.items {
            guard let index = merged.items.firstIndex(where: { $0.id == incoming.id }) else {
                merged.items.append(incoming)
                continue
            }
            let local = merged.items[index]
            if local.purgedAt != nil { continue }
            if incoming.purgedAt != nil {
                merged.items[index] = incoming
                continue
            }
            let previous = base?.item(incoming.id)
            if Self.equivalent(local, incoming) || Self.equivalent(incoming, previous) { continue }
            guard Self.equivalent(local, previous) else { throw LibrarySyncError.todoConflict }
            merged.items[index] = incoming
        }
        // A purged parent removes stale descendants arriving from an offline peer, too.
        let purged = merged.items.filter { $0.purgedAt != nil }.map(\.id)
        for id in purged {
            let descendants = merged.descendants(of: id).subtracting([id])
            for index in merged.items.indices where descendants.contains(merged.items[index].id) {
                merged.items[index].deletedAt = Date.distantPast
            }
        }
        merged.expireTrash()
        try merged.validate()
        return merged
    }
}

private enum TodoUndoConflict: Error { case changed }
