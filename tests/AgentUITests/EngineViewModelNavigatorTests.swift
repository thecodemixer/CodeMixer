import Foundation
import os
import Testing
@testable import AgentUI
@testable import AgentCore
@testable import AgentTestSupport
import AgentProtocol

/// Tests for the optimistic-send reconciliation and the session-navigator
/// actions added to `EngineViewModel`. These exercise the dedup rule (engine +
/// hook double-echo), rollback on failure, and transport-neutral navigation.
@Suite("EngineViewModel — optimistic send + navigator")
@MainActor
struct EngineViewModelNavigatorTests {

    // MARK: - Optimistic send

    @Test("sendPrompt appends the user bubble and enters a working state immediately")
    func optimisticAppendAndWorking() async {
        let (vm, bus, _) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("hello")

        #expect(vm.messages.count == 1)
        if case .user(_, let text) = vm.messages[0] { #expect(text == "hello") }
        else { #expect(Bool(false), "expected an optimistic user bubble") }
        #expect(vm.activity == .awaitingFirstChunk)
        if case .working = vm.status {} else { #expect(Bool(false), "expected working status") }

        await bus.shutdown()
    }

    @Test("sendPrompt ignores empty / whitespace-only text")
    func optimisticIgnoresEmpty() async {
        let (vm, bus, _) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("   \n  ")
        #expect(vm.messages.isEmpty)

        await bus.shutdown()
    }

    @Test("Engine echo reconciles the optimistic bubble; the hook double-echo is dropped")
    func optimisticReconcileAndDedup() async {
        let engineID = UUID()
        let hookID = UUID()
        let (vm, bus, _) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("hi")
        #expect(vm.messages.count == 1)

        // First real `.userTurn` — adopts the engine id, no new bubble.
        await bus.publish(.userTurn(id: engineID.uuidString, text: "hi"))
        await drain()
        #expect(vm.messages.count == 1)
        #expect(vm.lastUserBubbleID == engineID)

        // Second echo (the Claude hook) for the same turn — dropped.
        await bus.publish(.userTurn(id: hookID.uuidString, text: "hi"))
        await drain()
        #expect(vm.messages.count == 1)

        await bus.shutdown()
    }

    @Test("Late SessionStart during a send keeps the optimistic turn working")
    func lateSessionStartKeepsOptimisticTurnWorking() async {
        let (vm, bus, _) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let ws = URL(fileURLWithPath: "/Users/me/ws")
        await bus.publish(.sessionStarted(sessionID: "", model: nil, cwd: ws))
        await drain()

        vm.sendPrompt("hi")
        await bus.publish(.sessionStarted(sessionID: "real-session", model: nil, cwd: ws))
        await drain()

        #expect(vm.messages.count == 1)
        if case .user(_, let text) = vm.messages[0] {
            #expect(text == "hi")
        } else {
            Issue.record("expected optimistic user bubble")
        }
        #expect(vm.activity == .awaitingFirstChunk)
        if case .working = vm.status {} else {
            Issue.record("expected working status")
        }

        await bus.shutdown()
    }

    @Test("A genuinely different user turn is appended, not deduped")
    func differentTurnAppends() async {
        let (vm, bus, _) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("hi")
        await bus.publish(.userTurn(id: UUID().uuidString, text: "a different message"))
        await drain()

        #expect(vm.messages.count == 2)

        await bus.shutdown()
    }

    @Test("sendPrompt rolls back the optimistic bubble when the engine throws")
    func optimisticRollbackOnThrow() async {
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: ThrowingPort(),
                                 bus: bus,
                                 clock: FakeClock(),
                                 random: FakeRandomSource())
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("doomed")
        // Allow the fire-and-forget send Task to throw and roll back.
        try? await Task.sleep(for: .milliseconds(60))

        #expect(vm.messages.isEmpty)
        #expect(vm.diagnostics.contains { $0.level == .error })
        if case .idle = vm.status {} else { #expect(Bool(false), "status should reset to idle") }

        await bus.shutdown()
    }

    // MARK: - Navigator

    @Test("loadSessions on a non-resumable agent yields a first-class empty list")
    func loadSessionsNonResumable() async {
        let (vm, bus, _) = makeModel()
        vm.supportsResumableSessions = false
        vm.loadSessions(for: "/Users/me/ws")
        #expect(vm.sessionsByProject["/Users/me/ws"] == [])
        await bus.shutdown()
    }

    @Test("loadSessions populates sessions from the injected lister")
    func loadSessionsPopulates() async {
        let (vm, bus, _) = makeModel()
        let path = "/Users/me/ws"
        vm.supportsResumableSessions = true
        vm.sessionLister = { url in
            [SessionSummary(id: "s1", agentID: .claudeCode,
                            workspace: url, title: "First",
                            lastActivity: Date(), messageCount: 3, gitBranch: "main")]
        }
        vm.loadSessions(for: path)
        try? await Task.sleep(for: .milliseconds(60))

        #expect(vm.sessionsByProject[path]?.count == 1)
        #expect(vm.sessionsByProject[path]?.first?.title == "First")
        #expect(!vm.loadingProjectPaths.contains(path))

        await bus.shutdown()
    }

    @Test("newChat in the active project sends .newSession; other projects reopen via .openProject")
    func newChatRoutesToWireCommands() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        vm.subscribe()
        defer { vm.unsubscribe() }

        let ws = URL(fileURLWithPath: "/Users/me/ws")
        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: ws))
        await drain()

        vm.newChat(in: ws.path)
        vm.newChat(in: "/Users/me/other")
        try? await Task.sleep(for: .milliseconds(60))

        let commands = port.commands
        #expect(commands.contains { if case .newSession = $0 { return true }; return false })
        #expect(commands.contains {
            if case .openProject(let path, let resume) = $0 { return path == "/Users/me/other" && resume == nil }
            return false
        })

        await bus.shutdown()
    }

    @Test("openSession reopens the project with the resume id over the wire")
    func openSessionRoutesToOpenProject() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.openSession(projectPath: "/Users/me/ws", id: "sess-42")
        try? await Task.sleep(for: .milliseconds(60))

        #expect(port.commands.contains {
            if case .openProject(let path, let resume) = $0 {
                return path == "/Users/me/ws" && resume == "sess-42"
            }
            return false
        })

        await bus.shutdown()
    }

    @Test("openSession enters a switching state until replayed content arrives")
    func openSessionSwitchingState() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.userTurn(id: UUID().uuidString, text: "old"))
        await drain()
        #expect(vm.messages.count == 1)

        vm.openSession(projectPath: "/Users/me/ws", id: "sess-42")
        #expect(vm.isSwitchingSession)
        #expect(vm.messages.isEmpty)

        await bus.publish(.userTurn(id: UUID().uuidString, text: "historical"))
        await drain()

        #expect(!vm.isSwitchingSession)
        #expect(vm.messages.count == 1)

        await bus.shutdown()
    }

    @Test("openSession keeps switching state across restart stop event")
    func openSessionKeepsSwitchingAcrossStop() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.openSession(projectPath: "/Users/me/ws", id: "sess-42")
        #expect(vm.isSwitchingSession)

        await bus.publish(.stopped(reason: .userCancel))
        await drain()

        #expect(vm.isSwitchingSession)
        #expect(vm.messages.isEmpty)

        await bus.publish(.assistantText(id: UUID().uuidString,
                                         blockID: UUID().uuidString,
                                         text: "loaded",
                                         isFinal: true))
        await drain()

        #expect(!vm.isSwitchingSession)
        #expect(vm.messages.count == 1)

        await bus.shutdown()
    }

    @Test("createProject persists the selected mixed default and opens the new project")
    func createProjectPersistsMixedDefault() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: URL(fileURLWithPath: "/Users/me"))
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store
        vm.subscribe()
        defer { vm.unsubscribe() }

        let workspace = URL(fileURLWithPath: "/Users/me/ws")
        vm.adoptEmptyWorkspace(workspace)
        try? await Task.sleep(for: .milliseconds(40))

        vm.createProject(name: "mixed", agentMode: .mixed(defaultAgent: .claudeCode))
        try? await Task.sleep(for: .milliseconds(80))

        let project = await store.project(path: workspace.appendingPathComponent("mixed").path)
        #expect(project?.agentMode == .mixed(defaultAgent: .claudeCode))
        #expect(vm.projects.contains { $0.path == project?.path })
        #expect(vm.workspaceRoot?.path == workspace.path)
        #expect(port.commands.contains {
            if case .openProject(let path, let resume) = $0 {
                return path == project?.path && resume == nil
            }
            return false
        })

        await bus.shutdown()
    }

    @Test("sessionStarted for a subproject keeps workspaceRoot and project sections")
    func sessionStartedSubprojectKeepsWorkspaceProjects() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: URL(fileURLWithPath: "/Users/me"))
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store
        vm.subscribe()
        defer { vm.unsubscribe() }

        let workspace = URL(fileURLWithPath: "/Users/me/ws")
        try? fileSystem.createDirectory(at: workspace, withIntermediates: true)
        vm.adoptEmptyWorkspace(workspace)
        try? await Task.sleep(for: .milliseconds(40))

        let ref = try! await store.createProject(name: "api", agentMode: .claudeCode, in: workspace)
        let refs = await store.projects(for: workspace)
        vm.projects = refs

        await bus.publish(.sessionStarted(sessionID: "s1", model: nil,
                                          cwd: URL(fileURLWithPath: ref.path)))
        await drain()

        #expect(vm.workspaceRoot?.path == workspace.path)
        #expect(vm.workspace?.path == ref.path)
        #expect(vm.projects.count == 1)
        #expect(vm.projects.first?.path == ref.path)

        await bus.shutdown()
    }

    @Test("sessionStarted for the same workspace does not reload sessions")
    func sessionStartedSameWorkspaceSkipsReload() async {
        final class CallCounter: @unchecked Sendable {
            var count = 0
        }
        let listerCalls = CallCounter()
        let (vm, bus, _) = makeModel()
        vm.supportsResumableSessions = true
        vm.sessionLister = { _ in
            listerCalls.count += 1
            return []
        }
        vm.subscribe()
        defer { vm.unsubscribe() }

        let ws = URL(fileURLWithPath: "/Users/me/ws")
        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: ws))
        await drain()
        #expect(listerCalls.count == 1)

        await bus.publish(.sessionStarted(sessionID: "s2", model: nil, cwd: ws))
        await drain()
        #expect(listerCalls.count == 1)

        await bus.shutdown()
    }
}

// MARK: - Helpers

@MainActor
private func makeModel() -> (EngineViewModel, MulticastEventBus, FakeClock) {
    let bus = MulticastEventBus()
    let clock = FakeClock()
    let vm = EngineViewModel(engine: NoThrowPort(), bus: bus, clock: clock, random: FakeRandomSource())
    return (vm, bus, clock)
}

@MainActor
private func drain() async {
    try? await Task.sleep(for: .milliseconds(40))
}

private final class NoThrowPort: AgentEngineCommandPort, @unchecked Sendable {
    func send(_ command: AgentCommand) async throws {}
}

private final class ThrowingPort: AgentEngineCommandPort, @unchecked Sendable {
    func send(_ command: AgentCommand) async throws {
        throw AgentError.unsupportedOperation(detail: "send failed")
    }
}

private final class RecordingPort: AgentEngineCommandPort, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<[AgentCommand]>(initialState: [])
    var commands: [AgentCommand] { state.withLock { $0 } }
    func send(_ command: AgentCommand) async throws {
        state.withLock { $0.append(command) }
    }
}
