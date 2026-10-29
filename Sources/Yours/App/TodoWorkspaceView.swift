import SwiftUI

private enum TodoLayout {
    static var canvas: Color {
        #if os(macOS)
            Color(nsColor: .textBackgroundColor)
        #else
            Color(uiColor: .systemBackground)
        #endif
    }
    static var detailTextInset: CGFloat { target + 8 }
    static func baselineOffset(heading: Bool = false) -> CGFloat {
        #if os(macOS)
            NSFont.preferredFont(forTextStyle: heading ? .title2 : .body).capHeight / 2
        #else
            UIFont.preferredFont(forTextStyle: heading ? .title2 : .body).capHeight / 2
        #endif
    }
    /// Row breathing room is independent of the compact status-button target.
    static func rowTextInset(for height: CGFloat) -> CGFloat {
        #if os(macOS)
            let font = NSFont.preferredFont(forTextStyle: .body)
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
        #else
            let lineHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
        #endif
        return max(0, (height - lineHeight) / 2)
    }
    #if os(macOS)
        static let inset: CGFloat = 16
        static let target: CGFloat = 24
        static let disclosureWidth: CGFloat = 16
        static let listInset: CGFloat = 8
        static let navigationHeight: CGFloat = 28
        static let listRowHeight: CGFloat = 32
    #else
        static let inset: CGFloat = 24
        static let target: CGFloat = 44
        static let disclosureWidth: CGFloat = 44
        static let listInset: CGFloat = 16
        static let navigationHeight: CGFloat = 44
        static let listRowHeight: CGFloat = 44
    #endif
}

struct TodoWorkspaceView: View {
    @Bindable var store: NoteStore
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var addingTask: Bool
    @FocusState private var focusedTaskID: UUID?
    @ScaledMetric(relativeTo: .body) private var groupMarkerSize: CGFloat = 15
    @State private var draft = ""
    @State private var showsProject = false
    @State private var projectName = ""
    @State private var now = Date.now
    @State private var toast = ToastPresenter()
    @State private var expanded: Set<UUID> = []
    @State private var collapsedTasks: Set<UUID> = []
    @State private var collapsedProjects: Set<String> = []

