import SwiftUI

struct AppSettingsView: View {
    let store: NoteStore
    @Environment(AppPreferences.self) private var preferences
    @Environment(CloudLibrarySync.self) private var cloudSync
    @State private var pendingLanguage: AppPreferences.Language?
    @State private var isChangingLanguage = false
    @State private var languageError: String?

    var body: some View {
        settingsContent
            .disabled(isChangingLanguage)
            .alert(
                "settings.language.confirm_title",
                isPresented: Binding(
                    get: { pendingLanguage != nil }, set: { if !$0 { pendingLanguage = nil } }
                ), presenting: pendingLanguage
            ) { language in
                Button(languageConfirmationLabel) {
                    Task { await changeLanguage(to: language) }
                }
                .accessibilityIdentifier("settings-language-confirm")
                Button("common.cancel", role: .cancel) {}
            } message: { _ in
                #if os(macOS)
                    Text("settings.language.restart_message")
                #else
                    Text("settings.language.reopen_message")
                #endif
            }
            .alert(
                "settings.language.failed",
                isPresented: Binding(
                    get: { languageError != nil }, set: { if !$0 { languageError = nil } }
                )
            ) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text(verbatim: languageError ?? "")
            }
    }

    private var languageConfirmationLabel: LocalizedStringKey {
        #if os(macOS)
            "settings.language.restart_confirm"
        #else
            "settings.language.confirm"
        #endif
    }

    private var settingsContent: some View {
        #if os(macOS)
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Text("settings.title")
                        .font(.largeTitle.bold())
                        .padding(.bottom, 8)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("settings.basics").font(.title2.weight(.semibold))
                        GroupBox {
                            VStack(spacing: 0) {
                                HStack(spacing: 24) {
                                    Text("settings.theme")
                                    Spacer(minLength: 0)
                                    themePicker.labelsHidden().fixedSize()
                                }
                                .padding(12)
                                Divider().padding(.horizontal, 12)
                                HStack(spacing: 24) {
                                    Text("settings.language")
                                    Spacer(minLength: 0)
                                    languagePicker.labelsHidden().fixedSize()
                                }
                                .padding(12)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("settings.data").font(.title2.weight(.semibold))
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 24) {
                                    Text("sync.toggle")
                                    Spacer(minLength: 0)
                                    syncToggle.labelsHidden().fixedSize()
                                }
                                syncDetails
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        storageDescription
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .navigationTitle(L10n.string("settings.title"))
        #else
            Form {
                Section {
                    themePicker
                    languagePicker
                } header: {
                    Text("settings.basics")
                }
                Section {
                    syncToggle
                    syncDetails
                } header: {
                    Text("settings.data")
                } footer: {
                    storageDescription
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle(L10n.string("settings.title"))
        #endif
    }

    private var syncToggle: some View {
        @Bindable var preferences = preferences
        return Toggle("sync.toggle", isOn: $preferences.iCloudSyncEnabled)
            .disabled(!cloudSync.isAvailable && !preferences.iCloudSyncEnabled)
            .accessibilityIdentifier("settings-icloud-sync")
            #if os(macOS)
                .toggleStyle(.switch)
                .controlSize(.small)
                .pointerStyle(.link)
                .help("sync.help")
            #endif
    }

    private var syncDetails: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 6) {
                if cloudSync.isSyncing {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(Text("sync.syncing"))
                        .accessibilityIdentifier("settings-sync-progress")
                    Text("sync.syncing")
                } else if !cloudSync.isAvailable {
                    Text("sync.not_configured")
                } else if let error = cloudSync.errorMessage, preferences.iCloudSyncEnabled {
                    Text(verbatim: error).foregroundStyle(.primary)
                } else if !preferences.iCloudSyncEnabled {
                    Text("sync.off")
                } else if let date = cloudSync.lastSync {
                    HStack(spacing: 4) {
                        Text("sync.last_success")
                        Text(date, format: .dateTime.hour().minute())
                    }
                } else {
                    Text("sync.waiting")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            if preferences.iCloudSyncEnabled, cloudSync.isAvailable || cloudSync.isSyncing {
                Button("sync.now") { Task { await cloudSync.synchronize() } }
                    .disabled(cloudSync.isSyncing)
                    .fixedSize()
                    .accessibilityIdentifier("settings-sync-now")
                    #if os(macOS)
                        .controlSize(.small)
                        .pointerStyle(.link)
                    #endif
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private var storageDescription: some View {
        if AppStorage.current.profile != .production {
            Group {
                switch AppStorage.current.profile {
                case .production: EmptyView()
                case .development: Text("storage.profile.development")
                case .test(let session):
                    Text("storage.profile.test")
                        .accessibilityValue("\(session.uuidString)|\(AppStorage.current.root.path)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("settings-storage-profile")
        }
    }

    private var themePicker: some View {
        @Bindable var preferences = preferences
        return Picker("settings.theme", selection: $preferences.theme) {
            Text("settings.theme.light").tag(AppPreferences.Theme.light)
            Text("settings.theme.dark").tag(AppPreferences.Theme.dark)
            Text("settings.theme.system").tag(AppPreferences.Theme.system)
        }
        .accessibilityIdentifier("settings-theme")
        #if os(macOS)
            .pickerStyle(.menu)
            .tint(.primary)
            .pointerStyle(.link)
        #endif
    }

    private var languagePicker: some View {
        Picker(
            "settings.language",
            selection: Binding(
                get: { preferences.activeLanguage },
                set: { if $0 != preferences.activeLanguage { pendingLanguage = $0 } }
            )
        ) {
            Text(verbatim: "中文").tag(AppPreferences.Language.chinese)
            Text(verbatim: "English").tag(AppPreferences.Language.english)
        }
        .accessibilityIdentifier("settings-language")
        #if os(macOS)
            .pickerStyle(.menu)
            .tint(.primary)
            .pointerStyle(.link)
        #endif
    }

    private func changeLanguage(to language: AppPreferences.Language) async {
        guard !isChangingLanguage else { return }
        isChangingLanguage = true
        defer { isChangingLanguage = false }
        do {
            try await preferences.changeLanguage(
                to: language,
                save: {
                    await store.flushPendingSave()
                    return store.loadError == nil && store.saveError == nil && !store.hasUnsavedChanges
                },
                restart: {
                    #if os(macOS)
                        try AppLanguageRestart.restart()
                    #endif
                })
        } catch { languageError = error.localizedDescription }
    }
}
