import Foundation

/// Snapshot the Remote settings tab renders. The app layer (`CodemixerApp`)
/// owns the daemon/pairing/LaunchAgent state; this is the read-only view the
/// tab is handed back after every action.
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

/// App-layer callbacks the Remote settings tab invokes; every call returns the
/// resulting `RemoteSettingsState` so the tab never has to poll separately.
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