    private var filter: String { store.todoFilter }
    private var projectID: UUID? { UUID(uuidString: filter) }
    private var title: String {
        store.todos.projects.first { $0.id == projectID }.map(store.todos.projectTitle)
            ?? L10n.string(String.LocalizationValue("todo.view." + filter))
    }
    private var symbol: String {
        switch filter {
        case "all": "tray.full"
        case "today": "sun.max"
        case "inbox": "tray"
        case "completed": "checkmark.square"
        case "trash": "trash"
        default: "folder"
        }
    }
    private var allowsCreation: Bool { filter != "trash" && filter != "completed" }
    private var tasks: [TodoItem] {
        store.todos.items.filter { task in
            if filter == "trash" { return task.deletedAt != nil && task.purgedAt == nil }
            guard !task.isDeleted else { return false }
            if filter == "completed" { return task.status != .pending }
            guard task.status == .pending else { return false }
            if filter == "today" { return store.todos.isToday(task, now: now) }
            if filter == "inbox" { return task.projectID == nil }
            return projectID.map { task.projectID == $0 } ?? true
        }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 760 && (store.openTodoID == nil || geometry.size.width >= 900) {
                    sidebar.frame(width: 190)
                    Divider()
                }
                if store.openTodoID == nil || geometry.size.width >= 760 {
                    taskList(compact: geometry.size.width < 760)
                        .frame(maxWidth: .infinity)
                }
                if let task = editorPresentation.wrappedValue {
                    if geometry.size.width >= 760 { Divider() }
                    TodoDetailView(
                        store: store, id: task.id,
                        openChild: {
                            expanded.insert(task.id)
                            store.openTodoID = $0
                        }
                    )
                    .id(task.id)
                    .frame(maxWidth: .infinity)
                    .frame(width: geometry.size.width >= 760 ? max(320, min(430, geometry.size.width * 0.4)) : nil)
                }
            }
            .background(TodoLayout.canvas)
        }
        .safeAreaInset(edge: .bottom) { TodoSaveStatus(store: store) }
        .overlay { ToastOverlay(presenter: toast) }
        .onChange(of: store.todos) { _, library in
            if let id = store.openTodoID, library.item(id)?.isDeleted != false { store.openTodoID = nil }
        }
        .alert("todo.project.create", isPresented: $showsProject) {
            TextField("folder.name", text: $projectName)
            Button("common.cancel", role: .cancel) { projectName = "" }
            Button("todo.add") { createProject() }
                .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .task {
            while !Task.isCancelled {
                refreshDate()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refreshDate() } }
        .onChange(of: store.todoNotice) { _, notice in
            if let notice, store.openTodoID == nil {
                toast.show(ToastMessage(title: L10n.string("todo.undo_conflict.title"), message: notice))
                store.todoNotice = nil
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                navigationRow("all", name: L10n.string("todo.view.all"), symbol: "tray.full")
                navigationRow("today", name: L10n.string("todo.view.today"), symbol: "calendar")
                navigationRow("inbox", name: L10n.string("todo.view.inbox"), symbol: "tray")
                Divider().padding(.vertical, 6)
                HStack {
                    Text("todo.projects").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showsProject = true
                    } label: {
                        Image(systemName: "plus").font(.subheadline.weight(.medium))
                            .frame(width: TodoLayout.target, height: TodoLayout.target).contentShape(.rect)
                    }
                    .buttonStyle(.plain).todoPointer().help("todo.project.create").accessibilityLabel("todo.project.create")
                    .disabled(store.loadError != nil)
                }.frame(minHeight: TodoLayout.target).padding(.horizontal, 8)
                ForEach(store.todos.projects) { project in
                    navigationRow(project.id.uuidString, name: store.todos.projectTitle(project), symbol: "folder")
                }
                Divider().padding(.vertical, 6)
                navigationRow("completed", name: L10n.string("todo.view.completed"), symbol: "checkmark.circle")
                navigationRow("trash", name: L10n.string("todo.view.trash"), symbol: "trash")
            }.padding(8)
        }
        .background(.primary.opacity(0.025))
    }

    private func navigationRow(_ value: String, name: String, symbol: String) -> some View {
        Button {
            store.openTodoID = nil
            store.todoFilter = value
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).frame(width: 20)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + TodoLayout.baselineOffset() }
                Text(name).lineLimit(2)
            }
            .padding(.vertical, 2)
            .font(.body).foregroundStyle(filter == value ? AppTheme.accent : .primary)
            .frame(maxWidth: .infinity, minHeight: TodoLayout.navigationHeight, alignment: .leading)
            .padding(.horizontal, 8)
            .background(filter == value ? AppTheme.accent.opacity(0.10) : .clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain).todoPointer()
        .accessibilityAddTraits(filter == value ? .isSelected : [])
        .accessibilityRemoveTraits(filter == value ? [] : .isSelected)
        .help(name).accessibilityIdentifier("todo-filter-" + value)
    }

    private func taskList(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                if compact {
                    Menu {
                        viewChoice("all", symbol: "tray.full")
                        viewChoice("today", symbol: "calendar")
                        viewChoice("inbox", symbol: "tray")
                        Section("todo.projects") {
                            ForEach(store.todos.projects) { project in
                                Toggle(store.todos.projectTitle(project), isOn: choice(project.id.uuidString))
                            }
                            Button("todo.project.create") { showsProject = true }
                        }
                        viewChoice("completed", symbol: "checkmark.circle")
                        viewChoice("trash", symbol: "trash")
                    } label: {
                        Text(title).font(.title.bold())
                    }
                    .menuStyle(.borderlessButton).todoPointer().accessibilityIdentifier("todo-filter")
                } else {
                    Text(title).font(.title.bold()).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, TodoLayout.listInset).padding(.trailing, TodoLayout.inset)
            .padding(.top, 16).padding(.bottom, 8)
            if let error = store.loadError {
                ContentUnavailableView {
                    Label("storage.load_failed.title", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("storage.reload") { store.reload() }.todoPointer()
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if tasks.isEmpty {
                                ContentUnavailableView {
                                    Label(filter == "trash" ? "todo.trash.empty" : "todo.empty", systemImage: symbol)
                                } description: {
                                    Text(
                                        filter == "trash"
                                            ? "todo.trash.empty_help"
                                            : (filter == "today"
                                                ? "todo.empty.today" : (allowsCreation ? "todo.empty.add" : "todo.empty.finished")))
                                }.padding(.vertical, 28)
                            } else if filter == "trash" {
                                ForEach(tasks) { trashRow($0) }
                            } else if filter == "all" {
                                projectGroup(nil)
                                ForEach(store.todos.projects) { project in projectGroup(project) }
                            } else {
                                outline(matches: tasks)
                            }
                            if allowsCreation {
                                HStack(alignment: .firstTextBaseline, spacing: 0) {
                                    Color.clear.frame(width: TodoLayout.disclosureWidth, height: 1).accessibilityHidden(true)
                                    Image(systemName: "plus").font(.system(size: groupMarkerSize)).foregroundStyle(.secondary)
                                        .frame(width: groupMarkerSize, height: groupMarkerSize)
                                        .frame(width: TodoLayout.target, height: TodoLayout.target, alignment: .trailing)
                                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + TodoLayout.baselineOffset() }
                                        .padding(.trailing, 8).accessibilityHidden(true)
                                    TextField("todo.quick_add", text: $draft)
                                        .textFieldStyle(.plain).focused($addingTask)
                                        .onSubmit { create(openDetails: false) }
                                        .accessibilityIdentifier("todo-quick-add")
                                }
                                .padding(.top, 8).padding(.bottom, 8)
                            }
                        }.padding(.horizontal, TodoLayout.listInset).padding(.bottom, 16)
                    }
                    .onChange(of: focusedTaskID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, TodoLayout.inset)
        .frame(maxWidth: .infinity, alignment: .center)
        .onChange(of: filter) { _, _ in focusedTaskID = nil }
    }

    @ViewBuilder private func projectGroup(_ project: NoteFolder?) -> some View {
        let matches = tasks.filter { $0.projectID == project?.id }
        if !matches.isEmpty {
            let key = project?.id.uuidString ?? "inbox"
            Button {
                if !collapsedProjects.insert(key).inserted { collapsedProjects.remove(key) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Image(systemName: collapsedProjects.contains(key) ? "chevron.right" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: TodoLayout.disclosureWidth, height: TodoLayout.target)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + TodoLayout.baselineOffset() }
                    Image(systemName: project == nil ? "tray" : "folder")
                        .font(.system(size: groupMarkerSize)).foregroundStyle(AppTheme.accent)
                        .frame(width: groupMarkerSize, height: groupMarkerSize)
                        .frame(width: TodoLayout.target, height: TodoLayout.target, alignment: .trailing)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + TodoLayout.baselineOffset() }
                        .padding(.trailing, 8)
                    Text(project.map(store.todos.projectTitle) ?? L10n.string("todo.view.inbox")).font(.headline)
                    Text(matches.count.formatted()).font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
                    Spacer(minLength: 0)
                }.padding(.top, 12).padding(.bottom, 4).contentShape(.rect)
            }.buttonStyle(.plain).todoPointer()
            if !collapsedProjects.contains(key) { outline(matches: matches) }
        }
    }

    private func outline(matches: [TodoItem]) -> some View {
        let rows = store.todos.outline(matching: Set(matches.map(\.id)), expanded: expanded, collapsed: collapsedTasks)
        return ForEach(rows) { row in
            TodoOutlineRow(
                store: store, row: row, now: now, showsPath: filter == "today" && row.depth == 0,
                taskFocus: $focusedTaskID, isKeyboardFocused: focusedTaskID == row.id, onNavigate: navigateTasks,
                expanded: $expanded, collapsed: $collapsedTasks
            )
            .id(row.id)
        }
    }

    private var visibleOutlineRows: [TodoLibrary.OutlineRow] {
        if filter != "all" {
            return store.todos.outline(matching: Set(tasks.map(\.id)), expanded: expanded, collapsed: collapsedTasks)
        }
        let groups: [UUID?] = [nil] + store.todos.projects.map { Optional($0.id) }
        return groups.flatMap { projectID -> [TodoLibrary.OutlineRow] in
            guard !collapsedProjects.contains(projectID?.uuidString ?? "inbox") else { return [] }
            let matches = Set(tasks.filter { $0.projectID == projectID }.map(\.id))
            return store.todos.outline(matching: matches, expanded: expanded, collapsed: collapsedTasks)
        }
    }

    private func navigateTasks(_ key: KeyEquivalent) -> KeyPress.Result {
        let rows = visibleOutlineRows
        guard !rows.isEmpty else { return .ignored }
        if key == .upArrow || key == .downArrow {
            focusedTaskID = TodoKeyboardNavigation.adjacentID(
                in: rows.map(\.id), current: focusedTaskID, offset: key == .upArrow ? -1 : 1)
            return .handled
        }
        guard let id = focusedTaskID, let index = rows.firstIndex(where: { $0.id == id }) else { return .ignored }
        let row = rows[index]
        let isExpanded = expanded.contains(id) || (row.isExpanded && !collapsedTasks.contains(id))
        if key == .rightArrow, row.hasChildren {
            if isExpanded, index + 1 < rows.count, rows[index + 1].depth > row.depth {
                focusedTaskID = rows[index + 1].id
            } else {
                expanded.insert(id)
                collapsedTasks.remove(id)
            }
            return .handled
        }
        if key == .leftArrow {
            if row.hasChildren && isExpanded {
                expanded.remove(id)
                collapsedTasks.insert(id)
                return .handled
            }
            if let parent = store.todos.item(id)?.parentID, rows.contains(where: { $0.id == parent }) {
                focusedTaskID = parent
                return .handled
            }
        }
        return .ignored
    }

    private func refreshDate() {
        now = .now
        var next = store.todos
        next.expireTrash(now: now)
        store.updateTodos(next)
    }

    private var editorPresentation: Binding<TodoItem?> {
        Binding(
            get: {
                guard let id = store.openTodoID, let task = store.todos.item(id), !task.isDeleted else { return nil }
                return task
            }, set: { store.openTodoID = $0?.id })
    }

    private func choice(_ name: String) -> Binding<Bool> {
        Binding(
            get: { filter == name },
            set: {
                if $0 {
                    store.openTodoID = nil
                    store.todoFilter = name
                }
            })
    }

    private func viewChoice(_ name: String, symbol: String) -> some View {
        Toggle(isOn: choice(name)) {
            Label(L10n.string(String.LocalizationValue("todo.view." + name)), systemImage: symbol)
        }.todoPointer()
    }

    private func create(openDetails: Bool) {
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard openDetails || !title.isEmpty else { return }
        store.createTodo(title: title.isEmpty ? nil : title, openDetails: openDetails, undoManager: undoManager)
        draft = ""
        if !openDetails { addingTask = true }
    }

    private func createProject() {
        let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var next = store.todos
        let project = NoteFolder(id: UUID(), name: name)
        next.projects.append(project)
        store.updateTodos(next, undoManager: undoManager)
        store.openTodoID = nil
        store.todoFilter = project.id.uuidString
        projectName = ""
    }

    private func trashRow(_ task: TodoItem) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(task.content.displayTitle)
                Text(store.todos.path(to: task.id, includingTask: false)).font(.caption).foregroundStyle(.secondary)
                if let deleted = task.deletedAt {
                    Text(
                        TodoText.format(
                            "todo.trash.expires",
                            deleted.addingTimeInterval(15 * 24 * 60 * 60).formatted(
                                .dateTime.year().month().day().hour().minute().locale(L10n.language.locale)))
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if store.todos.descendants(of: task.id).count > 1 {
                    Text("todo.restore.subtree").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                var next = store.todos
                next.restore(task.id)
                store.updateTodos(next, undoManager: undoManager)
                guard let restored = next.item(task.id), !restored.isDeleted else {
                    toast.show(ToastMessage(title: L10n.string("todo.unavailable"), message: L10n.string("todo.trash.retention")))
                    return
                }
                toast.show(ToastMessage(title: L10n.string("todo.restore"), message: next.path(to: task.id, includingTask: false)))
            } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: TodoLayout.target, height: TodoLayout.target).contentShape(.rect)
            }
            .buttonStyle(.plain).todoPointer().help("todo.restore").accessibilityLabel("todo.restore")
            .accessibilityIdentifier("todo-restore-\(task.id)")
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
    }
}

/// Each row owns its expansion rendering so stable IDs cannot retain an old action/label capture.
enum TodoKeyboardNavigation {
    static func adjacentID(in ids: [UUID], current: UUID?, offset: Int) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return offset < 0 ? ids.last : ids.first }
        return ids[min(ids.count - 1, max(0, index + offset))]
    }
}

private struct TodoOutlineRow: View {
    let store: NoteStore
    let row: TodoLibrary.OutlineRow
    let now: Date
    let showsPath: Bool
    let taskFocus: FocusState<UUID?>.Binding
    let isKeyboardFocused: Bool
    let onNavigate: (KeyEquivalent) -> KeyPress.Result
    @State private var isHovered = false
    @Binding var expanded: Set<UUID>
    @Binding var collapsed: Set<UUID>

