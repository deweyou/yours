#if os(iOS)
    import SwiftUI
    import UniformTypeIdentifiers

    private enum MobileLibrary: Hashable {
        case recent, all, unfiled, tasks, settings
        case folder(UUID)
        case document(UUID)

        var folderID: UUID? {
            if case .folder(let id) = self { return id }
            return nil
        }
    }

    struct MobileWorkspaceView: View {
        @Bindable var store: NoteStore
        @State private var library: MobileLibrary?
        @State private var path: [UUID] = []
        @State private var compactColumn: NavigationSplitViewColumn = .sidebar
        @State private var query = ""
        @State private var expandedFolders: Set<UUID> = []
        @State private var showsFolderEditor = false
        @State private var editingFolderID: UUID?
        @State private var folderName = ""
        @State private var galleryScroll = RecordGalleryScrollState()
        @State private var movingNote: Note?
        @State private var showsImport = false
        @State private var importFromSidebar = false
        @State private var importError: String?

        private var activeFolderID: UUID? {
            if case .document(let id) = library { return store.notes.first(where: { $0.id == id })?.folderID }
            return library?.folderID
        }

        private var isEditing: Bool {
            if case .document = library { return true }
            return !path.isEmpty
        }

        private var title: String {
            switch library ?? .all {
            case .recent: L10n.string("note.recent")
            case .all: L10n.string("navigation.notes")
            case .unfiled: L10n.string("folder.unfiled")
            case .tasks: L10n.string("navigation.tasks")
            case .settings: L10n.string("settings.title")
            case .document(let id): store.notes.first(where: { $0.id == id })?.displayTitle ?? L10n.string("navigation.notes")
            case .folder(let id): store.folders.first(where: { $0.id == id })?.name ?? L10n.string("folder.title")
            }
        }

        private var notes: [Note] {
            store.notes.filter { note in
                let matches: Bool
                switch library ?? .all {
                case .recent, .all: matches = true
                case .unfiled: matches = note.folderID == nil
                case .folder(let id): matches = note.folderID == id
                case .tasks, .settings, .document: matches = false
                }
                return matches
                    && (query.isEmpty || note.title.localizedStandardContains(query) || note.text.localizedStandardContains(query))
            }.sorted { $0.updatedAt > $1.updatedAt }
        }

        var body: some View {
            // Keep one split/stack hierarchy across size changes so an active editor
            // is not replaced when iPad changes between wide and compact layouts.
            NavigationSplitView(preferredCompactColumn: $compactColumn) {
                sidebar
                    .navigationTitle("Yours")
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
            } detail: {
                NavigationStack(path: $path) {
                    libraryContent
                        .navigationTitle(title)
                        .navigationDestination(for: UUID.self) { id in
                            editor(id)
                        }
                }
            }
            .navigationSplitViewStyle(.balanced)
            .onChange(of: query) { _, _ in galleryScroll.reset() }
            .alert(editingFolderID == nil ? L10n.string("folder.create") : L10n.string("folder.rename"), isPresented: $showsFolderEditor) {
                TextField("folder.name", text: $folderName).accessibilityIdentifier("folder-name")
                Button("common.cancel", role: .cancel) {}
                Button("common.save") {
                    if let editingFolderID {
                        store.renameFolder(id: editingFolderID, name: folderName)
                    } else if let id = store.createFolder(name: folderName) {
                        select(.folder(id))
                        compactColumn = .detail
                    }
                }
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .sheet(item: $movingNote) { note in
                NavigationStack {
                    List {
                        moveDestination(L10n.string("folder.unfiled"), folderID: nil, note: note)
                        ForEach(store.folders) { folder in
                            moveDestination(folder.name, folderID: folder.id, note: note)
                        }
                    }
                    .navigationTitle(L10n.string("folder.move"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { movingNote = nil } }
                    }
                }
                .presentationDetents([.medium, .large])
            }
            .fileImporter(isPresented: $showsImport, allowedContentTypes: [MarkdownFile.contentType, .plainText]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let source = try String(contentsOf: url, encoding: .utf8)
                    prepareNewNote()
                    store.createNote(
                        title: url.deletingPathExtension().lastPathComponent,
                        richText: MarkdownFormatting.render(source), folderID: activeFolderID
                    )
                    openCreatedNote(fromSidebar: importFromSidebar)
                } catch { importError = error.localizedDescription }
            }
            .alert("markdown.import_failed", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("common.ok") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isEditing, let error = store.saveError {
                    HStack {
                        Label(L10n.unsaved(error), systemImage: "exclamationmark.triangle")
                        Button("common.retry") { store.retrySave() }
                    }.font(.callout).padding().background(.bar)
                }
            }
        }

        private var sidebar: some View {
            List(selection: Binding(get: { library }, set: { select($0) })) {
                Section {
                    NavigationLink(value: MobileLibrary.all) { Label("navigation.notes", systemImage: "note.text") }
                        .accessibilityIdentifier("workspace-notes")
                    NavigationLink(value: MobileLibrary.tasks) {
                        HStack {
                            Label("navigation.tasks", systemImage: "checklist")
                            Spacer()

                        }
                    }
                    .accessibilityIdentifier("workspace-tasks")
                    NavigationLink(value: MobileLibrary.settings) { Label("settings.title", systemImage: "gearshape") }
                        .accessibilityIdentifier("workspace-settings")
                }
                if library != .tasks && library != .settings {
                    Section("navigation.notes") {
                        libraryLink(L10n.string("note.recent"), symbol: "clock", destination: .recent)
                        libraryLink(L10n.string("note.all"), symbol: "tray.full", destination: .all)
                        libraryLink(L10n.string("folder.unfiled"), symbol: "tray", destination: .unfiled)
                    }
                    Section("folder.title") {
                        ForEach(store.folders) { folder in
                            DisclosureGroup(
                                isExpanded: Binding(
                                    get: { expandedFolders.contains(folder.id) },
                                    set: { if $0 { expandedFolders.insert(folder.id) } else { expandedFolders.remove(folder.id) } }
                                )
                            ) {
                                ForEach(store.notes.filter { $0.folderID == folder.id }) { note in
                                    Button {
                                        select(.document(note.id))
                                        compactColumn = .detail
                                    } label: {
                                        Label(note.displayTitle, systemImage: "doc.text").lineLimit(1)
                                    }
                                    .contextMenu { noteActions(note) }
                                }
                            } label: {
                                libraryLink(folder.name, symbol: "folder", destination: .folder(folder.id))
                                    .contextMenu {
                                        Button("common.rename", systemImage: "pencil") { editFolder(folder) }
                                    }
                            }
                        }
                        Button("folder.create", systemImage: "folder.badge.plus") { editFolder(nil) }
                            .accessibilityIdentifier("new-folder")
                            .disabled(store.loadError != nil)
                    }
                }
            }
            .listStyle(.sidebar)
            .toolbar { libraryToolbar(fromSidebar: true) }
        }

        private func libraryLink(_ name: String, symbol: String, destination: MobileLibrary) -> some View {
            NavigationLink(value: destination) { Label(name, systemImage: symbol).lineLimit(1) }
        }

        @ViewBuilder private var libraryContent: some View {
            if library == .settings {
                AppSettingsView(store: store)
            } else if let error = store.loadError {
                ContentUnavailableView {
                    Label("storage.load_failed.title", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(L10n.originalPreserved(error))
                } actions: {
                    Button("storage.reload") { store.reload() }
                }
            } else if case .document(let id) = library {
                editor(id)
            } else if library == .tasks {
                TodoWorkspaceView(store: store)
            } else {
                RecordGallery(notes: notes, scrollState: galleryScroll) { note in
                    Button {
                        path.append(note.id)
                    } label: {
                        RecordCard(note: note)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("note-row-\(note.id)")
                    .contextMenu { noteActions(note) }
                }
                .searchable(text: $query, prompt: L10n.searchNotes(title))
                .overlay {
                    if notes.isEmpty {
                        if !query.isEmpty {
                            ContentUnavailableView.search(text: query)
                        } else {
                            ContentUnavailableView {
                                Label("note.empty.title", systemImage: "note.text")
                            } description: {
                                Text("note.empty.description")
                            } actions: {
                                Button("note.create", systemImage: "plus") { createNote() }
                                    .buttonStyle(.glassProminent).accessibilityIdentifier("empty-new-note")
                            }
                        }
                    }
                }
                .toolbar { libraryToolbar(fromSidebar: false) }
            }
        }

        @ToolbarContentBuilder private func libraryToolbar(fromSidebar: Bool) -> some ToolbarContent {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu("note.actions", systemImage: "ellipsis.circle") {
                    Button("folder.create", systemImage: "folder.badge.plus") { editFolder(nil) }
                    if case .folder(let id) = library, let folder = store.folders.first(where: { $0.id == id }) {
                        Button("folder.rename.menu", systemImage: "pencil") { editFolder(folder) }
                    }
                    Button("markdown.import", systemImage: "square.and.arrow.down") {
                        importFromSidebar = fromSidebar
                        showsImport = true
                    }
                    .accessibilityIdentifier("import-markdown")
                }
                .accessibilityIdentifier("library-actions")
                .disabled(store.loadError != nil)
                Button("note.create", systemImage: "square.and.pencil") { createNote(fromSidebar: fromSidebar) }
                    .accessibilityIdentifier("new-note")
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(store.loadError != nil)
            }
        }

        @ViewBuilder private func noteActions(_ note: Note) -> some View {
            Button("folder.move", systemImage: "folder") { movingNote = note }
        }

        private func moveDestination(_ name: String, folderID: UUID?, note: Note) -> some View {
            Button {
                store.moveNote(id: note.id, to: folderID)
                movingNote = nil
            } label: {
                HStack {
                    Label(name, systemImage: "folder")
                    Spacer()
                    if note.folderID == folderID { Image(systemName: "checkmark").accessibilityLabel("folder.current") }
                }
            }
        }

        private func select(_ destination: MobileLibrary?) {
            guard library != destination else { return }
            galleryScroll.reset()
            library = destination
            path = []
            query = ""
        }

        private func editFolder(_ folder: NoteFolder?) {
            editingFolderID = folder?.id
            folderName = folder?.name ?? ""
            showsFolderEditor = true
        }

        private func prepareNewNote() {
            if library == nil || library == .tasks || library == .settings { select(.all) }
            query = ""
        }

        private func createNote(fromSidebar: Bool = false) {
            prepareNewNote()
            store.createNote(folderID: activeFolderID)
            openCreatedNote(fromSidebar: fromSidebar)
        }

        private func openCreatedNote(fromSidebar: Bool) {
            guard let id = store.selectedID else { return }
            if fromSidebar {
                select(.document(id))
            } else {
                path = [id]
            }
            compactColumn = .detail
        }

        @ViewBuilder private func editor(_ id: UUID) -> some View {
            if let note = store.notes.first(where: { $0.id == id }) {
                NoteEditorView(note: note, store: store, saveError: store.saveError, retrySave: store.retrySave)
                    .id(id)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Menu("note.organize", systemImage: "ellipsis.circle") { noteActions(note) }
                                .accessibilityIdentifier("organize-note")
                        }
                    }
            }
        }
    }
#endif
