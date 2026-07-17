import SwiftUI
import AgentCore
import AgentUI
import AgentRemoteControl

/// Identifiers for secondary windows opened beside the main workspace.
enum UtilityWindowID {
    static let debugTerminal = "debug-terminal"
    static let eventLog = "event-log"
    static let silentDiagnostics = "silent-diagnostics"
    static let projectPicker = "project-picker"
    static let openProject = "open-project"
    static let newProject = "new-project"
    static let newWorkspace = "new-workspace"
    static let configureProject = "configure-project"
}

/// macOS app entry point. Owns one `AgentEngine` per workspace, a single
/// `EngineViewModel` bound to it, and an in-process `RemoteControlServer`
/// so paired mobile clients can drive the same engine over Wi-Fi.
@main
struct CodemixerApp: App {

    @State private var bootstrap = Bootstrap()

    init() {
        // Reap zombie children (PTY workers, openssl, git) early.
        ChildReaper.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView(bootstrap: bootstrap)
                .frame(minWidth: 1024, minHeight: 640)
                .task { await bootstrap.start() }
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    bootstrap.viewModel?.newChatInCurrentProject()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(bootstrap.viewModel?.workspace == nil)
                Button("New Workspace…") { bootstrap.presentNewWorkspaceSheet() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Project…") { bootstrap.presentNewProjectSheet() }
                    .disabled(bootstrap.workspace == nil)
                Divider()
                Button("Open Workspace…") { bootstrap.presentProjectPicker() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Add Existing Project…") { bootstrap.presentOpenProject() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(bootstrap.workspace == nil)
                Button("Close Workspace") {
                    Task { await bootstrap.closeWorkspace() }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(bootstrap.workspace == nil)
                Button("Cancel Turn") { bootstrap.viewModel?.send(.cancelCurrentTurn) }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(bootstrap.viewModel?.canCancel != true)
            }
            CommandGroup(after: .saveItem) {
                Button("Export as Markdown…") { bootstrap.exportSession(as: .markdown) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export as JSONL…") { bootstrap.exportSession(as: .jsonl) }
                Button("Export as HTML…") { bootstrap.exportSession(as: .html) }
            }
            CommandGroup(after: .help) {
                Button("Show Debug Terminal") { bootstrap.showDebugTerminal = true }
                Button("Show Event Log") { bootstrap.showEventLog = true }
                if bootstrap.viewModel?.showSilentRecoveryLog == true {
                    Button("Show Silent Recovery Log") { bootstrap.showSilentDiagnostics = true }
                }
            }
        }

        Settings {
            settingsRoot
        }
        .windowResizability(.contentMinSize)

        Window("Debug Terminal", id: UtilityWindowID.debugTerminal) {
            DebugTerminalSheet(
                snapshotText: bootstrap.debugTerminalSnapshotText,
                onClose: { bootstrap.showDebugTerminal = false }
            )
            .codemixerAppearance(bootstrap.viewModel?.appearancePrefs ?? AppearancePrefs())
            .onDisappear { bootstrap.showDebugTerminal = false }
        }
        .windowResizability(.contentMinSize)

        Window("Event Log", id: UtilityWindowID.eventLog) {
            Group {
                if let bus = bootstrap.bus {
                    EventLogView(bus: bus)
                } else {
                    ProgressView()
                        .frame(minWidth: Theme.layout.eventLogMinWidth,
                               minHeight: Theme.layout.eventLogMinHeight)
                }
            }
            .codemixerAppearance(bootstrap.viewModel?.appearancePrefs ?? AppearancePrefs())
            .onDisappear { bootstrap.showEventLog = false }
        }
        .windowResizability(.contentMinSize)

        Window("Silent Recovery Log", id: UtilityWindowID.silentDiagnostics) {
            SilentDiagnosticsView()
                .codemixerAppearance(bootstrap.viewModel?.appearancePrefs ?? AppearancePrefs())
                .onDisappear { bootstrap.showSilentDiagnostics = false }
        }
        .windowResizability(.contentMinSize)

        Window("Open Workspace", id: UtilityWindowID.projectPicker) {
            WorkspacePickerView(
                recent: bootstrap.recents,
                onCancel: { bootstrap.showProjectPicker = false }
            ) { url, resume in
                Task { await bootstrap.openWorkspace(url, resumeSessionID: resume) }
            }
            .codemixerAppearance(bootstrap.viewModel?.appearancePrefs ?? AppearancePrefs())
            .movablePanelTitle("Open Workspace")
            .onDisappear { bootstrap.showProjectPicker = false }
        }
        .windowResizability(.contentSize)

        Window("Open Project", id: UtilityWindowID.openProject) {
            OpenProjectView(
                onCancel: { bootstrap.showOpenProject = false }
            ) { url in
                bootstrap.showOpenProject = false
                Task { await bootstrap.openWorkspace(url, resumeSessionID: nil) }
            }
            .codemixerAppearance(bootstrap.viewModel?.appearancePrefs ?? AppearancePrefs())
            .movablePanelTitle("Open Project")
            .onDisappear { bootstrap.showOpenProject = false }
        }
        .windowResizability(.contentSize)

        Window("New Project", id: UtilityWindowID.newProject) {
            Group {
                if let model = bootstrap.viewModel {
                    NewProjectSheet(
                        onCancel: { bootstrap.showNewProjectSheet = false },
                        onCreate: { name, mode in
                            await model.createProject(name: name, projectType: mode)
                            bootstrap.showNewProjectSheet = false
                        }
                    )
                } else {
                    ProgressView()
                        .frame(minWidth: Theme.layout.agentPickerMinWidth)
                        .padding(Theme.spacing.s24)
                }
            }
            .codemixerAppearance(bootstrap.viewModel?.appearancePrefs ?? AppearancePrefs())
            .movablePanelTitle("New Project")
            .onDisappear { bootstrap.showNewProjectSheet = false }
        }
        .windowResizability(.contentSize)

        Window("New Workspace", id: UtilityWindowID.newWorkspace) {
            NewWorkspaceSheet(
                onCancel: { bootstrap.showNewWorkspaceSheet = false },
                onCreate: { name, parent in
                    Task {
                        await bootstrap.createWorkspace(name: name, parentDirectory: parent)
                    }
                }
            )
            .codemixerAppearance(bootstrap.viewModel?.appearancePrefs ?? AppearancePrefs())
            .movablePanelTitle("New Workspace")
            .onDisappear { bootstrap.showNewWorkspaceSheet = false }
        }
        .windowResizability(.contentSize)

        Window("Configure Project", id: UtilityWindowID.configureProject) {
            Group {
                if let url = bootstrap.pendingConfigureURL {
                    ConfigureProjectSheet(
                        projectURL: url,
                        onCancel: { bootstrap.cancelPendingProjectConfiguration() },
                        onConfirm: { mode in
                            Task { await bootstrap.confirmPendingProjectConfiguration(mode: mode) }
                        }
                    )
                } else {
                    ProgressView()
                        .frame(minWidth: Theme.layout.agentPickerMinWidth)
                        .padding(Theme.spacing.s24)
                }
            }
            .codemixerAppearance(bootstrap.viewModel?.appearancePrefs ?? AppearancePrefs())
            .movablePanelTitle("Configure Project")
            .onDisappear { bootstrap.cancelPendingProjectConfiguration() }
        }
        .windowResizability(.contentSize)
    }

    @ViewBuilder
    private var settingsRoot: some View {
        if let model = bootstrap.viewModel {
            SettingsView(model: model,
                         remoteActions: bootstrap.remoteSettingsActions())
                .codemixerAppearance(model.appearancePrefs)
        } else {
            ProgressView("Loading…")
                .frame(minWidth: Theme.layout.settingsMinWidth,
                       minHeight: Theme.layout.settingsMinHeight)
        }
    }
}