    private var isExpanded: Bool { expanded.contains(row.id) || (row.isExpanded && !collapsed.contains(row.id)) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if row.hasChildren {
                Button {
                    if isExpanded {
                        expanded.remove(row.id)
                        collapsed.insert(row.id)
                    } else {
                        expanded.insert(row.id)
                        collapsed.remove(row.id)
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: TodoLayout.disclosureWidth, height: TodoLayout.target).contentShape(.rect)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + TodoLayout.baselineOffset() }
                }.buttonStyle(.plain).todoPointer()
                    .help(isExpanded ? "todo.collapse" : "todo.expand")
                    .accessibilityLabel(isExpanded ? "todo.collapse" : "todo.expand")
                    .accessibilityIdentifier("todo-expand-\(row.id)")
            } else {
                Color.clear.frame(width: TodoLayout.disclosureWidth, height: 1).accessibilityHidden(true)
            }
            TodoRow(
                store: store, id: row.id, now: now, minimumHeight: TodoLayout.listRowHeight, trailingInset: TodoLayout.inset,
                titleLineLimit: 2, taskFocus: taskFocus, onNavigate: onNavigate, showsPath: showsPath || row.depth >= 6,
                level: row.depth >= 6 ? row.depth + 1 : nil
            ) {
                taskFocus.wrappedValue = row.id
                store.openTodoID = row.id
            }
        }
        .padding(.leading, CGFloat(min(row.depth, 6)) * 16)
        .padding(.vertical, 2)
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .background(
            store.openTodoID == row.id ? AppTheme.accent.opacity(0.09) : isHovered ? Color.primary.opacity(0.035) : .clear,
            in: .rect(cornerRadius: 8)
        )
        .overlay {
            if isKeyboardFocused {
                RoundedRectangle(cornerRadius: 8).strokeBorder(AppTheme.accent.opacity(0.65), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct TodoStatusButton: View {
    let store: NoteStore
    let id: UUID
    @Environment(\.undoManager) private var undoManager
    var review: (() -> Void)?
    var isHeading = false
    @State private var confirmsCompletion = false
    @State private var hovered = false
    @ScaledMetric(relativeTo: .body) private var markerSize: CGFloat = 15

    var body: some View {
        if let task = store.todos.item(id) {
            Button {
                if task.status == .pending && !store.todos.unfinishedDescendants(id).isEmpty {
                    confirmsCompletion = true
                } else {
                    set(task.status == .pending ? .completed : .pending)
                }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: markerSize * DocumentTypography.taskCornerRadiusRatio)
                        .strokeBorder(
                            hovered ? AppTheme.accent : Color.secondary,
                            lineWidth: max(1, markerSize * DocumentTypography.taskBorderWidthRatio))
                    if task.status != .pending {
                        Image(systemName: task.status == .completed ? "checkmark" : "minus")
                            .font(.system(size: markerSize * DocumentTypography.taskCheckScale, weight: .semibold))
                            .foregroundStyle(task.status == .completed ? AppTheme.accent : Color.secondary)
                            .offset(x: task.status == .completed ? markerSize * DocumentTypography.taskCheckHorizontalOffsetRatio : 0)
                    }
                }
                .frame(width: markerSize, height: markerSize)
                .frame(minWidth: TodoLayout.target, minHeight: TodoLayout.target, alignment: .trailing)
                .contentShape(.rect)
            }
            .buttonStyle(.plain).todoPointer()
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + TodoLayout.baselineOffset(heading: isHeading) }
            .onHover { hovered = $0 }
            .help(task.status == .pending ? L10n.string("todo.complete") : L10n.string("todo.reopen"))
            .accessibilityLabel(task.status == .pending ? L10n.string("todo.complete") : L10n.string("todo.reopen"))
            .accessibilityValue(task.status.title)
            .accessibilityIdentifier("todo-status-\(id)")
            .alert("todo.finish_children", isPresented: $confirmsCompletion) {
                Button("todo.children.complete") { set(.completed, remaining: .completed) }
                Button("todo.children.cancel") { set(.completed, remaining: .cancelled) }
                Button("todo.children.review", role: .cancel) {
                    if let review {
                        review()
                    } else {
                        store.todoReviewID = id
                        store.openTodoID = id
                    }
                }
            } message: {
                Text("todo.finish_children.message")
            }
        }
    }

    private func set(_ status: TodoStatus, remaining: TodoStatus? = nil) {
        var next = store.todos
        guard next.setStatus(id, to: status, remaining: remaining) else { return }
        store.updateTodos(next, undoManager: undoManager)
    }
}

private struct TodoRow: View {
    let store: NoteStore
    let id: UUID
    var now = Date.now
    var minimumHeight = TodoLayout.target
    var trailingInset: CGFloat = 0
    var titleLineLimit: Int?
    var identifierScope = ""
    var taskFocus: FocusState<UUID?>.Binding?
    var onNavigate: ((KeyEquivalent) -> KeyPress.Result)?
    var showsPath = false
    var level: Int?
    let open: () -> Void

    @Environment(\.undoManager) private var undoManager
    @State private var isHovered = false
    @State private var titleDraft: String?

    var body: some View {
        if let task = store.todos.item(id), !task.isDeleted {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TodoStatusButton(store: store, id: id)
                rowContent(task)
            }
            .onHover { isHovered = $0 }
            .onDisappear {
                if let titleDraft { commitTitle(titleDraft) }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func openDetails() {
        #if os(macOS)
            NSApp.keyWindow?.makeFirstResponder(nil)
        #else
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
        open()
    }

    private func commitTitle(_ title: String) {
        titleDraft = nil
        guard !store.todos.isReadOnly(id) else { return }
        let normalizedTitle = title.replacingOccurrences(of: "\n", with: " ")
        guard store.todos.item(id)?.content.title != normalizedTitle else { return }
        var next = store.todos
        next.update(id) { $0.content.title = normalizedTitle }
        store.updateTodos(next, undoManager: undoManager)
    }

    private func rowContent(_ task: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                TodoInlineTitle(
                    title: task.content.title, displayTitle: task.content.displayTitle,
                    isReadOnly: store.todos.isReadOnly(id), isCompleted: task.status == .completed,
                    lineLimit: titleLineLimit, draft: $titleDraft, onCommit: commitTitle
                )
                .accessibilityIdentifier("todo-inline-title-\(identifierScope)\(id)")
                if let level {
                    Text(TodoText.format("todo.level", Int64(level))).font(.caption).foregroundStyle(.secondary)
                }
                if task.status == .cancelled {
                    Text(task.status.title).font(.caption).foregroundStyle(.secondary)
                }
                if showsPath && (task.parentID != nil || task.projectID != nil) {
                    Text(store.todos.path(to: id, includingTask: false)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(store.todos.path(to: id, includingTask: false))
                }
                if !task.schedule.isEmpty || task.deadline != nil {
                    TodoDateSummary(task: task, now: now)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(!store.todos.isReadOnly(id))
            Button(action: openDetails) {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(.secondary)
                    .frame(width: TodoLayout.target, height: TodoLayout.target).contentShape(.rect)
            }
            .buttonStyle(.plain).todoPointer()
            // Preserve the text row's height; the larger native hit target extends into its vertical padding.
            .frame(height: minimumHeight - 2 * TodoLayout.rowTextInset(for: minimumHeight))
            .opacity(showsDetailButton ? 1 : 0)
            .help("todo.details").accessibilityLabel("todo.details")
            .accessibilityIdentifier("todo-detail-button-\(identifierScope)\(id)")
        }
        .padding(.vertical, TodoLayout.rowTextInset(for: minimumHeight))
        .padding(.trailing, max(8, trailingInset))
        .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
        .background { detailHitArea }
        .alignmentGuide(.firstTextBaseline) { _ in
            #if os(macOS)
                TodoLayout.rowTextInset(for: minimumHeight) + NSFont.preferredFont(forTextStyle: .body).ascender
            #else
                TodoLayout.rowTextInset(for: minimumHeight) + UIFont.preferredFont(forTextStyle: .body).ascender
            #endif
        }
    }

    private var showsDetailButton: Bool {
        #if os(macOS)
            isHovered || taskFocus?.wrappedValue == id || store.openTodoID == id || titleDraft != nil
        #else
            true
        #endif
    }

    @ViewBuilder private var detailHitArea: some View {
        let button = Button(action: openDetails) { Color.clear.contentShape(.rect) }
            .buttonStyle(.plain).todoPointer().accessibilityLabel("todo.details")
            .accessibilityIdentifier("todo-open-\(identifierScope)\(id)")
        if let taskFocus {
            button.focusable().focused(taskFocus, equals: id).focusEffectDisabled()
                .onKeyPress(.return) {
                    openDetails()
                    return .handled
                }
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                    guard press.modifiers.intersection([.command, .control, .option]).isEmpty, let onNavigate else { return .ignored }
                    return onNavigate(press.key)
                }
        } else {
            button
        }
    }

}

private struct TodoDateSummary: View {
    let task: TodoItem
    var now = Date.now

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { dates }
            VStack(alignment: .leading, spacing: 4) { dates }
        }.font(.caption).foregroundStyle(.secondary)
    }

    private var summaryEntry: TodoArrangement? {
        let entries = task.schedule.sorted { $0.date < $1.date }
        return entries.first { $0.includes(now, calendar: .current) }
            ?? entries.first { $0.date > now } ?? entries.last
    }

