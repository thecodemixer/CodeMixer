import SwiftUI
import AgentCore

/// Remote tab: enable/disable the WebSocket server, LAN binding, pairing
/// (PIN + QR), certificate fingerprint, LaunchAgent install state, and the
/// paired-device list. All state round-trips through `RemoteSettingsActions`
/// so this view holds no daemon/pairing logic of its own.
struct RemoteSettingsTab: View {
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
