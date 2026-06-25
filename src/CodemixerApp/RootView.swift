import SwiftUI
import UniformTypeIdentifiers
import AgentCore
import AgentUI

// MARK: - RootView

struct RootView: View {
    @Bindable var bootstrap: Bootstrap
    @State private var diffPanelVisible: Bool = true

    var body: some View {
        ZStack {
            if let model = bootstrap.viewModel, bootstrap.workspace != nil {
                WorkspaceScene(model: model,
                               voice: bootstrap.voice,
                               tts: bootstrap.tts,
                               diffPanelVisible: $diffPanelVisible)
                    .navigationTitle(model.workspace?.lastPathComponent ?? "Codemixer")
                    .toolbar {
                        ToolbarItemGroup(placement: .primaryAction) {
                            if model.showUsageChip {
                                CostBadgeView(tokens: model.sessionTokens,
                                              costUSD: model.sessionCostUSD)
                            }
                            changesPanelToggle(for: model)
                            ConnectedClientsChip(count: model.connectedRemoteClients,
                                                 onTap: { bootstrap.showSettings = true })
                            toolbarOverflow(for: model)
                        }
                    }
                    .onChange(of: model.changedFiles.isEmpty) { _, isEmpty in
                        if !isEmpty { diffPanelVisible = true }
                    }
            } else {
                ProgressView("Starting agent…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surface.canvas)
            }
        }
        .sheet(isPresented: $bootstrap.showProjectPicker) {
            ProjectPickerView(recent: bootstrap.recents) { url, resume in
                Task { await bootstrap.openWorkspace(url, resumeSessionID: resume) }
            }
        }
        .sheet(isPresented: $bootstrap.showSettings) {
            if let model = bootstrap.viewModel {
                SettingsView(model: model,
                             remoteActions: bootstrap.remoteSettingsActions())
            }
        }
        .sheet(isPresented: $bootstrap.showDebugTerminal) {
            DebugTerminalSheet(snapshotText: bootstrap.debugTerminalSnapshotText,
                               onClose: { bootstrap.showDebugTerminal = false })
        }
        .sheet(isPresented: $bootstrap.showEventLog) {
            if let bus = bootstrap.bus { EventLogView(bus: bus) }
        }
        .sheet(item: $bootstrap.authURL) { url in
            AuthGateView(url: url, onDismiss: { bootstrap.authURL = nil })
        }
        .sheet(isPresented: Binding(
            get: { bootstrap.installHint != nil },
            set: { if !$0 { bootstrap.installHint = nil } }
        )) {
            InstallClaudeView(hint: bootstrap.installHint ?? "") {
                bootstrap.installHint = nil
            }
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
                Button("New Session") { model.send(.newSession) }
                Button("Compact Context") { model.send(.compact) }
                if let workspace = model.workspace {
                    Button("Reopen Current Project") {
                        model.send(.openProject(path: workspace.path, resumeSessionID: model.sessionID))
                    }
                }
                Button("Close Session") { model.send(.closeSession) }
            }
            Section("Model") {
                Button("Use Sonnet") { model.send(.selectModel(id: "sonnet")) }
                Button("Use Opus") { model.send(.selectModel(id: "opus")) }
            }
            Section("Mode") {
                Button("Default Permissions") { model.send(.setPermissionMode(.default)) }
                Button("Accept Edits") { model.send(.setPermissionMode(.acceptEdits)) }
                Button("Plan Mode") { model.send(.setPermissionMode(.plan)) }
                Button("Bypass Permissions") { model.send(.setPermissionMode(.bypassPermissions)) }
            }
            Section("Quick Commands") {
                Button("Help") { model.send(.runSlashCommand(name: "/help", args: [])) }
                Button("Usage") { model.send(.runSlashCommand(name: "/usage", args: [])) }
                Button("Model") { model.send(.runSlashCommand(name: "/model", args: [])) }
                Button("Permissions") { model.send(.runSlashCommand(name: "/permissions", args: [])) }
            }
            Section("Export Snapshot") {
                Button("Conversation") { model.send(.requestSnapshot(.conversation)) }
                Button("Diff") { model.send(.requestSnapshot(.diff)) }
                Button("Sessions") { model.send(.requestSnapshot(.sessions)) }
                Button("Preferences") { model.send(.requestSnapshot(.prefs)) }
            }
            Divider()
            Button("Show Debug Terminal") { bootstrap.showDebugTerminal = true }
            Button("Show Event Log") { bootstrap.showEventLog = true }
            Button("Settings…") { bootstrap.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("More actions")
    }
}