    @ViewBuilder private var dates: some View {
        if let entry = summaryEntry {
            Label {
                Text(entry.date.formatted(.dateTime.month().day().locale(L10n.language.locale)))
                if let end = entry.end {
                    Text(
                        entry.date.formatted(date: .omitted, time: .shortened) + "–"
                            + end.formatted(
                                date: Calendar.current.isDate(entry.date, inSameDayAs: end) ? .omitted : .abbreviated, time: .shortened))
                }
                if task.schedule.count > 1 { Text("+\(task.schedule.count - 1)") }
            } icon: {
                Image(systemName: entry.end == nil ? "calendar" : "clock")
            }
        }
        if let date = task.deadline {
            let overdue = task.status == .pending && date < Calendar.current.startOfDay(for: now)
            Label {
                if overdue {
                    Text(TodoText.date("todo.overdue.summary", date))
                } else {
                    Text(TodoText.date("todo.deadline.summary", date))
                }
            } icon: {
                Image(systemName: overdue ? "exclamationmark.circle" : "flag")
            }
            .foregroundStyle(overdue ? Color.red : Color.secondary)
        }

    }
}

private struct TodoPropertyLayout: Layout {
    private let spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing }
        let items = positions(subviews, width: width)
        return CGSize(width: width, height: items.map { $0.0.y + $0.1.height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, item) in zip(subviews, positions(subviews, width: bounds.width)) {
            view.place(
                at: CGPoint(x: bounds.minX + item.0.x, y: bounds.minY + item.0.y), anchor: .topLeading,
                proposal: ProposedViewSize(item.1))
        }
    }

    private func positions(_ subviews: Subviews, width: CGFloat) -> [(CGPoint, CGSize)] {
        var items: [(CGPoint, CGSize)] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, view.sizeThatFits(.unspecified).width), height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            items.append((CGPoint(x: x, y: y), size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return items
    }
}

private struct TodoDetailView: View {
    let store: NoteStore
    let id: UUID
    let openChild: (UUID) -> Void
    @Environment(\.undoManager) private var undoManager
    @State private var selection = AttributedTextSelection()
    @State private var bridge = EditorCommandBridge()
    @State private var childTitle = ""
    @State private var session = UUID()
    @State private var toast = ToastPresenter()
    @State private var editedArrangement: TodoArrangement?
    @State private var showsDeadline = false
    @State private var editsReminder = false
    @State private var showsMove = false
    @FocusState private var addingChild: Bool

    private var task: TodoItem? { store.todos.item(id) }
    private var isReadOnly: Bool { store.todos.isReadOnly(id) }

