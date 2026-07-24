import SwiftUI
import AgentCore

/// Top-level Settings sheet — Appearance, Permissions, Remote, Workspace,
/// Claude (read-only). Each tab is self-contained so future adapters can
/// inject their own tab without rebuilding the shell.
public struct SettingsView: View {
    @Bindable public var model: EngineViewModel
    public var remoteActions: RemoteSettingsActions

    public init(model: EngineViewModel,
                remoteActions: RemoteSettingsActions = .disabled) {
        self.model = model
        self.remoteActions = remoteActions
    }

    public var body: some View {
        TabView {
            AppearanceSettingsTab(model: model)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            PermissionsSettingsTab(model: model)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            RemoteSettingsTab(model: model, actions: remoteActions)
                .tabItem { Label("Remote", systemImage: "antenna.radiowaves.left.and.right") }
            WorkspaceSettingsTab(model: model)
                .tabItem { Label("Workspace", systemImage: "folder") }
            ClaudeSettingsTab()
                .tabItem { Label("Claude", systemImage: "sparkles") }
        }
        .frame(minWidth: Theme.layout.settingsMinWidth,
               minHeight: Theme.layout.settingsMinHeight)
        .padding(Theme.spacing.s16)
        .movablePanelTitle("Settings")
    }
}

#if DEBUG
#Preview("Settings – Light") {
    SettingsView(model: .preview)
        .preferredColorScheme(.light)
}

#Preview("Settings – Dark") {
    SettingsView(model: .preview)
        .preferredColorScheme(.dark)
}
#endif
