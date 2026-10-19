import SwiftUI

@main
struct YoursApp: App {
    @State private var store: NoteStore
    @State private var preferences: AppPreferences
    @State private var cloudSync: CloudLibrarySync
    @Environment(\.scenePhase) private var scenePhase

    #if os(macOS)
        @NSApplicationDelegateAdaptor(YoursApplicationDelegate.self) private var appDelegate
        @FocusedValue(\.workspaceNavigation) private var navigation
        @FocusedValue(\.markdownActions) private var markdownActions
    #endif

    init() {
        let storage = AppStorage.current
        let preferences = AppPreferences()
        // Native menus use the application defaults on subsequent launches.
        // Test suites retain their own language without touching this domain.
        switch storage.profile {
        case .test: break
        case .production, .development:
            UserDefaults.standard.set([preferences.activeLanguage.rawValue], forKey: "AppleLanguages")
        }
        #if DEBUG
            if case .test = storage.profile {
                let directory = storage.directory
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
            }
        #endif
        let store = NoteStore(directory: storage.directory)
        _store = State(initialValue: store)
        _preferences = State(initialValue: preferences)
        _cloudSync = State(initialValue: CloudLibrarySync(store: store, preferences: preferences, storage: storage))
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView(store: store)
                #if os(macOS)
                    .onAppear {
                        appDelegate.store = store
                        appDelegate.preferences = preferences
                    }
                #endif
                .tint(AppTheme.accent)
                .environment(preferences)
                .environment(cloudSync)
                .environment(\.locale, preferences.activeLanguage.locale)
                .preferredColorScheme(preferences.theme.colorScheme)
                .task(id: preferences.iCloudSyncEnabled && scenePhase == .active) {
                    guard preferences.iCloudSyncEnabled, scenePhase == .active else { return }
                    while !Task.isCancelled {
                        await cloudSync.synchronize()
                        do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    }
                }
                .onChange(of: preferences.iCloudSyncEnabled) { _, _ in cloudSync.stop() }
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

#if os(macOS)
    @MainActor
    final class YoursApplicationDelegate: NSObject, NSApplicationDelegate {
        weak var store: NoteStore?
        weak var preferences: AppPreferences?

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            guard let store, store.hasUnsavedChanges else { return .terminateNow }
            Task {
                store.retrySave()
                await store.flushPendingSave()
                // A failed save leaves the app open with its persistent error and editable content.
                let saved = !store.hasUnsavedChanges && store.saveError == nil
                if !saved {
                    AppLanguageRestart.cancel()
                    preferences?.cancelPendingLanguageChange()
                }
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        }
    }
#endif
