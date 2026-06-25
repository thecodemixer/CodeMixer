import Foundation
import OSLog

/// Decorator that wraps any `NetworkTransport` with structured OSLog spans on
/// every connect / accept / send / receive / close / error.
///
/// Usage:
///
///     let transport = LoggingNetworkTransport(
///         wrapping: LiveNetworkTransport(),
///         subsystem: AppIdentity.logSubsystem,
///         category: "Remote"
///     )
///
/// Log volume is bounded — payload bodies are summarised as
/// `<bytes=N first-bytes=...>` rather than fully dumped, so PII never leaks
/// into Console.app at this layer.
public struct LoggingNetworkTransport: NetworkTransport {

    private let wrapped: any NetworkTransport
    private let log: Logger

    public init(wrapping wrapped: any NetworkTransport,
                subsystem: String = AppIdentity.logSubsystem,
                category: String = "Network") {
        self.wrapped = wrapped
        self.log = Logger(subsystem: subsystem, category: category)
    }

    public func listen(on address: NetworkAddress,
                       options: NetworkOptions) async throws -> NetworkListenerHandle {
        log.notice("listen begin address=\(String(describing: address), privacy: .public) kind=\(String(describing: options.kind), privacy: .public) tls=\(options.tls != nil)")
        do {
            let handle = try await wrapped.listen(on: address, options: options)
            log.notice("listen ready port=\(handle.port, privacy: .public)")
            let log = self.log

            let (stream, continuation) = AsyncStream<any NetworkConnection>
                .makeStream(bufferingPolicy: .bufferingNewest(StreamBufferDefaults.networkConnections))
            Task {
                for await connection in handle.connections {
                    log.info("accept id=\(connection.id, privacy: .public) peer=\(connection.remoteDescription, privacy: .public)")
                    continuation.yield(LoggingNetworkConnection(wrapping: connection, log: log))
                }
                continuation.finish()
            }
            let cancel: @Sendable () async -> Void = {
                log.notice("listen cancel port=\(handle.port, privacy: .public)")
                await handle.cancel()
                continuation.finish()
            }
            return NetworkListenerHandle(connections: stream,
                                         port: handle.port,
                                         cancel: cancel)
        } catch {
            log.error("listen failed address=\(String(describing: address), privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    public func connect(to address: NetworkAddress,
                        options: NetworkOptions) async throws -> any NetworkConnection {
        log.notice("connect begin address=\(String(describing: address), privacy: .public) kind=\(String(describing: options.kind), privacy: .public)")
        do {
            let connection = try await wrapped.connect(to: address, options: options)
            log.notice("connect ready id=\(connection.id, privacy: .public) peer=\(connection.remoteDescription, privacy: .public)")
            return LoggingNetworkConnection(wrapping: connection, log: log)
        } catch {
            log.error("connect failed address=\(String(describing: address), privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }
}

private final class LoggingNetworkConnection: NetworkConnection, @unchecked Sendable {

    let id: UUID
    let remoteDescription: String
    let metadata: NetworkConnectionMetadata

    private let wrapped: any NetworkConnection
    private let log: Logger

    init(wrapping wrapped: any NetworkConnection, log: Logger) {
        self.wrapped = wrapped
        self.log = log
        self.id = wrapped.id
        self.remoteDescription = wrapped.remoteDescription
        self.metadata = wrapped.metadata
    }

    func send(_ data: Data) async throws {
        let preview = preview(of: data)
        do {
            try await wrapped.send(data)
            log.debug("send id=\(self.id, privacy: .public) bytes=\(data.count) preview=\(preview, privacy: .public)")
        } catch {
            log.error("send failed id=\(self.id, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func receive() async throws -> Data? {
        do {
            let data = try await wrapped.receive()
            if let data {
                log.debug("recv id=\(self.id, privacy: .public) bytes=\(data.count) preview=\(self.preview(of: data), privacy: .public)")
            } else {
                log.info("recv eof id=\(self.id, privacy: .public)")
            }
            return data
        } catch {
            log.error("recv failed id=\(self.id, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func close() async {
        log.info("close id=\(self.id, privacy: .public)")
        await wrapped.close()
    }

    private func preview(of data: Data) -> String {
        // Up to 24 printable ASCII bytes — enough to read the frame tag at a
        // glance, never enough to leak prompt contents.
        let prefix = data.prefix(24)
        let ascii = String(decoding: prefix, as: UTF8.self).filter { $0.isASCII }
        return ascii.isEmpty ? "<binary>" : ascii
    }
}
