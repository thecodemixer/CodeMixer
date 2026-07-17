import Testing
import Foundation
import AgentClientProtocol
import AgentCore
import AgentProtocol
import AgentTestSupport

@Suite("ACPTwin")
struct ACPTwinTests {

    @Test("twin emits sessionStarted and assistant text")
    func happyPath() async {
        let twin = ACPTwin(configuration: .init(reply: "pong"))
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        continuation.finish()
        let events = twin.makeEventStream(inputs: AgentInputs(
            outputBytes: stream,
            terminal: nil,
            hookSocket: nil,
            workspace: URL(fileURLWithPath: "/tmp/acp-twin"),
            sessionID: AsyncStream { $0.finish() }
        ))
        var collected: [AgentEvent] = []
        for await event in events {
            collected.append(event)
        }
        #expect(collected.contains {
            if case .sessionStarted(let id, _, _) = $0 { return id == "acp-twin-session" }
            return false
        })
        #expect(collected.contains {
            if case .assistantText(_, _, let text, true) = $0 { return text == "pong" }
            return false
        })
    }

    @Test("twin requireAuth emits authenticationRequired")
    func requireAuth() async {
        let twin = ACPTwin(configuration: .init(requireAuth: true))
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        continuation.finish()
        let events = twin.makeEventStream(inputs: AgentInputs(
            outputBytes: stream,
            terminal: nil,
            hookSocket: nil,
            workspace: URL(fileURLWithPath: "/tmp/acp-twin"),
            sessionID: AsyncStream { $0.finish() }
        ))
        var collected: [AgentEvent] = []
        for await event in events {
            collected.append(event)
        }
        #expect(collected.contains {
            if case .error(.authenticationRequired(let id)) = $0 { return id == .other }
            return false
        })
    }

    @Test("twin encodes bootstrap and cancel frames")
    func encoding() {
        let twin = ACPTwin()
        let context = LaunchContext(
            workspace: URL(fileURLWithPath: "/tmp/acp-twin"),
            permissionMode: .default
        )
        let bootstrap = String(decoding: twin.sessionBootstrapBytes(context: context), as: UTF8.self)
        #expect(bootstrap.contains("initialize"))
        let cancel = String(decoding: twin.cancelSequence(), as: UTF8.self)
        #expect(cancel.contains("session/cancel"))
    }

    @Test("twin encodeCommand newSession emits session/new")
    func newSessionCommand() {
        let twin = ACPTwin()
        _ = twin.sessionBootstrapBytes(context: LaunchContext(
            workspace: URL(fileURLWithPath: "/tmp/acp-twin"),
            permissionMode: .default
        ))
        let text = String(decoding: twin.encodeCommand(.newSession)!, as: UTF8.self)
        #expect(text.contains("session/new"))
    }

    @Test("listResumableSessions returns configured twin session")
    func sessions() async {
        let twin = ACPTwin()
        let sessions = await twin.listResumableSessions(workspace: URL(fileURLWithPath: "/tmp"))
        #expect(sessions.contains { $0.id == "acp-twin-session" })
    }
}

@Suite("Engine + ACPTwin", .serialized)
struct EngineACPTwinTests {

    @Test("engine start with twin emits sessionStarted and final assistant text")
    func engineStart() async throws {
        let engine = AgentEngine(seams: .live)
        await engine.bootstrap()
        let twin = ACPTwin(configuration: .init(reply: "Engine twin reply."))
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acp-engine-twin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let sink = EngineEventSink()
        let sub = await engine.bus.subscribe()
        let collector = Task { await sink.ingest(sub.stream) }

        try await engine.start(adapter: twin, workspace: workspace)
        try? await Task.sleep(for: .milliseconds(200))
        collector.cancel()
        await engine.bus.unsubscribe(sub.id)
        await engine.shutdown(reason: .naturalExit)

        let events = await sink.snapshot()
        #expect(events.contains {
            if case .sessionStarted(let id, _, _) = $0 { return id == "acp-twin-session" }
            return false
        })
        #expect(events.contains {
            if case .assistantText(_, _, let text, true) = $0 { return text == "Engine twin reply." }
            return false
        })
    }
}

private actor EngineEventSink {
    private var events: [AgentEvent] = []

    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            events.append(entry.event)
            if events.count > 64 { break }
        }
    }

    func snapshot() -> [AgentEvent] { events }
}
