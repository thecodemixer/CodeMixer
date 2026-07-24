import SwiftUI
import UniformTypeIdentifiers
import AgentCore
import AgentUI

// MARK: - RootView

struct RootView: View {
    @Bindable var bootstrap: Bootstrap
    @State private var diffPanelVisible: Bool = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack {
            if bootstrap.isStartupComplete, let model = bootstrap.viewModel {
                if bootstrap.isPreparingWorkspace {
                    startupLoading
                } else if bootstrap.workspace == nil {
                    noWorkspaceLanding
                } else if model.projects.isEmpty {
                    emptyWorkspaceLanding
                } else {
                    WorkspaceScene(model: model,
                                   voice: bootstrap.voice,
                                   tts: bootstrap.tts,
                                   diffPanelVisible: $diffPanelVisible)
                        .codemixerAppearance(model.appearancePrefs)
                        .navigationTitle(model.currentProjectDisplayName)
                        .toolbar {
                            ToolbarItemGroup(placement: .primaryAction) {
                                if model.showUsageChip {
                                    CostBadgeView(tokens: model.sessionTokens,
                                                  costUSD: model.sessionCostUSD)
                                }
                                changesPanelToggle(for: model)
                                ConnectedClientsChip(count: model.connectedRemoteClients,
                                                     onTap: { openSettings() })
                                toolbarOverflow(for: model)
                            }
                        }
                        .onChange(of: model.changedFiles.isEmpty) { _, isEmpty in
                            if !isEmpty { diffPanelVisible = true }
                        }
                }
            } else {
                startupLoading
            }
        }
        .codemixerAppearance(bootstrap.viewModel?.appearancePrefs ?? AppearancePrefs())
        .onChange(of: bootstrap.showProjectPicker) { _, show in
            syncUtilityWindow(UtilityWindowID.projectPicker, show: show)
        }
        .onChange(of: bootstrap.showOpenProject) { _, show in
            syncUtilityWindow(UtilityWindowID.openProject, show: show)
        }
        .onChange(of: bootstrap.showNewProjectSheet) { _, show in
            syncUtilityWindow(UtilityWindowID.newProject, show: show)
        }
        .onChange(of: bootstrap.showNewWorkspaceSheet) { _, show in
            syncUtilityWindow(UtilityWindowID.newWorkspace, show: show)
        }
        .onChange(of: bootstrap.pendingConfigureURL) { _, url in
            syncUtilityWindow(UtilityWindowID.configureProject, show: url != nil)
        }
        .onChange(of: bootstrap.showDebugTerminal) { _, show in
            syncUtilityWindow(UtilityWindowID.debugTerminal, show: show)
        }
        .onChange(of: bootstrap.showEventLog) { _, show in
            syncUtilityWindow(UtilityWindowID.eventLog, show: show)
        }
        .onChange(of: bootstrap.showSilentDiagnostics) { _, show in
            syncUtilityWindow(UtilityWindowID.silentDiagnostics, show: show)
        }
        .alert("Could not start agent",
               isPresented: Binding(
                   get: { bootstrap.startupError != nil },
                   set: { if !$0 { bootstrap.startupError = nil } }
               )) {
            Button("OK") { bootstrap.startupError = nil }
        } message: {
            Text(bootstrap.startupError ?? "Unknown startup error")
        }
        // Save panel when a snapshot export arrives from the engine.
        .onChange(of: bootstrap.viewModel?.pendingExport?.kind) { _, _ in
            if let export = bootstrap.viewModel?.pendingExport {
                bootstrap.viewModel?.clearPendingExport()
                presentSavePanel(for: export)
            }
        }
    }

    private func syncUtilityWindow(_ id: String, show: Bool) {
        if show {
            openWindow(id: id)
        } else {
            dismissWindow(id: id)
        }
    }

    private var startupLoading: some View {
        Theme.surface.canvas
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                ProgressView()
                    .controlSize(.regular)
            }
            .accessibilityLabel(bootstrap.isPreparingWorkspace
                                ? "Loading workspace models"
                                : "Loading")
    }

    private var noWorkspaceLanding: some View {
        WorkspaceLandingView(
            systemImage: "folder.badge.plus",
            title: "Open or create a workspace",
            subtitle: "A workspace is a folder that holds your projects and sessions.",
            primaryButtonTitle: "New Workspace…",
            primaryAction: { bootstrap.presentNewWorkspaceSheet() },
            primaryKeyboardShortcut: "n",
            secondaryButtonTitle: "Open Workspace…",
            secondaryAction: { bootstrap.presentProjectPicker() },
            secondaryKeyboardShortcut: "o"
        )
    }

    private var emptyWorkspaceLanding: some View {
        WorkspaceLandingView(
            systemImage: "folder",
            prominentName: bootstrap.workspace?.lastPathComponent,
            title: "Add your first project",
            subtitle: "Projects live inside this workspace. Choose a project type and name when you create one.",
            primaryButtonTitle: "New Project…",
            primaryAction: { bootstrap.presentNewProjectSheet() }
        )
    }

    @ViewBuilder
    private func changesPanelToggle(for model: EngineViewModel) -> some View {
        if !model.changedFiles.isEmpty {
            Button {
                diffPanelVisible.toggle()
            } label: {
                HStack(spacing: Theme.spacing.s4) {
                    Image(systemName: diffPanelVisible ? "sidebar.right" : "doc.text.magnifyingglass")
                        .imageScale(.small)
                    Text("\(model.changedFiles.count)")
                        .font(Theme.typography.caption)
                        .monospacedDigit()
                }
            }
            .buttonStyle(.borderless)
            .help(diffPanelVisible ? "Hide changes panel" : "Show changes panel")
            .accessibilityLabel(
                "\(diffPanelVisible ? "Hide" : "Show") \(model.changedFiles.count) changed \(model.changedFiles.count == 1 ? "file" : "files")"
            )
        }
    }

    private func presentSavePanel(for export: EngineViewModel.PendingExport) {
        guard let url = DesktopActions.savePanel(nameField: "snapshot.\(export.kind.rawValue)",
                                                 allowedTypes: [.json]) else { return }
        try? export.payload.write(to: url)
    }

    private func toolbarOverflow(for model: EngineViewModel) -> some View {
        Menu {
            Section("Session") {
                Button("New Session") { model.startNewSession() }
                Button("Compact Context") { model.compactContext() }
                if let workspace = model.workspace {
                    Button("Reopen Current Project") {
                        model.openProject(path: workspace.path, resumeSessionID: model.sessionID)
                    }
                }
                Button("Close Session") { model.closeCurrentSession() }
                Button("Close Workspace") {
                    Task { await bootstrap.closeWorkspace() }
                }
                .disabled(bootstrap.workspace == nil)
            }
            Section("Mode") {
                Button("Default Permissions") { model.setPermissionMode(.default) }
                Button("Accept Edits") { model.setPermissionMode(.acceptEdits) }
                Button("Plan Mode") { model.setPermissionMode(.plan) }
                Button("Bypass Permissions") { model.setPermissionMode(.bypassPermissions) }
            }
            Section("Quick Commands") {
                Button("Help") {
                    model.activateSlashCommand(
                        SlashCommand(id: "/help", name: "/help", summary: "Show help")
                    )
                }
                Button("Usage") {
                    model.activateSlashCommand(
                        SlashCommand(id: "/usage", name: "/usage", summary: "Show usage")
                    )
                }
                Button("Model") {
                    model.activateSlashCommand(
                        SlashCommand(id: "/model", name: "/model", summary: "Show or set model")
                    )
                }
                Button("Permissions") {
                    model.activateSlashCommand(
                        SlashCommand(id: "/permissions", name: "/permissions", summary: "Show permissions")
                    )
                }
            }
            Section("Export Snapshot") {
                Button("Conversation") { model.requestSnapshot(.conversation) }
                Button("Diff") { model.requestSnapshot(.diff) }
                Button("Sessions") { model.requestSnapshot(.sessions) }
                Button("Preferences") { model.requestSnapshot(.prefs) }
            }
            Divider()
            Button("Show Debug Terminal") { bootstrap.showDebugTerminal = true }
            Button("Show Event Log") { bootstrap.showEventLog = true }
            if model.showSilentRecoveryLog {
                Button("Show Silent Recovery Log") { bootstrap.showSilentDiagnostics = true }
            }
            Button("Settings…") { openSettings() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("More actions")
    }
}
