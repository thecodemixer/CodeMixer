import Testing
import Foundation
@testable import AgentRemoteControl
@testable import AgentCore
@testable import AgentProtocol
import AgentTestSupport

/// End-to-end coverage of the WebSocket dispatch path using the
/// `InMemoryNetworkTransport` seam — no real sockets, fully deterministic.
///
/// `.serialized` prevents races between the three tests; the server and
/// client tasks must not share the in-memory listener state concurrently.
@Suite("RemoteControlServer — end-to-end over in-memory transport", .serialized)
struct RemoteControlE2ETests {

    @Test func pairAndCommandRoundTrip() async throws {
        let net = InMemoryNetwork()
        let (server, transport, pairing, engine) = try await makeServer(transport: net.transport,
                                                                       requireAuth: true)
        let port = await server.boundPort ?? 0
        #expect(port > 0)

        let pin = await pairing.startNewPairing()
        let client = try await transport.connect(to: .loopback(port: port),
                                                 options: .plainWebSocket)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        try await client.send(try encoder.encode(ClientFrame.pair(pin: pin, clientName: "Test")))

        let firstData = try #require(try await client.receive())
        let firstFrame = try decoder.decode(ServerFrame.self, from: firstData)
        if case .paired(let token) = firstFrame {
            #expect(!token.isEmpty)
        } else {
            Issue.record("expected .paired, got \(firstFrame)")
        }

        // Subscribe before sending commands so event frames are delivered.
        try await client.send(try encoder.encode(ClientFrame.subscribe()))
        for _ in 0..<5 {
            guard let subData = try await client.receive() else { break }
            if case .subscribed = (try? decoder.decode(ServerFrame.self, from: subData)) { break }
        }

        let cmdID = UUID()
        let cmd: AgentCommand = .updateAppearancePref(key: .theme, value: .string("dark"))
        try await client.send(try encoder.encode(ClientFrame.command(id: cmdID, command: cmd)))

        var sawResult = false
        var sawEvent = false
        for _ in 0..<8 {
            guard let data = try await client.receive() else { break }
            guard let frame = try? decoder.decode(ServerFrame.self, from: data) else { continue }
            switch frame {
            case .result(let id, true, _) where id == cmdID:
                sawResult = true
            case .event(_, let wire):
                if case .appearancePrefChanged = wire { sawEvent = true }
            default:
                break
            }
            if sawResult && sawEvent { break }
        }
        #expect(sawResult)
        #expect(sawEvent)

        let prefs = await engine.prefs.state()
        #expect(prefs.appearance.theme == .dark)

        await client.close()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    @Test func unpairedClientCommandIsRejected() async throws {
        let net = InMemoryNetwork()
        let (server, transport, _, engine) = try await makeServer(transport: net.transport,
                                                                  requireAuth: true)
        let port = await server.boundPort ?? 0

        let client = try await transport.connect(to: .loopback(port: port),
                                                 options: .plainWebSocket)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let cmdID = UUID()
        let cmd: AgentCommand = .updateAppearancePref(key: .theme, value: .string("dark"))
        try await client.send(try encoder.encode(ClientFrame.command(id: cmdID, command: cmd)))

        let response = try #require(try await client.receive())
        let frame = try decoder.decode(ServerFrame.self, from: response)
        if case .result(let id, false, let error?) = frame {
            #expect(id == cmdID)
            #expect(error.code == "not_paired")
        } else {
            Issue.record("expected pair-required error, got \(frame)")
        }

        await client.close()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    @Test("Bearer auth frame reuses an existing paired token")
    func bearerAuthFrameAllowsCommands() async throws {
        let net = InMemoryNetwork()
        let (server, transport, pairing, engine) = try await makeServer(transport: net.transport,
                                                                       requireAuth: true)
        let port = await server.boundPort ?? 0
        let pin = await pairing.startNewPairing()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let pairingClient = try await transport.connect(to: .loopback(port: port),
                                                        options: .plainWebSocket)
        try await pairingClient.send(try encoder.encode(ClientFrame.pair(pin: pin, clientName: "Phone")))
        let pairData = try #require(try await pairingClient.receive())
        let token: String
        if case .paired(let issued) = try decoder.decode(ServerFrame.self, from: pairData) {
            token = issued
        } else {
            Issue.record("expected paired response")
            return
        }
        await pairingClient.close()

        let client = try await transport.connect(to: .loopback(port: port),
                                                 options: .plainWebSocket)
        try await client.send(try encoder.encode(ClientFrame.auth(token: token)))
        let authData = try #require(try await client.receive())
        if case .paired(let accepted) = try decoder.decode(ServerFrame.self, from: authData) {
            #expect(accepted == token)
        } else {
            Issue.record("expected auth acknowledgement")
            return
        }

        let cmdID = UUID()
        try await client.send(try encoder.encode(ClientFrame.command(
            id: cmdID,
            command: .updateAppearancePref(key: .theme, value: .string("loopback"))
        )))
        let resultData = try #require(try await client.receive())
        if case .result(let id, true, _) = try decoder.decode(ServerFrame.self, from: resultData) {
            #expect(id == cmdID)
        } else {
            Issue.record("expected command success after auth")
        }

        await client.close()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    @Test("Authorization header bearer token allows commands")
    func authorizationHeaderBearerTokenAllowsCommands() async throws {
        let net = InMemoryNetwork()
        let (server, transport, pairing, engine) = try await makeServer(transport: net.transport,
                                                                       requireAuth: true)
        let port = await server.boundPort ?? 0
        let pin = await pairing.startNewPairing()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let pairingClient = try await transport.connect(to: .loopback(port: port),
                                                        options: .plainWebSocket)
        try await pairingClient.send(try encoder.encode(ClientFrame.pair(pin: pin, clientName: "Phone")))
        let pairData = try #require(try await pairingClient.receive())
        let token: String
        if case .paired(let issued) = try decoder.decode(ServerFrame.self, from: pairData) {
            token = issued
        } else {
            Issue.record("expected paired response")
            return
        }
        await pairingClient.close()

        let client = try await transport.connect(to: .loopback(port: port),
                                                 options: .webSocket(authorizationBearer: token))
        let cmdID = UUID()
        try await client.send(try encoder.encode(ClientFrame.command(
            id: cmdID,
            command: .updateAppearancePref(key: .theme, value: .string("metadata-auth"))
        )))

        let resultData = try #require(try await client.receive())
        if case .result(let id, true, _) = try decoder.decode(ServerFrame.self, from: resultData) {
            #expect(id == cmdID)
        } else {
            Issue.record("expected command success with Authorization metadata")
        }

        await client.close()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    @Test("unexpected websocket path is rejected before frames")
    func unexpectedWebSocketPathIsRejected() async throws {
        let net = InMemoryNetwork()
        let (server, transport, _, engine) = try await makeServer(transport: net.transport,
                                                                  requireAuth: false)
        let port = await server.boundPort ?? 0

        let client = try await transport.connect(to: .loopback(port: port),
                                                 options: .webSocket(path: "/wrong"))
        let payload = try await client.receive()
        #expect(payload == nil)

        await client.close()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    @Test("snapshot requests receive ServerFrame.snapshot")
    func snapshotRequestReturnsSnapshotFrame() async throws {
        let net = InMemoryNetwork()
        let (server, transport, _, engine) = try await makeServer(transport: net.transport,
                                                                  requireAuth: false)
        let port = await server.boundPort ?? 0
        let client = try await transport.connect(to: .loopback(port: port),
                                                 options: .plainWebSocket)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        try await client.send(try encoder.encode(ClientFrame.snapshot(kind: .prefs)))
        let data = try #require(try await client.receive())
        if case .snapshot(let kind, let payload) = try decoder.decode(ServerFrame.self, from: data) {
            #expect(kind == .prefs)
            #expect(!payload.isEmpty)
        } else {
            Issue.record("expected snapshot frame")
        }

        await client.close()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    @Test func loggingDecoratorIsTransparent() async throws {
        // Wrap in-memory transport with the logging decorator. The same
        // command flow must still complete — logging is side-effect-only.
        let net = InMemoryNetwork()
        let logging = LoggingNetworkTransport(wrapping: net.transport,
                                              category: "RemoteE2E")
        let (server, transport, pairing, engine) = try await makeServer(transport: logging,
                                                                        requireAuth: false)
        _ = await pairing.startNewPairing()
        let port = await server.boundPort ?? 0

        let client = try await transport.connect(to: .loopback(port: port),
                                                 options: .plainWebSocket)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let cmdID = UUID()
        try await client.send(try encoder.encode(
            ClientFrame.command(id: cmdID,
                                command: .updateAppearancePref(key: .theme,
                                                               value: .string("dusk")))
        ))
        let data = try #require(try await client.receive())
        let frame = try decoder.decode(ServerFrame.self, from: data)
        if case .result(let id, true, _) = frame { #expect(id == cmdID) }
        else { Issue.record("unexpected frame: \(frame)") }

        await client.close()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    @Test("sendPrompt write failure sends userTurn event before command error")
    func sendPromptWriteFailureOrdersEventBeforeErrorResult() async throws {
        let net = InMemoryNetwork()
        let pty = FailingRemotePTY(error: .writeFailed(errno: 5))
        let seams = Seams.fake()
        let engine = AgentEngine(seams: seams, transportFactory: { _, _ in pty })
        await engine.bootstrap()
        try await engine.start(adapter: MockAdapter(),
                               workspace: URL(fileURLWithPath: NSTemporaryDirectory()))

        let pairing = PairingService(clock: seams.clock, random: seams.random)
        let server = RemoteControlServer(engine: engine,
                                         bus: engine.bus,
                                         pairing: pairing,
                                         transport: net.transport)
        try await server.start(configuration: .init(host: .loopback,
                                                    port: 0,
                                                    requireAuth: false,
                                                    useTLS: false))
        let port = await server.boundPort ?? 0
        let client = try await net.transport.connect(to: .loopback(port: port),
                                                     options: .plainWebSocket)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        try await client.send(try encoder.encode(ClientFrame.subscribe()))
        for _ in 0..<8 {
            guard let data = try await client.receive() else { break }
            if case .subscribed = try? decoder.decode(ServerFrame.self, from: data) { break }
        }

        let cmdID = UUID()
        try await client.send(try encoder.encode(ClientFrame.command(
            id: cmdID,
            command: .sendPrompt(text: "wire fail", attachments: [])
        )))

        var userTurnIndex: Int?
        var resultIndex: Int?
        var framesSeen = 0
        for _ in 0..<12 {
            guard let data = try await client.receive() else { break }
            guard let frame = try? decoder.decode(ServerFrame.self, from: data) else { continue }
            switch frame {
            case .event(_, .userTurn(_, let text)) where text == "wire fail":
                userTurnIndex = framesSeen
            case .result(let id, false, let error?) where id == cmdID:
                resultIndex = framesSeen
                #expect(error.code == "unknown")
                #expect(error.message.contains("writeFailed"))
            default:
                break
            }
            framesSeen += 1
            if userTurnIndex != nil && resultIndex != nil { break }
        }

        let userTurnPosition = try #require(userTurnIndex)
        let resultPosition = try #require(resultIndex)
        #expect(userTurnPosition < resultPosition)
        #expect(await pty.writtenTexts() == ["wire fail"])

        await client.close()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    @Test("PTY write command failures return remote command errors")
    func ptyWriteCommandFailuresReturnRemoteCommandErrors() async throws {
        struct WriteFailureCase {
            let command: AgentCommand
            let expectedBytes: Data

            init(_ command: AgentCommand, _ expectedText: String) {
                self.command = command
                self.expectedBytes = Data(expectedText.utf8)
            }

            init(_ command: AgentCommand, bytes: Data) {
                self.command = command
                self.expectedBytes = bytes
            }
        }

        let cases: [WriteFailureCase] = [
            .init(.sendPrompt(text: "remote prompt", attachments: []), "remote prompt"),
            .init(.cancelCurrentTurn, bytes: Data([0x03])),
            .init(.newSession, "/clear\n"),
            .init(.compact, "/compact\n"),
            .init(.selectModel(id: "sonnet"), "/model sonnet\n"),
            .init(.setPermissionMode(.acceptEdits), "/permission acceptEdits\n"),
            .init(.toggleThinkMode(enabled: true), "/think\n"),
            .init(.toggleThinkMode(enabled: false), "/think off\n"),
            .init(.toggleReviewMode(enabled: true), "/review\n"),
            .init(.toggleReviewMode(enabled: false), "/review off\n"),
            .init(.runSlashCommand(name: "/foo", args: ["a", "b"]), "/foo a b\n"),
            .init(.runCustomCommand(path: "/proj/review.md", args: ["x"]), "/proj/review.md x\n")
        ]

        let net = InMemoryNetwork()
        let pty = FailingRemotePTY(error: .writeFailed(errno: 5))
        let seams = seamsWithRunningClock()
        let engine = AgentEngine(seams: seams, transportFactory: { _, _ in pty })
        await engine.bootstrap()
        try await engine.start(adapter: MockAdapter(),
                               workspace: URL(fileURLWithPath: NSTemporaryDirectory()))

        let pairing = PairingService(clock: seams.clock, random: seams.random)
        let server = RemoteControlServer(engine: engine,
                                         bus: engine.bus,
                                         pairing: pairing,
                                         transport: net.transport)
        try await server.start(configuration: .init(host: .loopback,
                                                    port: 0,
                                                    requireAuth: false,
                                                    useTLS: false))
        let port = await server.boundPort ?? 0
        let client = try await net.transport.connect(to: .loopback(port: port),
                                                     options: .plainWebSocket)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for testCase in cases {
            let cmdID = UUID()
            try await client.send(try encoder.encode(ClientFrame.command(id: cmdID,
                                                                         command: testCase.command)))

            let data = try #require(try await client.receive())
            if case .result(let id, false, let error?) = try decoder.decode(ServerFrame.self, from: data) {
                #expect(id == cmdID)
                #expect(error.code == "unknown")
                #expect(error.message.contains("writeFailed"))
            } else {
                Issue.record("expected failed command result")
            }
        }

        #expect(await pty.writtenData() == cases.map(\.expectedBytes))

        await client.close()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    @Test("stateful PTY write failures return remote command errors")
    func statefulPTYWriteFailuresReturnRemoteCommandErrors() async throws {
        try await assertRemotePermissionWriteFailure()
        try await assertRemoteEditAndResubmitWriteFailure()
    }

    // MARK: - Helpers

    @Test("subscribe frame with lastSeenEventID triggers selective replay and subscribed ack")
    func reconnectWithReplay() async throws {
        let net = InMemoryNetwork()
        let (server, transport, _, engine) = try await makeServer(transport: net.transport,
                                                                   requireAuth: false)
        let port = await server.boundPort ?? 0

        // Publish two events before the client connects.
        let id1 = await engine.bus.publish(.bell)
        _ = await engine.bus.publish(.bell)

        let client = try await transport.connect(to: .loopback(port: port), options: .plainWebSocket)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // Client reconnects claiming it already saw the first event.
        let frame = ClientFrame.subscribe(lastSeenEventID: id1)
        try await client.send(try encoder.encode(frame))

        // Collect server frames. The server will:
        //   1. Replay events after id1 (only the second one)
        //   2. Send .subscribed(latestEventID:outcome:) as an ack
        // We collect until we've seen .subscribed, then read one more cycle
        // to pick up any replayed events that arrive after the ack.
        var eventCount = 0
        var sawSubscribed = false
        var latestID: UUID?
        var outcome: SubscribeReplayOutcome?

        for _ in 0..<15 {
            guard let data = try await client.receive() else { break }
            guard let serverFrame = try? decoder.decode(ServerFrame.self, from: data) else { continue }
            switch serverFrame {
            case .event:
                eventCount += 1
            case .subscribed(let lid, let replayOutcome):
                sawSubscribed = true
                latestID = lid
                outcome = replayOutcome
            default:
                break
            }
            // After we have both the ack and at least 1 replayed event, stop.
            if sawSubscribed && eventCount >= 1 { break }
        }

        // One event replayed (only the second one, since we supplied id1 as the checkpoint).
        #expect(eventCount == 1)
        #expect(sawSubscribed)
        #expect(latestID != nil)
        #expect(outcome == .resumed)
        await client.close()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    @Test("expired checkpoint subscribe reports checkpointExpired outcome")
    func expiredCheckpointSubscribe() async throws {
        let net = InMemoryNetwork()
        let (server, transport, _, engine) = try await makeServer(transport: net.transport,
                                                                   requireAuth: false)
        let port = await server.boundPort ?? 0

        for _ in 0..<8 {
            _ = await engine.bus.publish(.bell)
        }
        let staleID = UUID()

        let client = try await transport.connect(to: .loopback(port: port), options: .plainWebSocket)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        try await client.send(try encoder.encode(
            ClientFrame.subscribe(lastSeenEventID: staleID)
        ))

        var outcome: SubscribeReplayOutcome?
        for _ in 0..<20 {
            guard let data = try await client.receive() else { break }
            guard let frame = try? decoder.decode(ServerFrame.self, from: data) else { continue }
            if case .subscribed(_, let replayOutcome) = frame {
                outcome = replayOutcome
                break
            }
        }
        #expect(outcome == .checkpointExpired)
        await client.close()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    @Test("snapshot frame serves resync payloads after checkpoint expiry")
    func snapshotResyncAfterExpiry() async throws {
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

        _ = await engine.bus.publish(.userTurn(id: "u1", text: "hello"))
        let staleID = await engine.bus.lastPublishedID
        for _ in 0..<StreamBufferDefaults.eventHistory {
            _ = await engine.bus.publish(.bell)
        }

        let client = try await net.transport.connect(to: .loopback(port: port), options: .plainWebSocket)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        try await client.send(try encoder.encode(
            ClientFrame.subscribe(lastSeenEventID: staleID)
        ))
        for _ in 0..<20 {
            guard let data = try await client.receive() else { break }
            if case .subscribed = try? decoder.decode(ServerFrame.self, from: data) { break }
        }

        try await client.send(try encoder.encode(ClientFrame.snapshot(kind: .prefs)))
        var gotSnapshot = false
        for _ in 0..<600 {
            guard let data = try await client.receive() else { break }
            if case .snapshot(let kind, let payload) = try? decoder.decode(ServerFrame.self, from: data) {
                #expect(kind == .prefs)
                #expect(!payload.isEmpty)
                gotSnapshot = true
                break
            }
        }
        #expect(gotSnapshot)

        await client.close()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    private func makeServer(transport: any NetworkTransport,
                            requireAuth: Bool) async throws
        -> (RemoteControlServer, any NetworkTransport, PairingService, AgentEngine) {
        let seams = Seams.fake()
        let engine = AgentEngine(seams: seams)
        await engine.bootstrap()
        let pairing = PairingService(clock: seams.clock, random: seams.random)
        let server = RemoteControlServer(engine: engine,
                                         bus: engine.bus,
                                         pairing: pairing,
                                         transport: transport)
        try await server.start(configuration: .init(host: .loopback,
                                                    port: 0,
                                                    requireAuth: requireAuth,
                                                    useTLS: false))
        return (server, transport, pairing, engine)
    }

    private func assertRemotePermissionWriteFailure() async throws {
        let net = InMemoryNetwork()
        let pty = FailingRemotePTY(error: .writeFailed(errno: 5))
        let seams = Seams.fake()
        let engine = AgentEngine(seams: seams, transportFactory: { _, _ in pty })
        await engine.bootstrap()
        let adapter = RecordingMockAdapter(permissionDelivery: .writePTY(Data("allow\n".utf8)))
        try await engine.start(adapter: adapter,
                               workspace: URL(fileURLWithPath: NSTemporaryDirectory()))
        let server = try await startServer(engine: engine, transport: net.transport, seams: seams)
        let client = try await net.transport.connect(to: .loopback(port: await server.boundPort ?? 0),
                                                     options: .plainWebSocket)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let prompt = PermissionPrompt(toolName: "Bash",
                                      summary: "ls",
                                      argumentsSummary: "{}",
                                      requestedAt: Date())
        adapter.emit(.permissionRequest(prompt: prompt))
        try await Task.sleep(for: .milliseconds(20))

        let cmdID = UUID()
        try await client.send(try encoder.encode(ClientFrame.command(
            id: cmdID,
            command: .respondToPermission(id: prompt.id, decision: .allow)
        )))

        let data = try #require(try await client.receive())
        if case .result(let id, false, let error?) = try decoder.decode(ServerFrame.self, from: data) {
            #expect(id == cmdID)
            #expect(error.code == "unknown")
            #expect(error.message.contains("writeFailed"))
        } else {
            Issue.record("expected failed permission command result")
        }
        #expect(await pty.writtenData() == [Data("allow\n".utf8)])

        await client.close()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    private func assertRemoteEditAndResubmitWriteFailure() async throws {
        let net = InMemoryNetwork()
        let firstPTY = RemoteScriptedTransport()
        let restartedPTY = RemoteScriptedTransport(writeSteps: [.fail(.writeFailed(errno: 5))])
        let factory = RemoteScriptedTransportFactory([firstPTY, restartedPTY])
        let seams = seamsWithRunningClock()
        let engine = AgentEngine(seams: seams, transportFactory: factory.makeTransport)
        await engine.bootstrap()
        try await engine.start(adapter: RecordingMockAdapter(),
                               workspace: URL(fileURLWithPath: NSTemporaryDirectory()))
        let server = try await startServer(engine: engine, transport: net.transport, seams: seams)
        let client = try await net.transport.connect(to: .loopback(port: await server.boundPort ?? 0),
                                                     options: .plainWebSocket)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let firstCommandID = UUID()
        try await client.send(try encoder.encode(ClientFrame.command(
            id: firstCommandID,
            command: .sendPrompt(text: "first", attachments: [])
        )))
        _ = try #require(try await client.receive())

        let history = await engine.bus.historySnapshot
        guard case .userTurn(let idString, _)? = history.map(\.event).last(where: {
            if case .userTurn = $0 { return true }
            return false
        }), let targetID = UUID(uuidString: idString) else {
            Issue.record("expected userTurn in bus history")
            return
        }

        let editCommandID = UUID()
        try await client.send(try encoder.encode(ClientFrame.command(
            id: editCommandID,
            command: .editAndResubmitLast(targetBubbleID: targetID,
                                          text: "edited fail",
                                          attachments: [])
        )))

        let data = try #require(try await client.receive())
        if case .result(let id, false, let error?) = try decoder.decode(ServerFrame.self, from: data) {
            #expect(id == editCommandID)
            #expect(error.code == "unknown")
            #expect(error.message.contains("writeFailed"))
        } else {
            Issue.record("expected failed edit command result")
        }
        #expect(await firstPTY.writtenData() == [Data("first".utf8), Data([0x03])])
        #expect(await restartedPTY.writtenData() == [Data("edited fail".utf8)])

        await client.close()
        await server.stop()
        await engine.shutdown(reason: .naturalExit)
    }

    private func startServer(engine: AgentEngine,
                             transport: any NetworkTransport,
                             seams: Seams) async throws -> RemoteControlServer {
        let pairing = PairingService(clock: seams.clock, random: seams.random)
        let server = RemoteControlServer(engine: engine,
                                         bus: engine.bus,
                                         pairing: pairing,
                                         transport: transport)
        try await server.start(configuration: .init(host: .loopback,
                                                    port: 0,
                                                    requireAuth: false,
                                                    useTLS: false))
        return server
    }

    private func seamsWithRunningClock() -> Seams {
        let seams = Seams.fake()
        return Seams(clock: SystemClock(),
                     random: seams.random,
                     environment: seams.environment,
                     fileSystem: seams.fileSystem)
    }
}

private actor FailingRemotePTY: AgentTransport {
    nonisolated let outboundBytes: AsyncStream<Data>
    nonisolated let bellEvents: AsyncStream<Void>
    nonisolated var terminalSnapshot: (any TerminalSnapshotting)? { nil }

    private let continuation: AsyncStream<Data>.Continuation
    private let error: PTYError
    private var writes: [Data] = []

    init(error: PTYError) {
        var continuation: AsyncStream<Data>.Continuation!
        self.outboundBytes = AsyncStream(bufferingPolicy: .bufferingOldest(StreamBufferDefaults.ptyChunks)) { c in
            continuation = c
        }
        self.continuation = continuation
        self.error = error

        var bellCont: AsyncStream<Void>.Continuation!
        self.bellEvents = AsyncStream { bellCont = $0 }
        bellCont.finish()
    }

    func write(_ data: Data) async throws {
        writes.append(data)
        throw error
    }

    func interrupt() async {}

    func close() async {
        continuation.finish()
    }

    func writtenTexts() -> [String] {
        writes.map { String(decoding: $0, as: UTF8.self) }
    }

    func writtenData() -> [Data] {
        writes
    }
}

private final class RemoteScriptedTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [RemoteScriptedTransport]

    init(_ transports: [RemoteScriptedTransport]) {
        self.transports = transports
    }

    func makeTransport(_ descriptor: AgentTransportDescriptor,
                       _ launch: AgentTransportLaunchSpec) throws -> any AgentTransport {
        lock.lock()
        defer { lock.unlock() }
        guard !transports.isEmpty else {
            throw AgentError.internalInvariant(detail: "remote scripted transport factory exhausted")
        }
        return transports.removeFirst()
    }
}

private actor RemoteScriptedTransport: AgentTransport {
    enum WriteStep: Sendable {
        case succeed
        case fail(PTYError)
    }

    nonisolated let outboundBytes: AsyncStream<Data>
    nonisolated let bellEvents: AsyncStream<Void>
    nonisolated var terminalSnapshot: (any TerminalSnapshotting)? { nil }

    private let continuation: AsyncStream<Data>.Continuation
    private let writeSteps: [WriteStep]
    private var nextWriteIndex = 0
    private var writes: [Data] = []
    private var closed = false

    init(writeSteps: [WriteStep] = []) {
        var continuation: AsyncStream<Data>.Continuation!
        self.outboundBytes = AsyncStream(bufferingPolicy: .bufferingOldest(StreamBufferDefaults.ptyChunks)) { c in
            continuation = c
        }
        self.continuation = continuation
        self.writeSteps = writeSteps

        var bellCont: AsyncStream<Void>.Continuation!
        self.bellEvents = AsyncStream { bellCont = $0 }
        bellCont.finish()
    }

    func write(_ data: Data) async throws {
        guard !closed else { throw PTYError.alreadyClosed }
        writes.append(data)
        let step = nextWriteIndex < writeSteps.count ? writeSteps[nextWriteIndex] : .succeed
        nextWriteIndex += 1
        switch step {
        case .succeed:
            return
        case .fail(let error):
            throw error
        }
    }

    func interrupt() async {}

    func close() async {
        closed = true
        continuation.finish()
    }

    func writtenData() -> [Data] {
        writes
    }
}
