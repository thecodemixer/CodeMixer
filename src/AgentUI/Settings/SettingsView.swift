import SwiftUI
import AppKit
import AgentCore
import AgentProtocol

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
        .frame(minWidth: Theme.layout.settingsMinWidth, minHeight: Theme.layout.settingsMinHeight)
        .padding(Theme.spacing.s16)
    }
}

public struct RemoteSettingsState: Sendable, Equatable {
    public struct Device: Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let lastSeen: Date

        public init(id: String, name: String, lastSeen: Date) {
            self.id = id
            self.name = name
            self.lastSeen = lastSeen
        }
    }

    public var pin: String?
    public var certificateFingerprint: String?
    public var pairingURL: String?
    public var pairedDevices: [Device]
    public var connectedClientCount: Int
    public var launchAgentInstalled: Bool
    public var launchAgentDetail: String?
    /// Whether the WebSocket remote-control server is currently running.
    public var remoteEnabled: Bool
    /// Whether the server is bound to all interfaces (LAN) vs loopback only.
    public var lanEnabled: Bool

    public init(pin: String? = nil,
                certificateFingerprint: String? = nil,
                pairingURL: String? = nil,
                pairedDevices: [Device] = [],
                connectedClientCount: Int = 0,
                launchAgentInstalled: Bool = false,
                launchAgentDetail: String? = nil,
                remoteEnabled: Bool = false,
                lanEnabled: Bool = false) {
        self.pin = pin
        self.certificateFingerprint = certificateFingerprint
        self.pairingURL = pairingURL
        self.pairedDevices = pairedDevices
        self.connectedClientCount = connectedClientCount
        self.launchAgentInstalled = launchAgentInstalled
        self.launchAgentDetail = launchAgentDetail
        self.remoteEnabled = remoteEnabled
        self.lanEnabled = lanEnabled
    }
}

public struct RemoteSettingsActions: Sendable {
    public var refresh: @Sendable () async -> RemoteSettingsState
    public var startPairing: @Sendable () async -> RemoteSettingsState
    public var revoke: @Sendable (String) async -> RemoteSettingsState
    public var installLaunchAgent: @Sendable () async -> RemoteSettingsState
    public var uninstallLaunchAgent: @Sendable () async -> RemoteSettingsState
    /// Start (`true`) or stop (`false`) the WebSocket remote-control server.
    public var enableRemote: @Sendable (Bool) async -> RemoteSettingsState
    /// Rebind the server to LAN (`true`) or loopback only (`false`).
    public var setLANEnabled: @Sendable (Bool) async -> RemoteSettingsState

    public init(refresh: @escaping @Sendable () async -> RemoteSettingsState,
                startPairing: @escaping @Sendable () async -> RemoteSettingsState,
                revoke: @escaping @Sendable (String) async -> RemoteSettingsState,
                installLaunchAgent: @escaping @Sendable () async -> RemoteSettingsState,
                uninstallLaunchAgent: @escaping @Sendable () async -> RemoteSettingsState,
                enableRemote: @escaping @Sendable (Bool) async -> RemoteSettingsState,
                setLANEnabled: @escaping @Sendable (Bool) async -> RemoteSettingsState) {
        self.refresh = refresh
        self.startPairing = startPairing
        self.revoke = revoke
        self.installLaunchAgent = installLaunchAgent
        self.uninstallLaunchAgent = uninstallLaunchAgent
        self.enableRemote = enableRemote
        self.setLANEnabled = setLANEnabled
    }

    public static let disabled = RemoteSettingsActions(
        refresh: { RemoteSettingsState() },
        startPairing: { RemoteSettingsState() },
        revoke: { _ in RemoteSettingsState() },
        installLaunchAgent: { RemoteSettingsState() },
        uninstallLaunchAgent: { RemoteSettingsState() },
        enableRemote: { _ in RemoteSettingsState() },
        setLANEnabled: { _ in RemoteSettingsState() }
    )
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    @Bindable var model: EngineViewModel