    var body: some View {
        Group {
            if let task, !task.isDeleted {
                VStack(spacing: 0) {
                    detailToolbar(task)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                header(task)
                                VStack(alignment: .leading, spacing: 12) {
                                    properties(task)
                                    Divider()
                                    children.id("todo-children")
                                    Divider()
                                    Text("todo.section.notes").font(.headline)
                                }
                                .padding(.leading, TodoLayout.detailTextInset).padding(.trailing, TodoLayout.inset)
                                .padding(.top, 4)
                                notesEditor.padding(.bottom, 16)
                            }
                        }
                        .onChange(of: store.todoReviewID) { _, target in
                            if target == id {
                                proxy.scrollTo("todo-children", anchor: .top)
                                store.todoReviewID = nil
                            }
                        }
                    }
                }
                .background(TodoLayout.canvas)
                .overlay { ToastOverlay(presenter: toast) }
            } else {
                ContentUnavailableView("todo.unavailable", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showsMove) { movePicker }
        .onChange(of: store.todoNotice) { _, notice in
            if let notice {
                toast.show(ToastMessage(title: L10n.string("todo.undo_conflict.title"), message: notice))
                store.todoNotice = nil
            }
        }
        .onAppear {
            store.registerEditor(session, noteID: id)
            if store.todoReviewID == id {
                store.todoReviewID = nil
            }
        }
        .onDisappear { store.unregisterEditor(session) }
    }

    // The native rich-text editor stays mounted while schedule sheets are presented.
    private var notesEditor: some View {
        NativeRichTextEditor(
            text: Binding(
                get: { self.task?.content.richText ?? AttributedString() }, set: { value in edit { $0.content.richText = value } }),
            selection: $selection, commandBridge: bridge, documentID: id,
            isEditable: !isReadOnly, usesDocumentFont: false, horizontalInset: TodoLayout.inset,
            placeholder: isReadOnly ? nil : L10n.string("todo.notes.placeholder"), contentHeightRange: 64...260, focusWhenEmpty: false,
            onToast: { toast.show($0) }
        )
        .padding(.leading, TodoLayout.detailTextInset - TodoLayout.inset)
        .accessibilityIdentifier("todo-notes")
    }

    private func detailToolbar(_ task: TodoItem) -> some View {
        HStack(spacing: 4) {
            if let parentID = task.parentID {
                Button {
                    openChild(parentID)
                } label: {
                    detailPath(task, symbol: "chevron.left")
                }.buttonStyle(.plain).todoPointer()
            } else {
                detailPath(task, symbol: "folder")
            }
            actions
            Button {
                store.openTodoID = nil
            } label: {
                Image(systemName: "xmark").frame(width: TodoLayout.target, height: TodoLayout.target).contentShape(.rect)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).todoPointer()
            .help("todo.detail.close").accessibilityLabel("todo.detail.close")
            .accessibilityIdentifier("todo-detail-close")
        }
        .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 4)
    }

    private func detailPath(_ task: TodoItem, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: TodoLayout.target - 8)
            Text(store.todos.path(to: task.id, includingTask: false)).lineLimit(2)
        }
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: TodoLayout.target, alignment: .leading)
        .help(store.todos.path(to: task.id, includingTask: false))
    }

    private func header(_ task: TodoItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TodoStatusButton(store: store, id: id, review: { store.todoReviewID = id }, isHeading: true)
                TextField(
                    "todo.title",
                    text: Binding(
                        get: { self.task?.content.title ?? "" },
                        set: { value in edit { $0.content.title = value.replacingOccurrences(of: "\n", with: " ") } }), axis: .vertical
                )
                .font(.title2.bold()).textFieldStyle(.plain).lineLimit(1...6)
                .disabled(isReadOnly).accessibilityIdentifier("todo-title")
            }
            if task.status != .pending {
                Text(task.status.title).font(.caption).foregroundStyle(.secondary).padding(.leading, TodoLayout.detailTextInset)
            }
            if isReadOnly {
                Label("todo.read_only", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, TodoLayout.detailTextInset)
            }
        }
        .padding(.trailing, TodoLayout.inset).padding(.top, 4).padding(.bottom, 4)
    }

    private var children: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("todo.section.children").font(.headline)
                let count = store.todos.items.filter { $0.parentID == id && !$0.isDeleted }.count
                if count > 0 { Text(count.formatted()).font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }.padding(.bottom, 4)
            ForEach(store.todos.items.filter { $0.parentID == id && !$0.isDeleted }) { child in
                TodoRow(store: store, id: child.id, identifierScope: "detail-") { openChild(child.id) }
            }
            if !isReadOnly {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "plus").foregroundStyle(.secondary)
                        .frame(width: TodoLayout.target, height: TodoLayout.target, alignment: .trailing)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + TodoLayout.baselineOffset() }
                        .accessibilityHidden(true)
                    TextField("todo.child.placeholder", text: $childTitle).textFieldStyle(.plain)
                        .focused($addingChild).onSubmit { addChild() }
                }.padding(.vertical, 2)
            }
        }
    }

    private var actions: some View {
        Menu {
            if task?.status == .pending {
                Button("todo.cancel_task", systemImage: "minus.square") {
                    var next = store.todos
                    next.setStatus(id, to: .cancelled)
                    store.updateTodos(next, undoManager: undoManager)
                }.disabled(isReadOnly).todoPointer(!isReadOnly)
            }
            if task?.status != .pending || isReadOnly {
                Button("todo.reopen", systemImage: "arrow.uturn.backward") {
                    var next = store.todos
                    next.setStatus(id, to: .pending)
                    store.updateTodos(next, undoManager: undoManager)
                }.todoPointer()
            }
            Button("todo.move") { showsMove = true }.disabled(isReadOnly).todoPointer(!isReadOnly)
            Button("todo.delete", systemImage: "trash", role: .destructive) {
                let parentID = task?.parentID
                var next = store.todos
                next.delete(id)
                store.updateTodos(next, undoManager: undoManager)
                store.openTodoID = parentID.flatMap { next.item($0)?.isDeleted == false ? $0 : nil }
            }.todoPointer()
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: TodoLayout.target, height: TodoLayout.target).contentShape(.rect)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(width: TodoLayout.target, height: TodoLayout.target).tint(.secondary)
        .todoPointer().help("todo.actions").accessibilityLabel("todo.actions")
    }

    @State private var destinationSearch = ""
    private var movePicker: some View {
        NavigationStack {
            List {
                Button("todo.view.inbox") { move(parentID: nil, projectID: nil) }.todoPointer()
                Section("todo.projects") {
                    ForEach(
                        store.todos.projects.filter {
                            destinationSearch.isEmpty || store.todos.projectTitle($0).localizedStandardContains(destinationSearch)
                        }
                    ) { project in
                        Button(store.todos.projectTitle(project)) { move(parentID: nil, projectID: project.id) }.todoPointer()
                    }
                }
                Section("todo.parent") {
                    ForEach(moveCandidates) { parent in
                        Button(store.todos.destinationTitle(parent)) { move(parentID: parent.id, projectID: parent.projectID) }
                            .todoPointer()
                    }
                }
            }
            .searchable(text: $destinationSearch, prompt: "todo.move.search")
            .navigationTitle("todo.move")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { showsMove = false }.todoPointer() } }
        }
        #if os(macOS)
            .frame(minWidth: 400, idealWidth: 500, minHeight: 360, idealHeight: 500)
        #endif
    }
    private var moveCandidates: [TodoItem] {
        let excluded = store.todos.descendants(of: id)
        return store.todos.items.filter {
            !excluded.contains($0.id) && !$0.isDeleted && !store.todos.isReadOnly($0.id)
                && (destinationSearch.isEmpty || store.todos.destinationTitle($0).localizedStandardContains(destinationSearch))
        }
    }

    private func properties(_ task: TodoItem) -> some View {
        let entries = task.schedule.sorted { $0.date < $1.date }
        return VStack(alignment: .leading, spacing: 8) {
            TodoPropertyLayout {
                if let first = entries.first {
                    Button {
                        openArrangement(first)
                    } label: {
                        Label(TodoText.arrangement(first), systemImage: "calendar")
                            .padding(.horizontal, 4).frame(minHeight: TodoLayout.target).contentShape(.rect)
                    }
                    .buttonStyle(.plain).disabled(isReadOnly).todoPointer(!isReadOnly)
                    .help("todo.schedule").accessibilityIdentifier("todo-property-schedule")
                    if entries.count > 1 {
                        Menu {
                            ForEach(entries) { entry in
                                if isReadOnly {
                                    Text(TodoText.arrangement(entry))
                                } else {
                                    Button(TodoText.arrangement(entry)) { openArrangement(entry) }
                                }
                            }
                        } label: {
                            Text("+\(entries.count - 1)")
                                .padding(.horizontal, 6).frame(minHeight: TodoLayout.target)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .frame(minHeight: TodoLayout.target).tint(.secondary)
                        .todoPointer().help("todo.schedule.more")
                        .accessibilityLabel("todo.schedule.more").accessibilityIdentifier("todo-property-more-schedule")
                    }
                }
                if task.deadline != nil { deadlineValue(task) }
                if !isReadOnly || entries.contains(where: { $0.reminder != nil }) {
                    reminderProperty(entries)
                }
                if !isReadOnly {
                    Menu {
                        Button("todo.slot.add", systemImage: "calendar.badge.plus") {
                            openArrangement(TodoArrangement(date: Calendar.current.startOfDay(for: .now)))
                        }
                        Button("todo.deadline", systemImage: "flag") { showsDeadline = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .frame(width: TodoLayout.target, height: TodoLayout.target).contentShape(.rect)
                    .tint(.secondary).todoPointer()
                    .help("todo.properties.add").accessibilityLabel("todo.properties.add")
                    .accessibilityIdentifier("todo-property-add")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            .popover(item: $editedArrangement, arrowEdge: .leading) { arrangementEditor($0) }
            .popover(isPresented: $showsDeadline, arrowEdge: .leading) {
                TodoDateEditor(
                    entry: TodoArrangement(date: task.deadline ?? Calendar.current.startOfDay(for: .now)), purpose: .deadline,
                    onDelete: task.deadline == nil ? nil : { edit(undoable: true) { $0.deadline = nil } }
                ) { value in
                    edit(undoable: true) { $0.deadline = Calendar.current.startOfDay(for: value.date) }
                }
            }
            if let error = store.todoReminderError {
                Label(error, systemImage: "bell.slash").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reminderProperty(_ entries: [TodoArrangement]) -> some View {
        let reminderSummary = entries.compactMap(\.reminder)
            .map { $0.formatted(date: .abbreviated, time: .shortened) }.joined(separator: "\n")
        return Group {
            if entries.count <= 1 {
                Button {
                    openArrangement(entries.first ?? TodoArrangement(date: Calendar.current.startOfDay(for: .now)), forReminder: true)
                } label: {
                    Image(systemName: reminderSummary.isEmpty ? "bell" : "bell.badge")
                        .frame(width: TodoLayout.target, height: TodoLayout.target).contentShape(.rect)
                }.buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(entries) { entry in
                        Button(TodoText.arrangement(entry)) { openArrangement(entry, forReminder: true) }
                    }
                } label: {
                    Image(systemName: reminderSummary.isEmpty ? "bell" : "bell.badge")
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .frame(width: TodoLayout.target, height: TodoLayout.target).contentShape(.rect).tint(.secondary)
            }
        }
        .disabled(isReadOnly).todoPointer(!isReadOnly)
        .help(reminderSummary.isEmpty ? L10n.string("todo.reminder") : L10n.string("todo.reminder") + "\n" + reminderSummary)
        .accessibilityLabel("todo.reminder").accessibilityValue(reminderSummary)
        .accessibilityIdentifier("todo-property-reminder")
    }

    private func openArrangement(_ entry: TodoArrangement, forReminder: Bool = false) {
        editsReminder = forReminder
        editedArrangement = entry
    }

    private func arrangementEditor(_ entry: TodoArrangement) -> some View {
        TodoDateEditor(
            entry: entry, purpose: .arrangement, initialField: editsReminder ? .reminder : .start,
            onDelete: task?.schedule.contains(where: { $0.id == entry.id }) == true
                ? { edit(undoable: true) { $0.schedule.removeAll { $0.id == entry.id } } } : nil
        ) { value in
            edit(undoable: true) { task in
                if let index = task.schedule.firstIndex(where: { $0.id == value.id }) {
                    task.schedule[index] = value
                } else {
                    task.schedule.append(value)
                }
            }
        }
    }

    private func deadlineValue(_ task: TodoItem) -> some View {
        Button {
            showsDeadline = true
        } label: {
            Label(task.deadline.map { TodoText.date("todo.deadline.summary", $0) } ?? "", systemImage: "flag")
                .padding(.horizontal, 4).frame(minHeight: TodoLayout.target).contentShape(.rect)
        }
        .buttonStyle(.plain).disabled(isReadOnly).todoPointer(!isReadOnly)
        .help("todo.deadline").accessibilityIdentifier("todo-deadline")
    }

    private func addChild() {
        var next = store.todos
        guard next.create(title: childTitle, parentID: id) != nil else { return }
        store.updateTodos(next, undoManager: undoManager)
        childTitle = ""
        addingChild = true
    }
    private func move(parentID: UUID?, projectID: UUID?) {
        var next = store.todos
        guard next.move(id, parentID: parentID, projectID: projectID) else { return }
        store.updateTodos(next, undoManager: undoManager)
        showsMove = false
    }
    private func edit(undoable: Bool = false, _ change: (inout TodoItem) -> Void) {
        var next = store.todos
        next.update(id, edit: change)
        store.updateTodos(next, undoManager: undoable ? undoManager : nil)
    }
}

private struct TodoSaveStatus: View {
    let store: NoteStore
    var body: some View {
        if let error = store.saveError {
            HStack {
                Label(L10n.unsaved(error), systemImage: "exclamationmark.triangle").font(.caption)
                Spacer()
                Button("common.retry") { store.retrySave() }.todoPointer()
            }.padding().background(.bar)
        }
    }
}

private struct TodoPointer: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let enabled: Bool
    func body(content: Content) -> some View {
        #if os(macOS)
            content.pointerStyle(enabled && isEnabled ? .link : .default)
        #else
            content.hoverEffect(.highlight, isEnabled: enabled && isEnabled)
        #endif
    }
}

extension View {
    fileprivate func todoPointer(_ enabled: Bool = true) -> some View { modifier(TodoPointer(enabled: enabled)) }
}

private enum TodoText {
    static func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return L10n.string("todo.date.today") }
        if Calendar.current.isDateInTomorrow(date) { return L10n.string("todo.date.tomorrow") }
        if Calendar.current.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month().day().locale(L10n.language.locale))
        }
        return date.formatted(.dateTime.year().month().day().locale(L10n.language.locale))
    }

    static func arrangement(_ entry: TodoArrangement) -> String {
        guard let end = entry.end else { return day(entry.date) }
        let start = entry.date.formatted(date: .omitted, time: .shortened)
        let finish = end.formatted(date: Calendar.current.isDate(entry.date, inSameDayAs: end) ? .omitted : .abbreviated, time: .shortened)
        return day(entry.date) + " " + start + "–" + finish
    }

    static func format(_ key: String.LocalizationValue, _ value: any CVarArg) -> String {
        String(format: L10n.string(key), locale: L10n.language.locale, arguments: [value])
    }
    static func date(_ key: String.LocalizationValue, _ date: Date) -> String {
        format(key, date.formatted(.dateTime.month().day().locale(L10n.language.locale)))
    }
}

private enum TodoDatePurpose {
    case arrangement, deadline
    var title: LocalizedStringKey { self == .arrangement ? "todo.schedule" : "todo.deadline" }
}

private enum TodoDateField: String {
    case start, end, reminder
}

private struct TodoDateEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entry: TodoArrangement
    @State private var wantsReminder: Bool
    @State private var reminderReady = false
    @State private var reminderError: String?
    @State private var selectedDate: TodoDateField = .start
    @State private var rangeSelection = TodoCalendarRangeSelection()
    @State private var contentHeight: CGFloat = 0
    let purpose: TodoDatePurpose
    let onDelete: (() -> Void)?
    let onSave: (TodoArrangement) -> Void

    init(
        entry: TodoArrangement, purpose: TodoDatePurpose, initialField: TodoDateField = .start,
        onDelete: (() -> Void)? = nil, onSave: @escaping (TodoArrangement) -> Void
    ) {
        _entry = State(initialValue: entry)
        _wantsReminder = State(initialValue: entry.reminder != nil || initialField == .reminder)
        _selectedDate = State(initialValue: initialField)
        self.purpose = purpose
        self.onDelete = onDelete
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(purpose.title).font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").foregroundStyle(.secondary)
                        .frame(width: TodoLayout.target, height: TodoLayout.target)
                }.buttonStyle(.plain).todoPointer().help("common.cancel").accessibilityLabel("common.cancel")
            }.padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4)
            #if os(macOS)
                ScrollView {
                    editorContent
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            contentHeight = $0
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(500, contentHeight))
            #else
                ScrollView { editorContent }.scrollBounceBehavior(.basedOnSize)
            #endif
            Divider().padding(.horizontal, 18)
            HStack(spacing: 8) {
                if let onDelete {
                    Button(role: .destructive) {
                        onDelete()
                        dismiss()
                    } label: {
                        Image(systemName: "trash").frame(width: TodoLayout.target, height: TodoLayout.target).contentShape(.rect)
                    }
                    .buttonStyle(.plain).todoPointer()
                    .help(purpose == .deadline ? "todo.deadline.remove" : "todo.slot.remove")
                    .accessibilityLabel(purpose == .deadline ? "todo.deadline.remove" : "todo.slot.remove")
                    .accessibilityIdentifier("todo-date-remove")
                }
                Button("common.cancel") { dismiss() }
                    .buttonStyle(.bordered).keyboardShortcut(.cancelAction).todoPointer()
                Spacer()
                Button("common.done") {
                    if !wantsReminder { entry.reminder = nil }
                    onSave(entry)
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).todoPointer()
                    .disabled((wantsReminder && !reminderReady) || (entry.end != nil && rangeSelection.isIncomplete))
            }.controlSize(.regular).buttonBorderShape(.roundedRectangle(radius: 6))
                .padding(.horizontal, 18).padding(.vertical, 14)
        }
        .background(TodoLayout.canvas)
        .presentationBackground(TodoLayout.canvas)
        #if os(macOS)
            .frame(width: 336).fixedSize(horizontal: false, vertical: true)
        #else
            .frame(idealWidth: 360)
            .presentationDetents([.large])
        #endif
        .environment(\.locale, L10n.language.locale)
        .onChange(of: wantsReminder) { _, enabled in
            if !enabled && selectedDate == .reminder { selectedDate = .start }
        }
        .task(id: wantsReminder) {
            reminderError = nil
            reminderReady = false
            guard wantsReminder else { return }
            do {
                let granted = try await TodoNotifications.requestAuthorization()
                guard !Task.isCancelled else { return }
                reminderReady = granted
                if granted { entry.reminder = entry.reminder ?? entry.date } else { reminderError = L10n.string("todo.reminder.denied") }
            } catch {
                guard !Task.isCancelled else { return }
                reminderError = error.localizedDescription
            }
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            calendarContent
            if purpose == .arrangement {
                Divider()
                VStack(spacing: 4) {
                    Toggle(isOn: durationEnabled) { Text("todo.time_range").frame(maxWidth: .infinity, alignment: .leading) }
                        .toggleStyle(.switch).todoPointer().frame(minHeight: TodoLayout.target)
                    if let end = entry.end {
                        dateTimeRow(.start, title: "todo.slot.start", date: entry.date, binding: startDate)
                        dateTimeRow(.end, title: "todo.slot.end", date: end, binding: endDate)
                    }
                }
                Divider()
                reminderRow
                if wantsReminder {
                    dateTimeRow(.reminder, title: "todo.reminder.time", date: reminderDate.wrappedValue, binding: reminderDate)
                    if let reminderError { Text(reminderError).font(.caption).foregroundStyle(.red) }
                }
            }
        }.padding(.horizontal, 18).padding(.bottom, 14)
    }

    private func dateTimeRow(_ field: TodoDateField, title: LocalizedStringKey, date: Date, binding: Binding<Date>) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text(title).fixedSize()
                Spacer(minLength: 8)
                dateButton(field, date: date)
                TodoTimeField(title: title, field: field, date: binding)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    dateButton(field, date: date)
                    TodoTimeField(title: title, field: field, date: binding)
                }
            }
        }.frame(minHeight: TodoLayout.target)
    }

    private var calendarContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            TodoDateCalendar(date: calendarDate, range: calendarRange, onRangeSelection: rangeDayAction)
                .id(selectedDate)
            if calendarRange != nil {
                Text(
                    rangeSelection.anchor == nil
                        ? LocalizedStringKey("todo.range.select_start") : LocalizedStringKey("todo.range.select_end")
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var rangeDayAction: ((Date) -> Void)? {
        guard calendarRange != nil else { return nil }
        return { day in selectRangeDay(day) }
    }

    private var reminderRow: some View {
        HStack(spacing: 8) {
            Label("todo.reminder", systemImage: "bell").foregroundStyle(.primary)
            Spacer(minLength: 8)
            Menu {
                Button("todo.reminder.none") { wantsReminder = false }
                Button("todo.reminder.custom") {
                    wantsReminder = true
                    selectedDate = .reminder
                }
            } label: {
                Text(wantsReminder ? TodoText.day(reminderDate.wrappedValue) : L10n.string("todo.reminder.none"))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary).todoPointer()
                .accessibilityLabel("todo.reminder")
                .accessibilityValue(wantsReminder ? TodoText.day(reminderDate.wrappedValue) : L10n.string("todo.reminder.none"))
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
        }.frame(minHeight: TodoLayout.target)
    }

    private var calendarRange: ClosedRange<Date>? {
        guard purpose == .arrangement, selectedDate != .reminder, let end = entry.end else { return nil }
        let startDay = Calendar.current.startOfDay(for: entry.date)
        return startDay...max(startDay, Calendar.current.startOfDay(for: end))
    }

    private func selectRangeDay(_ day: Date) {
        var start = entry.date
        var end = entry.end ?? start.addingTimeInterval(3600)
        rangeSelection.select(day, start: &start, end: &end, calendar: .current)
        entry.date = start
        entry.end = end
    }

    private var calendarDate: Binding<Date> {
        switch selectedDate {
        case .start: startDate
        case .end: endDate
        case .reminder: reminderDate
        }
    }

    private func dateButton(_ field: TodoDateField, date: Date) -> some View {
        Button {
            selectedDate = field
            if field == .start { rangeSelection.prepareToSelectStart() }
            if field == .end { rangeSelection.prepareToSelectEnd(start: entry.date) }
        } label: {
            Text(TodoText.day(date)).font(.callout).fixedSize()
                .foregroundStyle(selectedDate == field ? AppTheme.accent : .primary)
                .padding(.horizontal, 4).frame(minHeight: TodoLayout.target)
                .background(selectedDate == field ? AppTheme.accent.opacity(0.07) : .clear, in: .rect(cornerRadius: 6))
                .contentShape(.rect)
        }.buttonStyle(.plain).todoPointer()
            .accessibilityIdentifier("todo-date-field-" + field.rawValue)
            .accessibilityLabel(
                Text(field == .start ? "todo.slot.start" : field == .end ? "todo.slot.end" : "todo.reminder.time")
                    + Text(" " + TodoText.day(date)))
    }

    private var startDate: Binding<Date> {
        Binding(
            get: { entry.date },
            set: { value in
                let duration = entry.end.map { $0.timeIntervalSince(entry.date) }
                entry.date = value
                if let duration { entry.end = value.addingTimeInterval(duration) }
            })
    }

    private var endDate: Binding<Date> {
        Binding(
            get: { entry.end ?? entry.date.addingTimeInterval(3600) },
            set: { entry.end = max($0, entry.date.addingTimeInterval(60)) })
    }

    private var reminderDate: Binding<Date> {
        Binding(get: { entry.reminder ?? entry.date }, set: { entry.reminder = $0 })
    }

    private var durationEnabled: Binding<Bool> {
        Binding(
            get: { entry.end != nil },
            set: { enabled in
                if enabled {
                    entry.date = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: entry.date) ?? entry.date
                    entry.end = entry.date.addingTimeInterval(3600)
                } else {
                    entry.date = Calendar.current.startOfDay(for: entry.date)
                    entry.end = nil
                    if selectedDate == .end { selectedDate = .start }
                    rangeSelection = TodoCalendarRangeSelection()
                }
            })
    }
}

