import Foundation
import AgentProtocol

/// Product defaults for local remote-control surfaces.
///
/// The WebSocket and HTTP sidecar ports are user-visible and documented in
/// setup flows, so they have one owner instead of being repeated in clients.
public enum RemoteDefaults {
    public static let webSocketPort: UInt16 = 8421
    public static let sidecarPort: UInt16 = 8422
    public static let webSocketPath = "/v1/ws"
    public static let healthPath = "/v1/health"
    public static let attachmentsPath = "/v1/attachments"
    public static let silentDiagnosticsPath = "/v1/diagnostics/silent"
    public static let loopbackHost = "127.0.0.1"
    public static let lanBindHost = "0.0.0.0"

    /// Bonjour service type advertised on the LAN (`_codemixer._tcp`).
    public static let bonjourServiceType = "_codemixer._tcp"
    public static let bonjourServiceName = "Codemixer"
    /// TXT `v` field — must match `WireVersion.current` for client pairing.
    public static let bonjourTXTVersion = String(WireVersion.current.rawValue)
}