    @State private var theme: Theme.AppearanceTheme = .system
    @State private var density: Theme.DensityMode = .comfortable
    @State private var fontFamily: Theme.FontFamily = .rounded
    @State private var floatingCornerStyle: Theme.FloatingCornerStyle = .standard
    @State private var fontScale: Double = 1.0
    @State private var showUsage: Bool = false
    @State private var reduceMotion: Bool = false
    @State private var showSilentLog: Bool = false

    var body: some View {
        Form {
            Picker("Theme", selection: $theme) {
                Text("System").tag(Theme.AppearanceTheme.system)
                Text("Light").tag(Theme.AppearanceTheme.light)
                Text("Dark").tag(Theme.AppearanceTheme.dark)
            }
            .onChange(of: theme) { _, new in
                model.send(.updateAppearancePref(key: .theme, value: .string(new.rawValue)))
            }

            Picker("Density", selection: $density) {
                Text("Comfortable").tag(Theme.DensityMode.comfortable)
                Text("Compact").tag(Theme.DensityMode.compact)
            }
            .onChange(of: density) { _, new in
                model.send(.updateAppearancePref(key: .densityMode, value: .string(new.rawValue)))
            }

            Picker("Font", selection: $fontFamily) {
                ForEach(Theme.FontFamily.allCases) { family in
                    Text(family.displayName).tag(family)
                }
            }
            .onChange(of: fontFamily) { _, new in
                model.send(.updateAppearancePref(key: .fontFamily, value: .string(new.rawValue)))
            }
            .accessibilityLabel("Font family for the sidebar, conversation, and diff panel")

            Picker("Popover corners", selection: $floatingCornerStyle) {
                ForEach(Theme.FloatingCornerStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .onChange(of: floatingCornerStyle) { _, new in
                model.send(.updateAppearancePref(key: .floatingCornerStyle, value: .string(new.rawValue)))
            }
            .accessibilityLabel("Corner radius for popovers, palettes, and dropdown panels")

            HStack {
                Text("Font scale")
                Slider(value: $fontScale, in: 0.8...1.4, step: 0.1)
                Text("\(Int(fontScale * 100))%").monospacedDigit()
            }
            .onChange(of: fontScale) { _, new in
                model.send(.updateAppearancePref(key: .fontSizeScale, value: .double(new)))
            }

            Toggle("Show token usage chip", isOn: $showUsage)
                .onChange(of: showUsage) { _, new in
                    model.send(.updateAppearancePref(key: .showUsageChip, value: .bool(new)))
                }

            Toggle("Reduce motion", isOn: $reduceMotion)
                .onChange(of: reduceMotion) { _, new in
                    model.send(.updateAppearancePref(key: .reduceMotion, value: .bool(new)))
                }

            Toggle("Show silent recovery log", isOn: $showSilentLog)
                .onChange(of: showSilentLog) { _, new in
                    model.send(.updateAppearancePref(key: .showSilentRecoveryLog, value: .bool(new)))
                }
        }
        .formStyle(.grouped)
        .task {
            theme = model.appearancePrefs.theme
            density = model.appearancePrefs.densityMode
            fontFamily = model.appearancePrefs.fontFamily
            floatingCornerStyle = model.appearancePrefs.floatingCornerStyle
            fontScale = model.appearancePrefs.fontSizeScale
            showUsage = model.appearancePrefs.showUsageChip
            reduceMotion = model.appearancePrefs.reduceMotion
            showSilentLog = model.appearancePrefs.showSilentRecoveryLog
        }
    }
}

// MARK: - Permissions

private struct PermissionsSettingsTab: View {
    @Bindable var model: EngineViewModel
    @State private var rules: [AutoApprovalRule] = []
    @State private var draftMatch: String = ""
    @State private var draftDecision: PermissionDecision = .allow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            Text("Auto-approval rules")
                .font(Theme.typography.label)
            Text("Glob pattern matched against `ToolName ArgumentsSummary`. First match wins.")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)

            List {
                ForEach($rules) { $rule in
                    HStack {
                        Toggle("", isOn: $rule.enabled).labelsHidden()
                        TextField("Pattern", text: $rule.match)
                            .font(Theme.typography.monoSmall)
                            .fontDesign(.monospaced)
                        Picker("", selection: $rule.decision) {
                            Text("Allow").tag(PermissionDecision.allow)
                            Text("Allow Always").tag(PermissionDecision.allowAlways)
                            Text("Deny").tag(PermissionDecision.deny)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        Button(action: { rules.removeAll { $0.id == rule.id } }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove rule")
                    }
                }
            }
            .frame(minHeight: Theme.layout.remoteSettingsMinHeight)

            HStack {
                TextField("New pattern…", text: $draftMatch)
                    .font(Theme.typography.monoSmall)
                    .fontDesign(.monospaced)
                Picker("", selection: $draftDecision) {
                    Text("Allow").tag(PermissionDecision.allow)
                    Text("Deny").tag(PermissionDecision.deny)
                }
                .labelsHidden()
                .frame(width: 120)
                Button("Add") {
                    rules.append(AutoApprovalRule(match: draftMatch, decision: draftDecision))
                    draftMatch = ""
                }
                .disabled(draftMatch.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button("Save") {
                model.send(.updateAutoApprovalRules(rules))
                model.syncAutoApprovalRules(rules)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .task { rules = model.autoApprovalRules }
    }
}

// MARK: - Remote

private struct RemoteSettingsTab: View {
    @Bindable var model: EngineViewModel
    let actions: RemoteSettingsActions

    @State private var remoteEnabled: Bool = false
    @State private var lanEnabled: Bool = false
    @State private var state = RemoteSettingsState()

    var body: some View {
        Form {
            Section("Access") {
                Toggle("Enable remote access", isOn: $remoteEnabled)
                    .onChange(of: remoteEnabled) { _, enabled in
                        Task { state = await actions.enableRemote(enabled) }
                    }
                    .accessibilityLabel("Enable or disable WebSocket remote-control server")
            }
            Section("Pairing") {
                HStack {
                    Text("PIN")
                    Spacer()
                    Text(state.pin ?? "••••••")
                        .font(Theme.typography.monoSmall)
                        .fontDesign(.monospaced)
                        .foregroundStyle(state.pin == nil ? Theme.text.tertiary : Theme.text.primary)
                    Button("Pair New Device") {
                        Task {
                            state = await actions.startPairing()
                            remoteEnabled = state.remoteEnabled
                            lanEnabled = state.lanEnabled
                        }
                    }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                if let pin = state.pin {
                    HStack(alignment: .top, spacing: Theme.spacing.s16) {
                        if let pairingURL = state.pairingURL,
                           let image = QRCodeRenderer().image(for: pairingURL) {
                            Image(nsImage: image)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 160, height: 160)
                                .accessibilityLabel("Pairing QR code")
                        }
                        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
                            Text("PIN expires after 90 seconds. Scan the QR code or enter this PIN and fingerprint manually.")
                                .font(Theme.typography.caption)
                                .foregroundStyle(Theme.text.secondary)
                                .textSelection(.enabled)
                                .accessibilityLabel("Pairing PIN \(pin)")
                            if let pairingURL = state.pairingURL {
                                Text(pairingURL)
                                    .font(Theme.typography.monoSmall)
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(Theme.text.tertiary)
                                    .textSelection(.enabled)
                                    .lineLimit(3)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
                HStack {
                    Text("Cert fingerprint")
                    Spacer()
                    Text(state.certificateFingerprint ?? "—")
                        .font(Theme.typography.monoSmall)
                        .fontDesign(.monospaced)
                        .foregroundStyle(Theme.text.tertiary)
                        .textSelection(.enabled)
                }
            }
            Section("Network") {
                Toggle("Allow LAN access (\(RemoteDefaults.lanBindHost))", isOn: $lanEnabled)
                    .onChange(of: lanEnabled) { _, enabled in
                        Task { state = await actions.setLANEnabled(enabled) }
                    }
                    .disabled(!remoteEnabled)
                    .accessibilityLabel("Bind server to all network interfaces for LAN access")
                LabeledContent("Port", value: "\(RemoteDefaults.webSocketPort)")
                LabeledContent("Connected clients", value: "\(state.connectedClientCount)")
            }
            Section("Daemon") {
                LabeledContent("Enable on login",
                               value: state.launchAgentInstalled ? "Installed" : "Not installed")
                HStack {
                    Button("Install LaunchAgent") {
                        Task { state = await actions.installLaunchAgent() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.launchAgentInstalled)
                    Button("Uninstall") {
                        Task { state = await actions.uninstallLaunchAgent() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!state.launchAgentInstalled)
                }
                if let detail = state.launchAgentDetail {
                    Text(detail)
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.text.secondary)
                }
            }
            Section("Paired devices") {
                if state.pairedDevices.isEmpty {
                    Text("No devices paired yet.")
                        .foregroundStyle(Theme.text.secondary)
                } else {
                    ForEach(state.pairedDevices) { device in
                        HStack {
                            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                                Text(device.name)
                                    .font(Theme.typography.label)
                                Text(device.lastSeen.formatted(date: .abbreviated, time: .shortened))
                                    .font(Theme.typography.caption)
                                    .foregroundStyle(Theme.text.tertiary)
                            }
                            Spacer()
                            Button("Revoke", role: .destructive) {
                                Task { state = await actions.revoke(device.id) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityLabel("Revoke \(device.name)")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            state = await actions.refresh()
            remoteEnabled = state.remoteEnabled
            lanEnabled = state.lanEnabled
        }
    }
}

// MARK: - Workspace

private struct WorkspaceSettingsTab: View {
    @Bindable var model: EngineViewModel

    var body: some View {
        Form {
            Section("Models") {
                if model.workspaceRoot == nil {
                    Text("Open a workspace to manage cached model catalogs.")
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.text.secondary)
                } else {
                    ForEach(model.workspaceModelCatalogRows) { row in
                        modelRow(row)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await model.reloadWorkspaceModelCatalogStatus()
        }
        .onChange(of: model.workspaceRoot?.path) { _, _ in
            Task { await model.reloadWorkspaceModelCatalogStatus() }
        }
    }

    @ViewBuilder
    private func modelRow(_ row: EngineViewModel.WorkspaceModelCatalogRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            HStack {
                Text(row.displayName)
                    .font(Theme.typography.label)
                Spacer()
                Text(modelCountLabel(row))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
            }
            switch row.refreshKind {
            case .automatic:
                Text("Refreshes automatically")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                Button("Refresh") {}
                    .disabled(true)
                    .accessibilityLabel("\(row.displayName) model refresh is automatic")
            case .manual(let detail):
                Text(detail)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                if let refreshedAt = row.refreshedAt {
                    Text("Last refreshed \(refreshedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.text.tertiary)
                } else {
                    Text("Not refreshed yet for this workspace")
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.text.tertiary)
                }
                Button(model.modelCatalogRefreshInFlight == row.agentID ? "Refreshing…" : "Refresh models") {
                    Task { await model.refreshAdapterModels(for: row.agentID) }
                }
                .disabled(model.modelCatalogRefreshInFlight != nil)
                .accessibilityLabel("Refresh \(row.displayName) models")
            }
        }
        .padding(.vertical, Theme.spacing.s4)
    }

    private func modelCountLabel(_ row: EngineViewModel.WorkspaceModelCatalogRow) -> String {
        switch row.modelCount {
        case 0: return "No models cached"
        case 1: return "1 model"
        default: return "\(row.modelCount) models"
        }
    }
}

// MARK: - Claude

private struct ClaudeSettingsTab: View {
    var body: some View {
        Form {
            Section("Claude Code") {
                LabeledContent("Binary", value: "claude (auto-located)")
                LabeledContent("Settings file", value: "~/.claude/settings.json")
                LabeledContent("Transcript dir", value: "~/.claude/projects/")
            }
            Section("Status") {
                Text("Codemixer never edits Claude's settings outside the managed hook block.")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
        }
        .formStyle(.grouped)
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
