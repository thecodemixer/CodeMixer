import Foundation
import Testing
@testable import AgentUI
@testable import AgentCore
@testable import AgentTestSupport
import AgentProtocol

/// Engine → bus → ViewModel path for Codemixer-owned history markers.
@Suite("ClientAction — engine to conversation end-to-end")
@MainActor
struct ClientActionEndToEndTests {

    @Test("UI helpers publish clientAction rows through a live AgentEngine")
    func helpersReachConversationViaLiveEngine() async throws {
        let harness = try await LiveEngineViewModelHarness.make()
        defer { Task { await harness.shutdown() } }

        harness.viewModel.setPermissionMode(.plan)
        try await waitUntil(timeout: .seconds(2)) {
            harness.viewModel.messages.contains {
                if case .clientAction(let action) = $0 {
                    return action.kind == .permissionMode && action.detail == "Plan"
                }
                return false
            }
        }

        harness.viewModel.selectModel(id: "opus", label: "Opus")
        try await waitUntil(timeout: .seconds(2)) {
            harness.viewModel.messages.contains {
                if case .clientAction(let action) = $0 {
                    return action.kind == .model && action.detail == "Opus"
                }
                return false
            }
        }

        harness.viewModel.compactContext()
        try await waitUntil(timeout: .seconds(2)) {
            harness.viewModel.messages.contains {
                if case .clientAction(let action) = $0 {
                    return action.kind == .sessionLifecycle && action.detail == "Compact context"
                }
                return false
            }
        }

        let actionKinds = harness.viewModel.messages.compactMap { message -> ClientAction.Kind? in
            if case .clientAction(let action) = message { return action.kind }
            return nil
        }
        #expect(actionKinds.contains(.permissionMode))
        #expect(actionKinds.contains(.model))
        #expect(actionKinds.contains(.sessionLifecycle))

        try await harness.engine.send(.requestSnapshot(.conversation))
        try await waitUntil(timeout: .seconds(2)) {
            harness.viewModel.pendingExport?.kind == .conversation
        }
        let payload = try #require(harness.viewModel.pendingExport?.payload)
        let json = try #require(String(data: payload, encoding: .utf8))
        #expect(json.contains("\"role\":\"action\""))
        #expect(json.contains("Plan"))
        #expect(json.contains("Opus"))
        #expect(json.contains("Compact context"))
    }
}

// MARK: - Harness

@MainActor
private final class LiveEngineViewModelHarness {
    let engine: AgentEngine
    let viewModel: EngineViewModel
    let workspace: URL

    init(engine: AgentEngine, viewModel: EngineViewModel, workspace: URL) {
        self.engine = engine
        self.viewModel = viewModel
        self.workspace = workspace
    }

    static func make() async throws -> LiveEngineViewModelHarness {
        let fs = InMemoryFileSystem()
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-client-action-e2e-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let env = FakeEnvironment(home: workspace)
        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams, transportFactory: { _, _ in E2EScriptedTransport() })
        await engine.bootstrap()
        try await engine.start(adapter: RecordingMockAdapter(), workspace: workspace)

        let viewModel = EngineViewModel(engine: engine, bus: engine.bus)
        viewModel.subscribe()
        viewModel.availableModels = [AgentModelOption(id: "opus", label: "Opus")]
        try await Task.sleep(for: .milliseconds(50))
        return LiveEngineViewModelHarness(engine: engine, viewModel: viewModel, workspace: workspace)
    }

    func shutdown() async {
        viewModel.unsubscribe()
        await engine.shutdown(reason: .naturalExit)
        try? FileManager.default.removeItem(at: workspace)
    }
}

/// Minimal writable transport so agent-affecting commands after `recordClientAction` succeed.
actor E2EScriptedTransport: AgentTransport {
    nonisolated let outboundBytes: AsyncStream<Data>
    nonisolated let bellEvents: AsyncStream<Void>
    nonisolated var terminalSnapshot: (any TerminalSnapshotting)? { nil }

    private let outboundContinuation: AsyncStream<Data>.Continuation
    private var closed = false

    init() {
        var continuation: AsyncStream<Data>.Continuation!
        outboundBytes = AsyncStream(bufferingPolicy: .bufferingOldest(StreamBufferDefaults.ptyChunks)) { c in
            continuation = c
        }
        outboundContinuation = continuation
        var bellCont: AsyncStream<Void>.Continuation!
        bellEvents = AsyncStream { bellCont = $0 }
        bellCont.finish()
    }

    func write(_ data: Data) async throws {
        guard !closed else { throw AgentTransportError.alreadyClosed }
    }

    func interrupt() async {}

    func close() async {
        closed = true
        outboundContinuation.finish()
    }
}

@MainActor
private func waitUntil(timeout: Duration,
                       poll: Duration = .milliseconds(20),
                       condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: poll)
        await Task.yield()
    }
    Issue.record("timed out waiting for condition")
    throw WaitTimeout()
}

private struct WaitTimeout: Error {}