/// Calendar arithmetic is independent of view state, including month boundaries and DST.
struct TodoCalendarMonth {
    let calendar: Calendar
    let start: Date
    let days: [Date]

    init(containing date: Date, calendar: Calendar) {
        self.calendar = calendar
        let start = calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        self.start = start
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: start)?.count ?? 0
        let cellCount = ((offset + count + 6) / 7) * 7
        days = (0..<cellCount).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: start) }
    }

    static func selecting(_ day: Date, preservingTimeOf date: Date, calendar: Calendar) -> Date {
        let time = calendar.dateComponents([.hour, .minute, .second], from: date)
        return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day) ?? day
    }
}

struct TodoCalendarRangeSelection {
    private(set) var anchor: Date?
    private(set) var isIncomplete = false

    init(anchor: Date? = nil) { self.anchor = anchor }

    // Switching the visible field must not discard an unfinished two-click range.
    mutating func prepareToSelectStart() {
        if !isIncomplete { anchor = nil }
    }

    mutating func prepareToSelectEnd(start: Date) {
        if !isIncomplete { anchor = start }
    }

    mutating func select(_ day: Date, start: inout Date, end: inout Date, calendar: Calendar) {
        let day = calendar.startOfDay(for: day)
        if let anchor, day >= calendar.startOfDay(for: anchor) {
            end = max(TodoCalendarMonth.selecting(day, preservingTimeOf: end, calendar: calendar), start.addingTimeInterval(60))
            self.anchor = nil
            isIncomplete = false
        } else {
            start = TodoCalendarMonth.selecting(day, preservingTimeOf: start, calendar: calendar)
            end = max(TodoCalendarMonth.selecting(day, preservingTimeOf: end, calendar: calendar), start.addingTimeInterval(60))
            anchor = day
            isIncomplete = true
        }
    }
}

