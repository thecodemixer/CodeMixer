import Foundation
import CryptoKit
import Network
import Security

/// Production `NetworkTransport` backed by `NWListener` and `NWConnection`.
///
/// One actor instance is enough for the whole process. Listeners and
/// connections are independent objects, so two calls to `listen` happily
/// coexist on different ports.
public struct LiveNetworkTransport: NetworkTransport {

    private static let listenerReadyTimeout: DispatchTimeInterval = .seconds(5)

    public init() {}

    // MARK: - Listen

    public func listen(on address: NetworkAddress,
                       options: NetworkOptions) async throws -> NetworkListenerHandle {
        let parameters = parameters(for: options)
        switch address {
        case .loopback: parameters.requiredInterfaceType = .loopback
        case .lan, .host: break
        case .unixSocket(let path):
            parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        }

        let port = NWEndpoint.Port(rawValue: address.port) ?? .any

        let listener: NWListener
        do {
            if case .unixSocket = address {
                listener = try NWListener(using: parameters)
            } else {
                listener = try NWListener(using: parameters, on: port)
            }
        } catch {
            throw NetworkTransportError.listenFailed(detail: error.localizedDescription)
        }

        let (stream, continuation) = AsyncStream<any NetworkConnection>
            .makeStream(bufferingPolicy: .bufferingNewest(StreamBufferDefaults.networkConnections))

        listener.newConnectionHandler = { conn in
            conn.start(queue: .global(qos: .userInitiated))
            let wrapped = LiveNetworkConnection(connection: conn, options: options)
            continuation.yield(wrapped)
        }

        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            let gate = ReadinessContinuationGate(ready)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(returning: ())
                case .failed(let error), .waiting(let error):
                    continuation.finish()
                    gate.resume(throwing: NetworkTransportError.listenFailed(detail: error.localizedDescription))
                case .cancelled:
                    continuation.finish()
                    gate.resume(throwing: NetworkTransportError.closed)
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.listenerReadyTimeout) {
                if gate.resume(throwing: NetworkTransportError.listenFailed(detail: "timed out waiting for ready")) {
                    listener.cancel()
                    continuation.finish()
                }
            }
        }

        let resolvedPort = listener.port?.rawValue ?? address.port
        let cancel: @Sendable () async -> Void = {
            listener.cancel()
            continuation.finish()
        }
        return NetworkListenerHandle(connections: stream,
                                     port: resolvedPort,
                                     cancel: cancel)
    }

    // MARK: - Connect

    public func connect(to address: NetworkAddress,
                        options: NetworkOptions) async throws -> any NetworkConnection {
        let parameters = parameters(for: options)
        let endpoint = try makeEndpoint(for: address)
        let connection = NWConnection(to: endpoint, using: parameters)
        let wrapper = LiveNetworkConnection(connection: connection,
                                            options: options,
                                            startImmediately: false)
        try await wrapper.awaitReady()
        return wrapper
    }

    // MARK: - Internals

    private func parameters(for options: NetworkOptions) -> NWParameters {
        let parameters: NWParameters
        switch options.tls {
        case .server(let identity):
            let tls = NWProtocolTLS.Options()
            if let sec = sec_identity_create(identity) {
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec)
            }
            parameters = NWParameters(tls: tls)
        case .pinnedFingerprint(let expectedFingerprint):
            let tls = NWProtocolTLS.Options()
            let queue = DispatchQueue(label: AppIdentity.tlsPinQueueLabel)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { metadata, trust, complete in
                let serverTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let certificates = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] ?? []
                let matches = certificates.first.map { certificate in
                    let data = SecCertificateCopyData(certificate) as Data
                    return sha256Fingerprint(data) == expectedFingerprint
                } ?? false
                _ = metadata
                complete(matches)
            }, queue)
            parameters = NWParameters(tls: tls)
        case .systemTrust:
            // Trust-evaluation is provided by Network framework's defaults.
            parameters = NWParameters(tls: NWProtocolTLS.Options())
        case .none:
            parameters = .tcp
        }
        if options.kind == .webSocket {
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            if !options.metadata.headers.isEmpty {
                let headers = options.metadata.headers.map { (name: $0.key, value: $0.value) }
                ws.setAdditionalHeaders(headers)
            }
            parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        }
        return parameters
    }

    private func makeEndpoint(for address: NetworkAddress) throws -> NWEndpoint {
        switch address {
        case .loopback(let port):
            return .hostPort(host: .init(RemoteDefaults.loopbackHost),
                             port: try endpointPort(port))
        case .lan(let port):
            return .hostPort(host: .init(RemoteDefaults.lanBindHost),
                             port: try endpointPort(port))
        case .host(let host, let port):
            return .hostPort(host: .init(host),
                             port: try endpointPort(port))
        case .unixSocket(let path):
            return .unix(path: path)
        }
    }

    private func endpointPort(_ port: UInt16) throws -> NWEndpoint.Port {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NetworkTransportError.connectFailed(detail: "invalid port \(port)")
        }
        return endpointPort
    }
}

