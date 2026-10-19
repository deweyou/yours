import SwiftUI

@main
struct YoursApp: App {
    @State private var store: NoteStore
    @State private var preferences = AppPreferences()
    @Environment(\.scenePhase) private var scenePhase

    #if os(macOS)
        @FocusedValue(\.workspaceNavigation) private var navigation
        @FocusedValue(\.markdownActions) private var markdownActions
    #endif

    init() {
        #if DEBUG
            // A UUID names an isolated test store; never accept an arbitrary data path.
            if let value = ProcessInfo.processInfo.environment["YOURS_UI_TEST_SESSION"],
                let session = UUID(uuidString: value)
            {
                let directory = URL.applicationSupportDirectory
                    .appendingPathComponent("YoursUITests", isDirectory: true)
                    .appendingPathComponent(session.uuidString, isDirectory: true)
                if let count = ProcessInfo.processInfo.environment["YOURS_UI_TEST_GALLERY_COUNT"].flatMap(Int.init),
                    [1_000, 10_000].contains(count),
                    !FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes.json").path)
                {
                    // Fixtures are allowed only inside the UUID-isolated Debug store.
                    let notes = (0..<count).map { index in
                        let date = Date(timeIntervalSince1970: 1_700_000_000 - Double(index))
                        return Note(
                            id: UUID(), text: String(repeating: "中文笔记与 mixed text 👋。\n", count: index % 12 + 1),
                            createdAt: date, updatedAt: date, title: String(format: "Gallery %04d", index))
                    }
                    do {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try JSONEncoder().encode(notes).write(to: directory.appendingPathComponent("notes.json"), options: .atomic)
                    } catch {
                        preconditionFailure("Cannot prepare isolated gallery fixture: \(error)")
                    }
                }
                _store = State(initialValue: NoteStore(directory: directory))
                return
            }
        #endif
        _store = State(initialValue: NoteStore())
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView(store: store)
                .tint(AppTheme.accent)
                .environment(preferences)
                .environment(\.locale, preferences.activeLanguage.locale)
                .preferredColorScheme(preferences.theme.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    guard phase != .active else { return }
                    Task { await store.flushPendingSave() }
                }
        }
        #if os(macOS)
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 1000, height: 720)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(L10n.string("settings.open")) { navigation?.select(.settings) }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(navigation == nil)
                }
                CommandGroup(after: .importExport) {
                    Button(L10n.string("markdown.copy")) { markdownActions?.copy() }
                    .disabled(markdownActions == nil)
                    Button(L10n.string("markdown.export")) { markdownActions?.export() }
                    .disabled(markdownActions == nil)
                }
                CommandGroup(replacing: .newItem) {
                    Button(L10n.string("note.create"), systemImage: "square.and.pencil") {
                        navigation?.createNote(in: store)
                    }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(store.loadError != nil || navigation == nil)
                }
            }
        #endif
    }
}