private struct TodoDateCalendar: View {
    @Binding var date: Date
    var range: ClosedRange<Date>?
    var onRangeSelection: ((Date) -> Void)?
    @Environment(\.calendar) private var systemCalendar
    @Environment(\.locale) private var locale
    @State private var visibleMonth: Date
    @State private var cursorDate: Date
    @FocusState private var gridFocused: Bool
    @ScaledMetric(relativeTo: .body) private var daySize: CGFloat = 32

    init(date: Binding<Date>, range: ClosedRange<Date>? = nil, onRangeSelection: ((Date) -> Void)? = nil) {
        _date = date
        self.range = range
        self.onRangeSelection = onRangeSelection
        _visibleMonth = State(initialValue: date.wrappedValue)
        _cursorDate = State(initialValue: date.wrappedValue)
    }

    private var calendar: Calendar {
        var calendar = systemCalendar
        calendar.locale = locale
        calendar.firstWeekday = 2
        return calendar
    }
    private var month: TodoCalendarMonth { TodoCalendarMonth(containing: visibleMonth, calendar: calendar) }
    private var cellHeight: CGFloat { max(TodoLayout.target, daySize + 2) }
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 28) {
                shortcut("todo.date.today", day: calendar.startOfDay(for: .now))
                shortcut("todo.date.tomorrow", day: calendar.date(byAdding: .day, value: 1, to: .now) ?? .now)
                shortcut(
                    "todo.date.next_week",
                    day: calendar.nextDate(after: .now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) ?? .now)
                Spacer(minLength: 0)
            }.padding(.bottom, 6)
            HStack {
                Text(monthTitle)
                    .font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                monthButton(-1, symbol: "chevron.left", label: "todo.date.previous_month")
                monthButton(1, symbol: "chevron.right", label: "todo.date.next_month")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 24)
                        .accessibilityHidden(true)
                }
                ForEach(month.days, id: \.self) { day in dayButton(day) }
            }
            .focusable().focusEffectDisabled().focused($gridFocused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let offset = press.key == .leftArrow ? -1 : press.key == .rightArrow ? 1 : press.key == .upArrow ? -7 : 7
                guard let day = calendar.date(byAdding: .day, value: offset, to: cursorDate) else { return .handled }
                cursorDate = day
                visibleMonth = day
                if range == nil { selectDay(day) }
                return .handled
            }
            .onKeyPress(.space) {
                selectDay(cursorDate)
                return .handled
            }
            .onKeyPress(.return) {
                guard range != nil else { return .ignored }
                selectDay(cursorDate)
                return .handled
            }
            .accessibilityIdentifier("todo-date-calendar")
        }
        .onChange(of: date) { _, value in
            cursorDate = value
            if !calendar.isDate(value, equalTo: visibleMonth, toGranularity: .month) { visibleMonth = value }
        }
    }

    private var monthTitle: String {
        var style = Date.FormatStyle.dateTime.year().month(.wide).locale(locale)
        style.calendar = calendar
        return month.start.formatted(style)
    }

    private var dayLabelStyle: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.year().month().day().weekday(.wide).locale(locale)
        style.calendar = calendar
        return style
    }

    private func dayIdentifier(_ day: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        return "todo-day-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    private func dayButton(_ day: Date) -> some View {
        let first = range.map { calendar.isDate(day, inSameDayAs: $0.lowerBound) } ?? false
        let last = range.map { calendar.isDate(day, inSameDayAs: $0.upperBound) } ?? false
        let selected = range == nil ? calendar.isDate(day, inSameDayAs: date) : first || last
        let inRange = range.map { $0.contains(calendar.startOfDay(for: day)) } ?? false
        let inMonth = calendar.isDate(day, equalTo: month.start, toGranularity: .month)
        let today = calendar.isDateInToday(day)
        return Button {
            selectDay(day)
            gridFocused = true
        } label: {
            Text(calendar.component(.day, from: day).formatted())
                .monospacedDigit()
                .foregroundStyle(selected ? Color.white : today ? AppTheme.accent : inMonth ? .primary : .secondary)
                .frame(width: daySize, height: daySize)
                .background(selected ? AppTheme.accent : .clear, in: .circle)
                .overlay {
                    if calendar.isDate(day, inSameDayAs: cursorDate) && gridFocused {
                        Circle().strokeBorder(AppTheme.accent.opacity(0.25), lineWidth: 2)
                            .frame(width: daySize + 6, height: daySize + 6)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: cellHeight).contentShape(.rect)
                .background {
                    if inRange && !(first && last) {
                        GeometryReader { geometry in
                            Rectangle().fill(AppTheme.accent.opacity(0.14))
                                .frame(width: first || last ? geometry.size.width / 2 : geometry.size.width, height: daySize)
                                .offset(x: first ? geometry.size.width / 2 : 0, y: (cellHeight - daySize) / 2)
                        }
                    }
                }
        }.buttonStyle(.plain).todoPointer().focusable(false)
            .accessibilityLabel(day.formatted(dayLabelStyle))
            .accessibilityValue(
                inRange
                    ? L10n.string(first ? "todo.range.start" : last ? "todo.range.end" : "todo.range.inside")
                    : today ? L10n.string("todo.date.today") : ""
            )
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityRemoveTraits(selected ? [] : .isSelected)
            .accessibilityIdentifier(dayIdentifier(day))
    }

    private func monthButton(_ offset: Int, symbol: String, label: LocalizedStringKey) -> some View {
        Button {
            visibleMonth = calendar.date(byAdding: .month, value: offset, to: month.start) ?? month.start
            let newMonth = TodoCalendarMonth(containing: visibleMonth, calendar: calendar)
            let ordinal = min(
                calendar.component(.day, from: cursorDate), calendar.range(of: .day, in: .month, for: newMonth.start)?.count ?? 1)
            cursorDate = calendar.date(byAdding: .day, value: ordinal - 1, to: newMonth.start) ?? newMonth.start
        } label: {
            Image(systemName: symbol).font(.body).frame(width: 28, height: TodoLayout.target).contentShape(.rect)
        }.buttonStyle(.plain).todoPointer().help(label).accessibilityLabel(label)

    }

    private func selectDay(_ day: Date) {
        if let onRangeSelection {
            onRangeSelection(day)
        } else {
            date = TodoCalendarMonth.selecting(day, preservingTimeOf: date, calendar: calendar)
        }
        cursorDate = day
        visibleMonth = day
    }

    private func shortcut(_ title: LocalizedStringKey, day: Date) -> some View {
        Button(title) { selectDay(day) }
            .buttonStyle(.plain).todoPointer().frame(minHeight: TodoLayout.target)
            .foregroundStyle(calendar.isDate(day, inSameDayAs: date) ? AppTheme.accent : .secondary)

    }
}

private struct TodoTimeField: View {
    let title: LocalizedStringKey
    let field: TodoDateField
    @Binding var date: Date
    @ScaledMetric(relativeTo: .body) private var componentWidth: CGFloat = 52