private func sha256Fingerprint(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02X", $0) }
        .joined(separator: ":")
}

// MARK: - Connection wrapper

final class LiveNetworkConnection: NetworkConnection, @unchecked Sendable {

    private static let readinessTimeout: DispatchTimeInterval = .seconds(5)

    let id = UUID()
    let connection: NWConnection
    let options: NetworkOptions
    let metadata: NetworkConnectionMetadata

    private let lock = NSLock()
    private var closed = false

    init(connection: NWConnection, options: NetworkOptions, startImmediately: Bool = true) {
        self.connection = connection
        self.options = options
        self.metadata = options.metadata
        if startImmediately, connection.state != .ready {
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    var remoteDescription: String {
        switch connection.endpoint {
        case .hostPort(let host, let port): return "\(host):\(port.rawValue)"
        default: return "\(connection.endpoint)"
        }
    }

    func awaitReady() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ReadinessContinuationGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume(returning: ())
                case .failed(let error), .waiting(let error):
                    gate.resume(throwing: NetworkTransportError.connectFailed(detail: error.localizedDescription))
                case .cancelled:
                    gate.resume(throwing: NetworkTransportError.closed)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.readinessTimeout) {
                if gate.resume(throwing: NetworkTransportError.connectFailed(detail: "timed out waiting for ready")) {
                    self.connection.cancel()
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        guard !isClosed else { throw NetworkTransportError.closed }
        let context: NWConnection.ContentContext
        switch options.kind {
        case .webSocket:
            let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
            context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        case .tcp:
            context = .defaultMessage
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data,
                            contentContext: context,
                            isComplete: true,
                            completion: .contentProcessed { error in
                if let error {
                    c.resume(throwing: NetworkTransportError.sendFailed(detail: error.localizedDescription))
                } else {
                    c.resume()
                }
            })
        }
    }

    func receive() async throws -> Data? {
        guard !isClosed else { return nil }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
            switch options.kind {
            case .webSocket:
                connection.receiveMessage { data, _, isComplete, error in
                    if let error {
                        c.resume(throwing: NetworkTransportError.receiveFailed(detail: error.localizedDescription))
                    } else if isComplete && (data?.isEmpty ?? true) {
                        c.resume(returning: nil)
                    } else {
                        c.resume(returning: data)
                    }
                }
            case .tcp:
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let error {
                        c.resume(throwing: NetworkTransportError.receiveFailed(detail: error.localizedDescription))
                    } else if isComplete && (data?.isEmpty ?? true) {
                        c.resume(returning: nil)
                    } else {
                        c.resume(returning: data)
                    }
                }
            }
        }
    }

    func close() async {
        guard markClosed() else { return }
        connection.cancel()
    }

    private func markClosed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        closed = true
        return true
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }
}

private final class ReadinessContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(returning value: Void) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
        return true
    }

    @discardableResult
    func resume(throwing error: any Error) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
        return true
    }
}
