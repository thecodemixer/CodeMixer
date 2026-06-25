import Foundation
import Testing
@testable import AgentCore

/// Wrapper boundary: `Network.NWListener`/`NWConnection` over Unix-domain
/// sockets. Covers both the in-memory and live transports so HookServer
/// callers can swap them out interchangeably.
@Suite("Unix-socket NetworkTransport")
struct UnixSocketTransportTests {

    @Test("InMemoryNetwork: bytes round-trip across a unix-socket path")
    func inMemoryRoundTrip() async throws {
        let net = InMemoryNetwork()
        let transport = net.transport
        let path = "/tmp/codemixer-uds-\(UUID().uuidString)"

        let handle = try await transport.listen(on: .unixSocket(path: path),
                                                options: .plainTCP)
        let serverTask = Task<Data?, Never> {
            for await connection in handle.connections {
                let data = try? await connection.receive()
                try? await connection.send(Data("pong".utf8))
                await connection.close()
                return data
            }
            return nil
        }
        let client = try await transport.connect(to: .unixSocket(path: path),
                                                 options: .plainTCP)
        try await client.send(Data("ping".utf8))
        let reply = try await client.receive()
        await client.close()
        await handle.cancel()

        #expect(reply == Data("pong".utf8))
        #expect(await serverTask.value == Data("ping".utf8))
    }

    @Test("Connect to missing unix-socket path throws connectFailed")
    func missingPathThrows() async {
        let net = InMemoryNetwork()
        do {
            _ = try await net.transport.connect(to: .unixSocket(path: "/no/such"),
                                                options: .plainTCP)
            Issue.record("expected throw")
        } catch let NetworkTransportError.connectFailed(detail) {
            #expect(detail.contains("/no/such"))
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test("LiveNetworkTransport accepts a connection from a parallel connect")
    func liveRoundTrip() async throws {
        let transport = LiveNetworkTransport()
        let path = NSTemporaryDirectory() + "codemixer-uds-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let handle = try await transport.listen(on: .unixSocket(path: path),
                                                options: .plainTCP)
        let serverTask = Task<Data?, Never> {
            for await connection in handle.connections {
                let data = try? await connection.receive()
                try? await connection.send(Data("pong".utf8))
                await connection.close()
                return data
            }
            return nil
        }
        let client = try await transport.connect(to: .unixSocket(path: path),
                                                 options: .plainTCP)
        try await client.send(Data("ping".utf8))
        let reply = try await client.receive()
        await client.close()

        // Bound a wait on the server task so a flake on Network.framework
        // doesn't hang the suite.
        let received = await withTaskGroup(of: Data?.self) { group in
            group.addTask { await serverTask.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                serverTask.cancel()
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
        await handle.cancel()

        #expect(reply == Data("pong".utf8))
        #expect(received == Data("ping".utf8))
    }
}
