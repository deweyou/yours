#if os(macOS)
    import AppKit
    import SwiftUI

    @MainActor @Observable
    final class MacWorkspaceNavigation {
        enum Destination: Equatable {
            case home, documents, tasks, settings
        }

        private struct Location: Equatable {
            var destination: Destination
            var editorID: UUID?
        }

        private var location = Location(destination: .home)
        private var backHistory: [Location] = []
        private var forwardHistory: [Location] = []

        var destination: Destination { location.destination }
        var editorID: UUID? { location.editorID }
        var canGoBack: Bool { !backHistory.isEmpty }
        var canGoForward: Bool { !forwardHistory.isEmpty }

        func select(_ destination: Destination) {
            visit(Location(destination: destination))
        }

        func openNote(_ id: UUID) {
            visit(Location(destination: .documents, editorID: id))
        }

        func goBack() {
            guard let previous = backHistory.popLast() else { return }
            forwardHistory.append(location)
            location = previous
        }

        func goForward() {
            guard let next = forwardHistory.popLast() else { return }
            backHistory.append(location)
            location = next
        }

        private func visit(_ next: Location) {
            guard next != location else { return }
            backHistory.append(location)
            location = next
            forwardHistory.removeAll()
        }

        func createNote(in store: NoteStore) {
            store.createNote()
            if let id = store.selectedID { openNote(id) }
        }

    }

    extension FocusedValues {
        @Entry var workspaceNavigation: MacWorkspaceNavigation?
    }

    struct MacWorkspaceView: View {
        @Bindable var store: NoteStore
        @Environment(\.colorSchemeContrast) private var contrast
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @State private var navigation = MacWorkspaceNavigation()
        @State private var galleryScroll = RecordGalleryScrollState()

        private var notes: [Note] {
            store.notes.sorted { $0.updatedAt > $1.updatedAt }
        }

        var body: some View {
            HStack(spacing: 0) {
                functionRail
                workspaceCard
                    .background(WorkspaceWindowControls())
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                    .padding(.top, 14)
            }
            .background {
                ZStack {
                    if reduceTransparency {
                        Color(nsColor: .windowBackgroundColor)
                    } else {
                        WorkspaceBackdrop()
                    }
                    // Keep the glass tint close to the document canvas without hiding it.
                    Color(nsColor: .textBackgroundColor)
                        .opacity(contrast == .increased ? 0 : (colorScheme == .dark ? 0.68 : 0.50))
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            .containerBackground(.clear, for: .window)
            .frame(minWidth: 780, minHeight: 460)
            .containerShape(.rect(cornerRadius: 16))
            .overlay(alignment: .top) {
                HStack(spacing: 4) {
                    historyButton("navigation.back", symbol: "chevron.left", enabled: navigation.canGoBack, action: navigation.goBack)
                        .accessibilityIdentifier("navigation-back")
                    historyButton(
                        "navigation.forward", symbol: "chevron.right", enabled: navigation.canGoForward, action: navigation.goForward
                    )
                    .accessibilityIdentifier("navigation-forward")
                    Spacer(minLength: 0)
                    if navigation.destination == .documents { newNoteButton }
                }
                .padding(.leading, 84)
                .padding(.trailing, 12)
                .frame(height: 46)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
            }
            .focusedSceneValue(\.workspaceNavigation, navigation)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if navigation.editorID == nil, let error = store.saveError {
                    HStack {
                        Label(L10n.unsaved(error), systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("common.retry") { store.retrySave() }
                    }.padding().background(.bar)
                }
            }
        }

        private func historyButton(
            _ title: LocalizedStringKey, symbol: String, enabled: Bool, action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 28, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            .accessibilityLabel(title)
            .help(title)
            .disabled(!enabled)
            .pointerStyle(enabled ? .link : .default)
        }

        private var newNoteButton: some View {
            Button {
                navigation.createNote(in: store)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 32, height: 32)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .tint(.primary)
            .accessibilityLabel("note.create")
            .accessibilityIdentifier("new-note")
            .help("note.create.help")
            .disabled(store.loadError != nil)
            .pointerStyle(store.loadError == nil ? .link : .default)
        }

        private var functionRail: some View {
            VStack(spacing: 6) {
                destinationButton("navigation.home", symbol: "house", isSelected: navigation.destination == .home) {
                    navigation.select(.home)
                }
                .accessibilityIdentifier("workspace-home")
                destinationButton("navigation.documents", symbol: "doc.text", isSelected: navigation.destination == .documents) {
                    navigation.select(.documents)
                }
                .accessibilityIdentifier("workspace-documents")
                destinationButton("navigation.tasks", symbol: "checkmark.square", isSelected: navigation.destination == .tasks) {
                    navigation.select(.tasks)
                }
                .accessibilityIdentifier("workspace-tasks")
                .help("tasks.coming_soon.help")
                Spacer(minLength: 0)
                destinationButton("settings.title", symbol: "gearshape", isSelected: navigation.destination == .settings) {
                    navigation.select(.settings)
                }
                .accessibilityIdentifier("workspace-settings")
                .help("settings.title")
            }
            .padding(.top, 14)
            .padding(.bottom, 12)
            .frame(width: 48)
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("navigation.accessibility_label")
        }

        private func destinationButton(
            _ title: LocalizedStringKey, symbol: String, isSelected: Bool, action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                Image(systemName: isSelected ? "\(symbol).fill" : symbol)
                    .accessibilityHidden(true)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .frame(width: 32, height: 32)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.primary.opacity(contrast == .increased ? 0.16 : 0.07))
                        }
                    }
                    .contentShape(.rect(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .help(title)
            .accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }

        private var workspaceCard: some View {
            Group {
                if navigation.destination == .settings {
                    AppSettingsView(store: store)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if navigation.destination == .home {
                    ContentUnavailableView("navigation.home", systemImage: "house", description: Text("home.empty.description"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HSplitView {
                        notesSidebar
                            .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
                            .background(WorkspaceSplitPosition())
                        VStack(spacing: 0) {
                            detail
                        }
                        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor))
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(workspaceCardShape)
            .background {
                workspaceCardShape
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 4, y: 1)
                    .allowsHitTesting(false)
            }
            .overlay {
                workspaceCardShape
                    .stroke(Color.primary.opacity(contrast == .increased ? 0.3 : 0.08), lineWidth: 1)
                    .clipShape(workspaceCardShape)
                    .allowsHitTesting(false)
            }
        }

        private var workspaceCardShape: ConcentricRectangle {
            ConcentricRectangle(
                topLeadingCorner: .fixed(16), topTrailingCorner: .fixed(16),
                bottomLeadingCorner: .fixed(16), bottomTrailingCorner: .concentric)
        }

        private var notesSidebar: some View {
            VStack(spacing: 0) {
                if navigation.destination == .documents {
                    Button {
                        navigation.select(.documents)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            Text(verbatim: "Inbox")
                                .font(.body)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(contrast == .increased ? 0.16 : 0.06))
                        }
                        .contentShape(.rect(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("documents-inbox")
                    .accessibilityAddTraits(.isSelected)
                    .pointerStyle(.link)
                    .padding(.horizontal, 8)
                    .padding(.top, 12)
                }
                Spacer(minLength: 0)

            }
            .background(Color(nsColor: .textBackgroundColor))
        }

        @ViewBuilder private var detail: some View {
            if let error = store.loadError {
                ContentUnavailableView {
                    Label("storage.load_failed.title", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(L10n.originalPreserved(error))
                } actions: {
                    Button("storage.reload") { store.reload() }
                }
            } else if navigation.destination == .tasks {
                ContentUnavailableView(
                    "tasks.coming_soon.title", systemImage: "checklist", description: Text("tasks.coming_soon.description")
                )
                .navigationTitle(L10n.string("navigation.tasks"))
            } else if let note = store.notes.first(where: { $0.id == navigation.editorID }) {
                NoteEditorView(note: note, store: store, saveError: store.saveError, retrySave: store.retrySave)
                    .id(note.id)
            } else {
                library
            }
        }

        private var library: some View {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    Text(verbatim: "Inbox").font(.largeTitle.bold())
                    Spacer()
                    Text(L10n.noteCount(notes.count)).foregroundStyle(.secondary)

                }
                .padding(.horizontal, 36).padding(.top, 24).padding(.bottom, 4)
                RecordGallery(notes: notes, scrollState: galleryScroll) { note in
                    Button {
                        navigation.openNote(note.id)
                    } label: {
                        RecordCard(note: note)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("note-row-\(note.id)")
                    .accessibilityLabel(note.displayTitle)
                    .accessibilityValue(note.preview)
                    .pointerStyle(.link)
                }
                .overlay {
                    if notes.isEmpty {
                        ContentUnavailableView {
                            Label("note.empty.title", systemImage: "note.text")
                        } description: {
                            Text("note.empty.prompt")
                        }
                    }
                }
            }
            .navigationTitle("Inbox")
        }
    }

    /// Center native window controls in the full strip above the card.
    private struct WorkspaceWindowControls: NSViewRepresentable {
        func makeNSView(context: Context) -> AlignmentView { AlignmentView() }

        func updateNSView(_ view: AlignmentView, context: Context) {
            view.needsLayout = true
        }

        final class AlignmentView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                NotificationCenter.default.removeObserver(self)
                guard let window else { return }
                // SwiftUI may mount this probe before AppKit restores the final window size.
                // Reconcile after window updates as well as geometry changes; alignment is idempotent.
                for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didUpdateNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(alignControls), name: name, object: window)
                }
                needsLayout = true
            }

            override func layout() {
                super.layout()
                alignControls()
            }

            @objc private func alignControls() {
                guard let window, !window.styleMask.contains(.fullScreen), bounds.height > 0 else { return }
                let cardTop = convert(bounds, to: nil).maxY
                let stripHeight = window.frame.height - cardTop
                // Do not reposition system controls during transient or full-screen layouts.
                guard (20...80).contains(stripHeight) else { return }
                let center = NSPoint(x: 0, y: cardTop + stripHeight / 2)
                for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                    guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
                    let y = parent.convert(center, from: nil).y - button.frame.height / 2
                    if abs(button.frame.origin.y - y) > 0.25 {
                        button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y))
                    }
                }
            }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }

    /// Sample behind the window while keeping the document surface opaque.
    private struct WorkspaceBackdrop: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .underWindowBackground
            view.blendingMode = .behindWindow
            view.state = .followsWindowActiveState
            return view
        }

        func updateNSView(_ view: NSVisualEffectView, context: Context) {}
    }

    /// Set the initial divider once; subsequent resizing remains owned by the native split view.
    private struct WorkspaceSplitPosition: NSViewRepresentable {
        func makeNSView(context: Context) -> InitialPositionView { InitialPositionView() }

        func updateNSView(_ view: InitialPositionView, context: Context) {}

        final class InitialPositionView: NSView {
            private var didSetPosition = false
            private var initialLayoutTask: Task<Void, Never>?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                initialLayoutTask?.cancel()
                guard window != nil else { return }
                // SwiftUI must finish mounting and sizing the native split before applying its initial position.
                initialLayoutTask = Task { @MainActor [weak self] in
                    guard !Task.isCancelled else { return }
                    self?.setInitialPosition()
                }
            }

            private func setInitialPosition() {
                guard !didSetPosition, window != nil else { return }
                var ancestor = superview
                while let view = ancestor {
                    if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 2, split.bounds.width > 0 {
                        split.layoutSubtreeIfNeeded()
                        didSetPosition = true
                        split.setPosition(240, ofDividerAt: 0)
                        return
                    }
                    ancestor = view.superview
                }
            }

            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
    }
#endif
