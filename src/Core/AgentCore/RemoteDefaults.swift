import Foundation

/// Product defaults for local remote-control surfaces.
///
/// The WebSocket and HTTP sidecar ports are user-visible and documented in
/// setup flows, so they have one owner instead of being repeated in clients.
public enum RemoteDefaults {
    public static let webSocketPort: UInt16 = 8421
    public static let sidecarPort: UInt16 = 8422
    public static let webSocketPath = "/v1/ws"
    public static let loopbackHost = "127.0.0.1"
    public static let lanBindHost = "0.0.0.0"
}
