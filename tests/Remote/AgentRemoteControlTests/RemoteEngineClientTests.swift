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

        try await client.send(.updateAppearancePref(.theme("remote")))

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
            try await client.send(.updateAppearancePref(.theme("remote")))
        }

        try await Task.sleep(for: .milliseconds(100))
        await serverConnection.close()

        let resolved = await commandTaskResolvesDisconnected(commandTask)
        #expect(resolved)
        await client.disconnect()
    }

    @Test("checkpointExpired subscribe republishes engineRestarted and snapshots")
    func checkpointExpiredResync() async throws {
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

        for _ in 0..<8 {
            _ = await engine.bus.publish(.bell)
        }
        let staleID = UUID()

        let client = RemoteEngineClient(
            configuration: .init(address: .loopback(port: port),
                                 options: .webSocket()),
            transport: net.transport
        )
        await client.setLastSeenEventID(staleID)
        let sub = await client.bus.subscribe()
        let collector = ResyncCollector()

        let collect = Task {
            for await entry in sub.stream {
                await collector.record(entry.event)
                if await collector.isComplete { break }
            }
        }

        try await client.connect()

        try? await Task.sleep(for: .seconds(2))
        collect.cancel()

        #expect(await collector.sawRestart)
        #expect(await collector.snapshotKinds.contains(.conversation))
        #expect(await collector.snapshotKinds.contains(.diff))
        #expect(await collector.snapshotKinds.contains(.prefs))

        await client.disconnect()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    private func nextEvent(from stream: AsyncStream<MulticastEventBus.HistoryEntry>) async -> AgentEvent? {
        await withTaskGroup(of: AgentEvent?.self) { group in
            group.addTask {
                for await entry in stream {
                    return entry.event
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

private actor ResyncCollector {
    private(set) var sawRestart = false
    private(set) var snapshotKinds = Set<SnapshotKind>()

    func record(_ event: AgentEvent) {
        switch event {
        case .engineRestarted:
            sawRestart = true
        case .snapshotReady(let kind, _):
            snapshotKinds.insert(kind)
        default:
            break
        }
    }

    var isComplete: Bool {
        sawRestart && snapshotKinds.isSuperset(of: [.conversation, .diff, .prefs])
    }
}
