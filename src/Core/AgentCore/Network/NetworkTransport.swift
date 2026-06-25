import Foundation
import Security

/// Single seam for everything network-shaped in Codemixer.
///
/// Three concrete implementations live alongside this protocol:
///   * `LiveNetworkTransport` — production: `NWListener` + `NWConnection`.
///   * `LoggingNetworkTransport` — decorator emitting OSLog spans on every
///     connect / send / receive / close / error.
///   * `InMemoryNetworkTransport` — deterministic, in-process pipes for tests.
///
/// All three speak the same surface, so swapping them out is a single line in
/// `RemoteControlServer` / `HTTPSidecarServer` / `ClientConnection`. Tests get
/// fast, fast, predictable end-to-end coverage; production keeps real Network
/// framework semantics; logging is just a wrapper.
public protocol NetworkTransport: Sendable {

    /// Begin accepting inbound connections at `address`. The returned handle
    /// streams every accepted connection until `cancel()` is called.
    func listen(on address: NetworkAddress,
                options: NetworkOptions) async throws -> NetworkListenerHandle

    /// Establish an outbound connection. Resolves once the handshake (TLS,
    /// WebSocket, etc.) completes — the returned connection is immediately
    /// ready for `send` / `receive`.
    func connect(to address: NetworkAddress,
                 options: NetworkOptions) async throws -> any NetworkConnection
}

// MARK: - Connection

/// A duplex byte/message channel. Frame semantics are determined by
/// `NetworkOptions.kind`:
///   * `.webSocket`: each `send` / `receive` is one logical WS message.
///   * `.tcp`:       each call is an opportunistic byte chunk (HTTP-style).
public protocol NetworkConnection: AnyObject, Sendable {

    /// Stable identifier for logging / metrics. Generated at connection birth.
    var id: UUID { get }

    /// Human-readable peer description (host + port, or `mem://port/uuid`).
    var remoteDescription: String { get }

    /// Transport-level request metadata, when the concrete transport can
    /// surface it. WebSocket clients use this for path + Authorization headers.
    var metadata: NetworkConnectionMetadata { get }

    /// Returns once the bytes have been handed to the OS / in-memory peer.
    func send(_ data: Data) async throws

    /// Returns the next inbound frame, or `nil` when the peer closes cleanly.
    /// Throws on protocol errors.
    func receive() async throws -> Data?

    /// Idempotent. Safe to call from any task.
    func close() async
}

public struct NetworkConnectionMetadata: Sendable, Hashable {
    public var path: String?
    public var headers: [String: String]

    public init(path: String? = nil, headers: [String: String] = [:]) {
        self.path = path
        self.headers = headers
    }

    public static let empty = NetworkConnectionMetadata()

    public var bearerToken: String? {
        let value = headers.first { key, _ in
            key.caseInsensitiveCompare("Authorization") == .orderedSame
        }?.value
        guard let value, value.lowercased().hasPrefix("bearer ") else { return nil }
        return String(value.dropFirst("Bearer ".count))
    }
}

public extension NetworkConnection {
    var metadata: NetworkConnectionMetadata { .empty }
}

// MARK: - Listener handle

/// What a `NetworkTransport.listen` call returns.
///
/// We use a struct of stored async streams + a cancel closure rather than a
/// protocol so decorators can wrap the connection stream with `map { ... }`
/// without inheriting an entire type.
///
/// `@unchecked Sendable`: contains `AsyncStream<any NetworkConnection>` whose
/// `Element` existential is not itself `Sendable`-constrained by the compiler,
/// but every concrete `NetworkConnection` the stream yields is `Sendable`.
public struct NetworkListenerHandle: @unchecked Sendable {
    /// Hot stream of accepted connections. Buffered so a slow consumer
    /// doesn't drop fresh peers on the floor.
    public let connections: AsyncStream<any NetworkConnection>

    /// Stop accepting and tear the listener down. Idempotent.
    public let cancel: @Sendable () async -> Void

    /// Bound port the listener is actually using — useful for tests that ask
    /// for an ephemeral port and need to dial it back.
    public let port: UInt16

    public init(connections: AsyncStream<any NetworkConnection>,
                port: UInt16,
                cancel: @escaping @Sendable () async -> Void) {
        self.connections = connections
        self.port = port
        self.cancel = cancel
    }
}

// MARK: - Address & options

/// Where to bind a listener / dial a peer.
public enum NetworkAddress: Sendable, CustomStringConvertible {
    /// Bind to / dial 127.0.0.1.
    case loopback(port: UInt16)
    /// Bind to / dial 0.0.0.0 (LAN-reachable). For dialing, the host is
    /// expected to be set via `.host(_:port:)` instead.
    case lan(port: UInt16)
    /// Explicit host (DNS or IP) and port.
    case host(String, port: UInt16)
    /// Unix-domain socket at `path`. Used by per-session hook servers so
    /// callers do not have to touch `NWListener` / `NWConnection` directly.
    case unixSocket(path: String)

    public var port: UInt16 {
        switch self {
        case .loopback(let p), .lan(let p), .host(_, let p): return p
        case .unixSocket: return 0
        }
    }

    public var description: String {
        switch self {
        case .loopback(let p):    return "127.0.0.1:\(p)"
        case .lan(let p):         return "0.0.0.0:\(p)"
        case .host(let h, let p): return "\(h):\(p)"
        case .unixSocket(let p):  return "unix://\(p)"
        }
    }
}

/// What kind of connection to negotiate and whether to wrap it in TLS.
public struct NetworkOptions: Sendable {
    /// Frame model — see `NetworkConnection` for semantics.
    public enum Kind: Sendable { case webSocket, tcp }

    public var kind: Kind
    public var tls: TLSConfiguration?
    public var metadata: NetworkConnectionMetadata

    public init(kind: Kind,
                tls: TLSConfiguration? = nil,
                metadata: NetworkConnectionMetadata = .empty) {
        self.kind = kind
        self.tls = tls
        self.metadata = metadata
    }

    public static let plainWebSocket = NetworkOptions(kind: .webSocket, tls: nil)
    public static let plainTCP       = NetworkOptions(kind: .tcp, tls: nil)

    public static func webSocket(path: String = RemoteDefaults.webSocketPath,
                                 authorizationBearer token: String? = nil,
                                 tls: TLSConfiguration? = nil) -> NetworkOptions {
        var headers: [String: String] = [:]
        if let token {
            headers["Authorization"] = "Bearer \(token)"
        }
        return NetworkOptions(kind: .webSocket,
                              tls: tls,
                              metadata: NetworkConnectionMetadata(path: path,
                                                                  headers: headers))
    }
}

/// TLS settings carried alongside a transport option.
///
/// Both server and client variants exist because servers need a `SecIdentity`
/// to present, while clients may want to pin a certificate fingerprint and
/// otherwise trust the system store.
public enum TLSConfiguration: @unchecked Sendable {
    /// Server-side: present this identity.
    case server(identity: SecIdentity)
    /// Client-side: trust any cert whose SHA-256 fingerprint matches.
    case pinnedFingerprint(String)
    /// Client-side: trust the system certificate store.
    case systemTrust
}

// MARK: - Errors

public enum NetworkTransportError: Error, Sendable {
    case listenFailed(detail: String)
    case connectFailed(detail: String)
    case sendFailed(detail: String)
    case receiveFailed(detail: String)
    case closed
    case unsupported(detail: String)
}
