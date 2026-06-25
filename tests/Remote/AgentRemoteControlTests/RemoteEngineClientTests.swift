import Testing
import Foundation
@testable import AgentRemoteControl
@testable import AgentCore
@testable import AgentProtocol

@Suite("RemoteEngineClient", .serialized)
struct RemoteEngineClientTests {

    @Test("sends commands and republishes remote events")
    func sendsCommandsAndRepublishesEvents() async throws {
        let net = InMemoryNetwork()
        let seams = Seams.fake()
        let engine = AgentEngine(seams: seams)
        await engine.bootstrap()
        let pairing = PairingService(clock: seams.clock, random: seams.random)
        let server = RemoteControlServer(engine: engine,
                                         bus: engine.bus,
                                         pairing: pairing,
                                         transport: net.transport)
        try await server.start(configuration: .init(host: .loopback,
                                                    port: 0,
                                                    requireAuth: false,
                                                    useTLS: false))
        let port = try #require(await server.boundPort)

        let client = RemoteEngineClient(
            configuration: .init(address: .loopback(port: port),
                                 options: .webSocket()),
            transport: net.transport
        )
        try await client.connect()
        let sub = await client.bus.subscribe()

        try await client.send(.updateAppearancePref(key: .theme, value: .string("remote")))

        let event = await nextEvent(from: sub.stream)
        let sawEvent: Bool
        if case .appearancePrefChanged(let key, let value) = event {
            sawEvent = key == .theme && value == .string("remote")
        } else {
            sawEvent = false
        }
        #expect(sawEvent)

        await client.disconnect()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    @Test("disconnect resolves a pending command with disconnected")
    func disconnectResolvesPendingCommand() async throws {
        let net = InMemoryNetwork()
        let listener = try await net.transport.listen(on: .loopback(port: 0), options: .plainWebSocket)
        defer { Task { await listener.cancel() } }

        let accepted = Task<(any NetworkConnection)?, Never> {
            for await connection in listener.connections {
                return connection
            }
            return nil
        }

        let client = RemoteEngineClient(
            configuration: .init(address: .loopback(port: listener.port),
                                 options: .webSocket()),
            transport: net.transport
        )
        try await client.connect()
        let serverConnection = try #require(await accepted.value)

        let commandTask = Task {
            try await client.send(.updateAppearancePref(key: .theme, value: .string("remote")))
        }

        try await Task.sleep(for: .milliseconds(100))
        await serverConnection.close()

        let resolved = await commandTaskResolvesDisconnected(commandTask)
        #expect(resolved)
        await client.disconnect()
    }

    private func nextEvent(from stream: AsyncStream<AgentEvent>) async -> AgentEvent? {
        await withTaskGroup(of: AgentEvent?.self) { group in
            group.addTask {
                for await event in stream {
                    return event
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func commandTaskResolvesDisconnected(_ task: Task<Void, any Error>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await task.value
                    return false
                } catch RemoteEngineClient.ClientError.disconnected {
                    return true
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                task.cancel()
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
