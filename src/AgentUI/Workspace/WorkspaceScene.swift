import SwiftUI

/// The root scene: split view of conversation + diff, composer pinned at the
/// bottom, status pill floating above the composer.
///
/// Adds Cmd+F in-conversation search and a single-fire stalled-toast at 90s
/// of no engine activity (driven by `model.stalledToastVisible`).
public struct WorkspaceScene: View {
    @Bindable public var model: EngineViewModel
    public var voice: VoiceInputService?
    public var tts: TTSService?
    @Binding public var diffPanelVisible: Bool

    @State private var searchVisible: Bool = false
    @State private var paletteVisible: Bool = false
    @State private var navigatorFocusMode: Bool = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @Environment(\.effectiveReduceMotion) private var reduceMotion

    public init(model: EngineViewModel,
                voice: VoiceInputService? = nil,
                tts: TTSService? = nil,
                diffPanelVisible: Binding<Bool> = .constant(true)) {
        self.model = model
        self.voice = voice
        self.tts = tts
        self._diffPanelVisible = diffPanelVisible
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebarView(model: model, focusMode: $navigatorFocusMode)
                .navigationSplitViewColumnWidth(
                    min: navigatorFocusMode
                        ? Theme.layout.sessionSidebarIconRailWidth
                        : Theme.layout.sessionSidebarMinWidth,
                    ideal: navigatorFocusMode
                        ? Theme.layout.sessionSidebarIconRailWidth
                        : Theme.layout.sessionSidebarIdealWidth,
                    max: navigatorFocusMode
                        ? Theme.layout.sessionSidebarIconRailWidth
                        : Theme.layout.sessionSidebarMaxWidth)
        } detail: {
            if model.showsFolderBrowser,
               let path = model.workspace?.path,
               let project = model.projects.first(where: {
                   URL(fileURLWithPath: $0.path).standardizedFileURL.path
                       == URL(fileURLWithPath: path).standardizedFileURL.path
               }),
               let kind = project.projectType.folderKind {
                if model.showsPreviewOnly,
                   kind.showsPreviewOnSelection,
                   let relativePath = model.activeFolderSelectionRelativePath {
                    FilePreviewPanelHost(
                        model: model,
                        project: project,
                        kind: kind,
                        relativePath: relativePath
                    )
                } else {
                    FolderProjectBrowserView(model: model, project: project, kind: kind)
                }
            } else if model.changedFiles.isEmpty || !diffPanelVisible {
                conversationColumn
            } else {
                HSplitView {
                    conversationColumn
                    DiffPanelView(model: model, workspace: model.workspace)
                }
            }
        }
        .onChange(of: model.changedFiles.isEmpty) { _, isEmpty in
            // Auto-expand when files are first touched in a turn.
            if !isEmpty { diffPanelVisible = true }
        }
        .background(Theme.surface.canvas)
        .overlay(alignment: .bottom) {
            if let removed = model.removedProjectUndo {
                UndoToast(message: "Removed \(removed.ref.displayName)",
                          onUndo: {
                              Task { await model.undoRemoveProject() }
                          })
                    .padding(.bottom, Theme.spacing.s64)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Theme.motion.resolve(Theme.motion.arriving, reduceMotion: reduceMotion),
                   value: model.removedProjectUndo)
        .overlay {
            if paletteVisible {
                commandPalette
            }
        }
        .animation(Theme.motion.resolve(Theme.motion.arriving, reduceMotion: reduceMotion),
                   value: paletteVisible)
        .onAppear {
            model.subscribe()
            columnVisibility = model.sidebarVisible ? .all : .detailOnly
        }
        .onDisappear { model.unsubscribe() }
        .onChange(of: columnVisibility) { _, visibility in
            let visible = (visibility != .detailOnly)
            guard visible != model.sidebarVisible else { return }
            model.sidebarVisible = visible
            // Persist via the shared prefs path (multi-mode safe), not UserDefaults.
            model.updateAppearance(.sidebarVisible(visible))
        }
        // Hidden buttons so Cmd+F / Cmd+\ / Cmd+K work from anywhere in the scene.
        .background {
            Button("Search in conversation") { searchVisible.toggle() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            Button("Toggle Sidebar") { toggleSidebar() }
                .keyboardShortcut("\\", modifiers: .command)
                .hidden()
            Button("Command Palette") { paletteVisible.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
    }

    @ViewBuilder
    private var conversationColumn: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                // Overview-capable projects: project overview shows the hosted
                // dashboard only (no Chat/Dashboard tabs). File sessions stay chat-only.
                // Folder projects replace this column entirely at the detail level.
                if model.showsOverviewDashboard {
                    if model.isRestartingCustomACPCLI {
                        ContentUnavailableView(
                            "Restarting ACP CLI",
                            systemImage: "arrow.triangle.2.circlepath",
                            description: Text("Closing the agent process and waiting for it to come back online.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Restarting ACP CLI")
                    } else if let url = model.dashboardURL {
                        AgentDashboardView(url: url, reloadGeneration: model.dashboardLoadGeneration)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView(
                            "Dashboard unavailable",
                            systemImage: "rectangle.dashed",
                            description: Text("Waiting for the agent to advertise its overview URL. Try Restart ACP CLI if this persists.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Dashboard unavailable")
                    }
                } else {
                    ConversationView(model: model, tts: tts, searchVisible: $searchVisible)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                StatusPill(status: model.status,
                           substate: model.activity,
                           onCancel: { model.cancelCurrentTurn() })
                    .padding(.top, Theme.spacing.s12)
                    .padding(.trailing, Theme.spacing.s16)
            }

            // Overview page owns its own start/control chrome; keep composer for chat sessions.
            // Wave-gate / control-session reviews can still land while the dashboard
            // is visible — surface that prompt without opening the full composer.
            if model.showsOverviewDashboard {
                if let prompt = model.activePendingPermission {
                    PermissionPromptView(prompt: prompt) { decision in
                        model.respondToPermission(id: prompt.id, decision: decision)
                    }
                    .padding(.horizontal, Theme.spacing.s16)
                    .padding(.vertical, Theme.spacing.s12)
                    .background(Theme.surface.panel)
                    .overlay(alignment: .top) { Divider() }
                    .accessibilityLabel("Permission required for overview")
                }
            } else {
                PromptComposerView(model: model, voice: voice)
            }
        }
        .frame(minWidth: Theme.layout.workspaceSidebarMinWidth)
        .overlay(alignment: .top) {
            // Stalled-turn toast slides in from the top, auto-dismisses in 8s.
            if model.stalledToastVisible {
                StalledToast(onCancel: { model.cancelCurrentTurn() })
                    .padding(.top, Theme.spacing.s8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Theme.motion.quick, value: model.stalledToastVisible)
        .animation(Theme.motion.quick, value: model.showsOverviewDashboard)
    }

    @ViewBuilder
    private var commandPalette: some View {
        ZStack(alignment: .top) {
            // Dimmed backdrop; click to dismiss.
            Color.black.opacity(Theme.opacity.muted)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { paletteVisible = false }
                .accessibilityLabel("Dismiss command palette")

            CommandPaletteView(model: model,
                               sceneCommands: paletteSceneCommands,
                               onDismiss: { paletteVisible = false })
                .padding(.top, Theme.spacing.s64)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var paletteSceneCommands: [PaletteCommand] {
        [
            PaletteCommand(id: "scene-toggle-sidebar",
                           title: "Toggle Session Navigator",
                           subtitle: "Show or hide the sidebar (⌘\\)",
                           systemImage: "sidebar.leading") { toggleSidebar() },
            PaletteCommand(id: "scene-search",
                           title: "Search in Conversation",
                           subtitle: "Find text in the current chat (⌘F)",
                           systemImage: "magnifyingglass") { searchVisible = true },
        ]
    }

    private func toggleSidebar() {
        let animation = Theme.motion.resolve(Theme.motion.changing, reduceMotion: reduceMotion)
        withAnimation(animation) {
            columnVisibility = (columnVisibility == .detailOnly) ? .all : .detailOnly
        }
    }

}

// MARK: - Undo toast

private struct UndoToast: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: Theme.spacing.s12) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(Theme.text.secondary)
            Text(message)
                .font(Theme.typography.label)
                .foregroundStyle(Theme.text.primary)
            Button("Undo", action: onUndo)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Undo project removal")
        }
        .toastCardChrome()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Stalled toast

private struct StalledToast: View {
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.spacing.s12) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(Theme.signal.warning)
            Text("Agent may be stalled.")
                .font(Theme.typography.label)
                .foregroundStyle(Theme.text.primary)
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Cancel stalled turn")
        }
        .toastCardChrome(borderTint: Theme.signal.warning.opacity(Theme.opacity.medium),
                        borderWidth: Theme.stroke.standard)
    }
}
