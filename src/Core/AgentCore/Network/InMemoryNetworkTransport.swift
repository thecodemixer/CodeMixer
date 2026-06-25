import Foundation

/// In-process `NetworkTransport` used by tests.
///
/// A single `InMemoryNetwork` instance acts as the shared "internet" — both
/// sides of a connection are wired through it. Frames sent on one connection
/// arrive verbatim on its peer; no encoding, no TCP, no flake.
///
/// Typical use:
///
///     let net = InMemoryNetwork()
///     let server = RemoteControlServer(..., transport: net.transport)
///     try await server.start(configuration: .init(host: .loopback, port: 0))
///     let client = try await net.transport.connect(to: .loopback(port: 0),
///                                                  options: .plainWebSocket)
public final class InMemoryNetwork: @unchecked Sendable {

    public init() {}

    /// A `NetworkTransport` view over this shared network.
    public var transport: any NetworkTransport { InMemoryTransport(network: self) }

    // MARK: - Internals

    private let lock = NSLock()
    private var listeners: [UInt16: ListenerEntry] = [:]
    private var unixListeners: [String: ListenerEntry] = [:]
    private var nextEphemeral: UInt16 = 49_000

    fileprivate func register(port requested: UInt16,
                              acceptor: @escaping @Sendable (InMemoryConnection) -> Void) -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        let port = requested == 0 ? allocateEphemeral() : requested
        listeners[port] = ListenerEntry(acceptor: acceptor)
        return port
    }

    fileprivate func deregister(port: UInt16) {
        lock.lock(); defer { lock.unlock() }
        listeners.removeValue(forKey: port)
    }

    fileprivate func acceptor(for port: UInt16) -> (@Sendable (InMemoryConnection) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return listeners[port]?.acceptor
    }

    fileprivate func registerUnix(path: String,
                                  acceptor: @escaping @Sendable (InMemoryConnection) -> Void) {
        lock.lock(); defer { lock.unlock() }
        unixListeners[path] = ListenerEntry(acceptor: acceptor)
    }

    fileprivate func deregisterUnix(path: String) {
        lock.lock(); defer { lock.unlock() }
        unixListeners.removeValue(forKey: path)
    }

    fileprivate func unixAcceptor(for path: String) -> (@Sendable (InMemoryConnection) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return unixListeners[path]?.acceptor
    }

    private func allocateEphemeral() -> UInt16 {
        while listeners[nextEphemeral] != nil { nextEphemeral &+= 1 }
        let port = nextEphemeral
        nextEphemeral &+= 1
        return port
    }

    private struct ListenerEntry {
        let acceptor: @Sendable (InMemoryConnection) -> Void
    }
}

// MARK: - Transport

private struct InMemoryTransport: NetworkTransport {

    let network: InMemoryNetwork

    func listen(on address: NetworkAddress,
                options: NetworkOptions) async throws -> NetworkListenerHandle {
        let (stream, continuation) = AsyncStream<any NetworkConnection>
            .makeStream(bufferingPolicy: .bufferingNewest(StreamBufferDefaults.networkConnections))

        let acceptor: @Sendable (InMemoryConnection) -> Void = { server in
            continuation.yield(server)
        }
        let network = network
        switch address {
        case .unixSocket(let path):
            network.registerUnix(path: path, acceptor: acceptor)
            let cancel: @Sendable () async -> Void = {
                network.deregisterUnix(path: path)
                continuation.finish()
            }
            return NetworkListenerHandle(connections: stream, port: 0, cancel: cancel)
        case .loopback, .lan, .host:
            let port = network.register(port: address.port, acceptor: acceptor)
            let cancel: @Sendable () async -> Void = {
                network.deregister(port: port)
                continuation.finish()
            }
            return NetworkListenerHandle(connections: stream, port: port, cancel: cancel)
        }
    }

    func connect(to address: NetworkAddress,
                 options: NetworkOptions) async throws -> any NetworkConnection {
        switch address {
        case .unixSocket(let path):
            guard let acceptor = network.unixAcceptor(for: path) else {
                throw NetworkTransportError.connectFailed(detail: "no listener at \(path)")
            }
            let pair = InMemoryConnection.pair(label: address.description,
                                               clientMetadata: .empty,
                                               serverMetadata: options.metadata)
            acceptor(pair.server)
            return pair.client
        case .loopback, .lan, .host:
            guard let acceptor = network.acceptor(for: address.port) else {
                throw NetworkTransportError.connectFailed(detail: "no listener on port \(address.port)")
            }
            let pair = InMemoryConnection.pair(label: address.description,
                                               clientMetadata: .empty,
                                               serverMetadata: options.metadata)
            acceptor(pair.server)
            return pair.client
        }
    }
}

// MARK: - Connection pair

/// In-process connection backed by a tiny mailbox actor. Each side owns one
/// `Mailbox` for its inbound queue; `send` enqueues on the peer's mailbox.
/// `receive` is a single-consumer dequeue with continuation-based suspension.
final class InMemoryConnection: NetworkConnection, @unchecked Sendable {

    let id = UUID()
    let remoteDescription: String
    let metadata: NetworkConnectionMetadata

    private let inbox: Mailbox
    private let outbox: Mailbox

    init(label: String,
         inbox: Mailbox,
         outbox: Mailbox,
         metadata: NetworkConnectionMetadata) {
        self.remoteDescription = "mem://\(label)/\(UUID().uuidString.prefix(8))"
        self.inbox = inbox
        self.outbox = outbox
        self.metadata = metadata
    }

    func send(_ data: Data) async throws {
        try await outbox.enqueue(data)
    }

    func receive() async throws -> Data? {
        await inbox.dequeue()
    }

    func close() async {
        await inbox.close()
        await outbox.close()
    }

    /// Wire two `InMemoryConnection`s so each one's `send` shows up on the
    /// other's `receive`. Returns the (client, server) pair.
    static func pair(label: String,
                     clientMetadata: NetworkConnectionMetadata,
                     serverMetadata: NetworkConnectionMetadata) -> (client: InMemoryConnection, server: InMemoryConnection) {
        let clientInbox = Mailbox()
        let serverInbox = Mailbox()
        let client = InMemoryConnection(label: label,
                                        inbox: clientInbox,
                                        outbox: serverInbox,
                                        metadata: clientMetadata)
        let server = InMemoryConnection(label: label,
                                        inbox: serverInbox,
                                        outbox: clientInbox,
                                        metadata: serverMetadata)
        return (client, server)
    }
}

/// Tiny single-consumer mailbox. Used to glue an `InMemoryConnection`'s
/// `send` on one side to `receive` on the other.
actor Mailbox {
    private var buffer: [Data] = []
    private var waiter: CheckedContinuation<Data?, Never>?
    private var closed = false

    func enqueue(_ data: Data) throws {
        guard !closed else { throw NetworkTransportError.closed }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
        } else {
            buffer.append(data)
        }
    }

    func dequeue() async -> Data? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if closed { return nil }
        return await withCheckedContinuation { c in
            waiter = c
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }
}