    var body: some View {
        HStack(spacing: 2) {
            Picker(selection: component(.hour)) {
                ForEach(0..<24) { hour in Text(String(format: "%02d", hour)).tag(hour) }
            } label: {
                Text(title) + Text(" ") + Text("todo.time.hour")
            }
            .frame(width: componentWidth).accessibilityIdentifier("todo-hour-picker-" + field.rawValue)
            Text(":").foregroundStyle(.secondary).accessibilityHidden(true)
            Picker(selection: component(.minute)) {
                ForEach(0..<60) { minute in Text(String(format: "%02d", minute)).tag(minute) }
            } label: {
                Text(title) + Text(" ") + Text("todo.time.minute")
            }
            .frame(width: componentWidth).accessibilityIdentifier("todo-minute-picker-" + field.rawValue)
        }.pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize().todoPointer()
    }

    private func component(_ component: Calendar.Component) -> Binding<Int> {
        Binding(
            get: { Calendar.current.component(component, from: date) },
            set: { value in
                let clock = Calendar.current.dateComponents([.hour, .minute], from: date)
                date =
                    Calendar.current.date(
                        bySettingHour: component == .hour ? value : clock.hour ?? 0,
                        minute: component == .minute ? value : clock.minute ?? 0,
                        second: 0, of: date) ?? date
            })
    }
}

#if os(macOS)
    /// A native editor whose hit region follows rendered lines, leaving row whitespace to the detail button.
    private struct TodoInlineTitle: NSViewRepresentable {
        let title: String
        let displayTitle: String
        let isReadOnly: Bool
        let isCompleted: Bool
        let lineLimit: Int?
        @Binding var draft: String?
        let onCommit: (String) -> Void

        func makeNSView(context: Context) -> TodoTitleTextView {
            let view = TodoTitleTextView()
            view.drawsBackground = false
            view.isRichText = false
            view.isVerticallyResizable = true
            view.textContainerInset = .zero
            view.textContainer?.lineFragmentPadding = 0
            view.allowsUndo = true
            view.setAccessibilityLabel(L10n.string("todo.title"))
            return view
        }

        func updateNSView(_ view: TodoTitleTextView, context: Context) {
            view.onDraft = { draft = $0 }
            view.onCommit = onCommit
            view.onCancel = { draft = nil }
            view.originalTitle = title
            view.isEditable = !isReadOnly
            view.isSelectable = !isReadOnly
            view.lineLimit = lineLimit
            if !view.isEditingTitle {
                view.string = displayTitle
                view.font = .preferredFont(forTextStyle: .body)
                view.textColor = .labelColor
                if isCompleted {
                    view.textStorage?.addAttribute(
                        .strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                        range: NSRange(location: 0, length: view.string.utf16.count))
                }
                view.textContainer?.maximumNumberOfLines = lineLimit ?? 0
                view.textContainer?.lineBreakMode = .byTruncatingTail
            }
            view.toolTip = displayTitle
        }

        func sizeThatFits(_ proposal: ProposedViewSize, nsView: TodoTitleTextView, context: Context) -> CGSize? {
            let width = max(1, proposal.width ?? 300)
            nsView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
            guard let layout = nsView.layoutManager, let container = nsView.textContainer else { return nil }
            layout.ensureLayout(for: container)
            let height = max(layout.defaultLineHeight(for: .preferredFont(forTextStyle: .body)), layout.usedRect(for: container).height)
            return CGSize(width: width, height: ceil(height))
        }
    }

    final class TodoTitleTextView: NSTextView {
        var originalTitle = ""
        var lineLimit: Int?
        private(set) var isEditingTitle = false
        var onDraft: ((String) -> Void)?
        var onCommit: ((String) -> Void)?
        var onCancel: (() -> Void)?
        private var cancelsEditing = false
        private let titleUndoManager = UndoManager()
        override var undoManager: UndoManager? { titleUndoManager }

        func titleRects() -> [CGRect] {
            guard let layoutManager, let textContainer else { return [] }
            layoutManager.ensureLayout(for: textContainer)
            var rects: [CGRect] = []
            layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: textContainer)) { _, used, _, _, _ in
                rects.append(used.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y))
            }
            if string.isEmpty {
                rects.append(CGRect(x: textContainerOrigin.x, y: textContainerOrigin.y, width: 8, height: font?.pointSize ?? 17))
            }
            return rects
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            guard isEditable, titleRects().contains(where: { $0.contains(local) }) else { return nil }
            return super.hitTest(point)
        }

        override func resetCursorRects() {
            for rect in titleRects() { addCursorRect(rect, cursor: .iBeam) }
        }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            if !isEditingTitle {
                isEditingTitle = true
                string = originalTitle
                textContainer?.maximumNumberOfLines = 0
                textContainer?.lineBreakMode = .byWordWrapping
                invalidateIntrinsicContentSize()
                typingAttributes = [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor]
                onDraft?(string)
            }
            return true
        }

        override func didChangeText() {
            super.didChangeText()
            onDraft?(string)
            invalidateIntrinsicContentSize()
            window?.invalidateCursorRects(for: self)
        }

        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            if isEditingTitle {
                let title = string
                isEditingTitle = false
                undoManager?.removeAllActions()
                if cancelsEditing {
                    cancelsEditing = false
                    string = originalTitle
                    onCancel?()
                } else {
                    onCommit?(title)
                }
            }
            return true
        }

        override func insertNewline(_ sender: Any?) {
            // The input manager consumes candidate-confirmation Return before this command reaches us.
            guard !hasMarkedText() else { return }
            window?.makeFirstResponder(nil)
        }

        override func cancelOperation(_ sender: Any?) {
            if hasMarkedText() {
                super.cancelOperation(sender)
                return
            }
            cancelsEditing = true
            window?.makeFirstResponder(nil)
        }
    }
#else
    private struct TodoInlineTitle: UIViewRepresentable {
        let title: String
        let displayTitle: String
        let isReadOnly: Bool
        let isCompleted: Bool
        let lineLimit: Int?
        @Binding var draft: String?
        let onCommit: (String) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(self) }

        func makeUIView(context: Context) -> TodoTitleTextView {
            let view = TodoTitleTextView()
            view.backgroundColor = .clear
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            view.isScrollEnabled = false
            view.delegate = context.coordinator
            view.accessibilityLabel = L10n.string("todo.title")
            return view
        }

        func updateUIView(_ view: TodoTitleTextView, context: Context) {
            context.coordinator.owner = self
            view.isEditable = !isReadOnly
            view.isSelectable = !isReadOnly
            view.onCancel = { draft = nil }
            view.originalTitle = title
            if !view.isFirstResponder {
                view.attributedText = NSAttributedString(
                    string: displayTitle,
                    attributes: [
                        .font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.label,
                        .strikethroughStyle: isCompleted ? NSUnderlineStyle.single.rawValue : 0,
                    ])
                view.textContainer.maximumNumberOfLines = lineLimit ?? 0
                view.textContainer.lineBreakMode = .byTruncatingTail
            }
        }

        func sizeThatFits(_ proposal: ProposedViewSize, uiView: TodoTitleTextView, context: Context) -> CGSize? {
            let width = max(1, proposal.width ?? 300)
            return CGSize(width: width, height: ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
        }

        final class Coordinator: NSObject, UITextViewDelegate {
            var owner: TodoInlineTitle
            init(_ owner: TodoInlineTitle) { self.owner = owner }
            func textViewDidBeginEditing(_ textView: UITextView) {
                textView.text = owner.title
                textView.textContainer.maximumNumberOfLines = 0
                textView.textContainer.lineBreakMode = .byWordWrapping
                owner.draft = textView.text
            }
            func textViewDidChange(_ textView: UITextView) { owner.draft = textView.text }
            func textViewDidEndEditing(_ textView: UITextView) {
                if let titleView = textView as? TodoTitleTextView, titleView.cancelsEditing {
                    titleView.cancelsEditing = false
                    owner.draft = nil
                } else {
                    owner.onCommit(textView.text)
                }
            }
            func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
                if text == "\n", textView.markedTextRange == nil {
                    textView.resignFirstResponder()
                    return false
                }
                return true
            }
        }
    }

    private final class TodoTitleTextView: UITextView {
        var originalTitle = ""
        var cancelsEditing = false
        var onCancel: (() -> Void)?

        override var keyCommands: [UIKeyCommand]? {
            (super.keyCommands ?? []) + [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelTitle))]
        }

        @objc private func cancelTitle() {
            guard markedTextRange == nil else {
                unmarkText()
                return
            }
            cancelsEditing = true
            text = originalTitle
            resignFirstResponder()
            onCancel?()
        }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard isEditable else { return false }
            layoutManager.ensureLayout(for: textContainer)
            var containsText = false
            layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: textContainer)) { _, used, _, _, _ in
                if used.offsetBy(dx: self.textContainerInset.left, dy: self.textContainerInset.top).contains(point) { containsText = true }
            }
            return containsText || (text.isEmpty && point.x < 8 && bounds.contains(point))
        }
    }
#endif
