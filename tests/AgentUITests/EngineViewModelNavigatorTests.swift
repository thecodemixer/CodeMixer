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

    @Test("loadSessions uses project-specific support when the current adapter is non-resumable")
    func loadSessionsUsesProjectSpecificSupport() async {
        let (vm, bus, _) = makeModel()
        let path = "/Users/me/ws/claude"
        vm.supportsResumableSessions = false
        vm.projectResumableSessionSupport[path] = true
        vm.sessionLister = { url in
            [SessionSummary(id: "s1", agentID: .claudeCode,
                            workspace: url, title: "Claude chat",
                            lastActivity: Date(), messageCount: 1)]
        }

        vm.loadSessions(for: path)
        try? await Task.sleep(for: .milliseconds(60))

        #expect(vm.sessionsByProject[path]?.map(\.title) == ["Claude chat"])
        #expect(vm.hasResumableSessionProjects)

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

    @Test("renameProject follows the renamed active project path")
    func renameProjectFollowsRenamedActivePath() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: URL(fileURLWithPath: "/Users/me"))
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        let workspace = URL(fileURLWithPath: "/Users/me/ws")
        let ref = try await store.createProject(name: "api", projectType: .codex, in: workspace)
        let oldPath = ref.path
        let newPath = workspace.appendingPathComponent("Backend").path
        vm.workspaceProjects = store
        vm.workspaceRoot = workspace
        vm.workspace = URL(fileURLWithPath: oldPath)
        vm.sessionID = "thread-1"
        vm.projects = [ref]
        vm.sessionsByProject[oldPath] = [
            SessionSummary(id: "s1", agentID: .codex,
                           workspace: URL(fileURLWithPath: oldPath),
                           title: "Thread", lastActivity: Date(), messageCount: 1),
        ]
        vm.loadingProjectPaths.insert(oldPath)
        vm.projectResumableSessionSupport[oldPath] = true

        vm.renameProject(path: oldPath, newName: "Backend")
        await drain()

        #expect(vm.workspace?.path == newPath)
        #expect(vm.projects.map(\.path) == [newPath])
        #expect(vm.sessionsByProject[oldPath] == nil)
        #expect(vm.sessionsByProject[newPath]?.first?.id == "s1")
        #expect(!vm.loadingProjectPaths.contains(oldPath))
        #expect(vm.loadingProjectPaths.contains(newPath))
        #expect(vm.projectResumableSessionSupport[oldPath] == nil)
        #expect(port.commands.contains {
            if case .openProject(let path, let resume) = $0 {
                return path == newPath && resume == "thread-1"
            }
            return false
        })

        await bus.shutdown()
    }

    @Test("renameProject blocks folder rename until the turn ends")
    func renameProjectBlocksWhileTurnIsActive() async throws {
        let (vm, bus, _) = makeModel()
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: URL(fileURLWithPath: "/Users/me"))
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        let workspace = URL(fileURLWithPath: "/Users/me/ws")
        let ref = try await store.createProject(name: "api", projectType: .codex, in: workspace)
        let oldPath = ref.path
        let newPath = workspace.appendingPathComponent("Backend").path
        vm.workspaceProjects = store
        vm.workspaceRoot = workspace
        vm.workspace = workspace.appendingPathComponent("other")
        vm.projects = [ref]
        vm.activity = .awaitingFirstChunk

        vm.renameProject(path: oldPath, newName: "Backend")
        await drain()

        #expect(fileSystem.isDirectory(at: URL(fileURLWithPath: oldPath)))
        #expect(!fileSystem.isDirectory(at: URL(fileURLWithPath: newPath)))
        #expect(vm.projects.map(\.path) == [oldPath])
        #expect(vm.diagnostics.contains {
            $0.message == "Wait for the current turn to finish before renaming a project."
        })

        await bus.shutdown()
    }

    @Test("newChat always opens the project with no resume id for a fresh session")
    func newChatRoutesToWireCommands() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        vm.subscribe()
        defer { vm.unsubscribe() }

        let ws = URL(fileURLWithPath: "/Users/me/ws")
        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: ws))
        await drain()

        vm.messages = [.user(bubbleID: UUID(), text: "old")]
        vm.newChat(in: ws.path)
        vm.newChat(in: "/Users/me/other")
        try? await Task.sleep(for: .milliseconds(60))

        let commands = port.commands
        #expect(commands.filter {
            if case .openProject(let path, let resume) = $0 {
                return path == ws.path && resume == nil
            }
            return false
        }.count >= 1)
        #expect(commands.contains {
            if case .openProject(let path, let resume) = $0 {
                return path == "/Users/me/other" && resume == nil
            }
            return false
        })
        #expect(vm.messages.isEmpty)
        #expect(vm.workspace?.path == "/Users/me/other")

        await bus.shutdown()
    }

    @Test("newChatInCurrentProject starts a session only in the active project")
    func newChatInCurrentProjectUsesWorkspace() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.newChatInCurrentProject()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(port.commands.isEmpty)

        let project = URL(fileURLWithPath: "/Users/me/ws/api")
        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: project))
        await drain()

        vm.messages = [.user(bubbleID: UUID(), text: "old")]
        vm.newChatInCurrentProject()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(port.commands.contains {
            if case .openProject(let path, let resume) = $0 {
                return path == project.path && resume == nil
            }
            return false
        })
        #expect(vm.messages.isEmpty)
        #expect(vm.workspace?.path == project.path)
        #expect(vm.sessionID == nil)

        await bus.shutdown()
    }

    @Test("openSession makes the session's project current for the top bar")
    func openSessionSetsCurrentProject() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        vm.projects = [
            .init(path: "/Users/me/ws/api", displayName: "API", projectType: .codex),
            .init(path: "/Users/me/ws/web", displayName: "Web", projectType: .claudeCode),
        ]
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "old", model: nil,
                                          cwd: URL(fileURLWithPath: "/Users/me/ws/web")))
        await drain()
        #expect(vm.currentProjectDisplayName == "Web")

        vm.openSession(projectPath: "/Users/me/ws/api", id: "sess-42")
        #expect(vm.workspace?.path == "/Users/me/ws/api")
        #expect(vm.currentProjectDisplayName == "API")

        await bus.shutdown()
    }

    @Test("selectProject opens the most recent session when available")
    func selectProjectOpensRecentSession() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let api = URL(fileURLWithPath: "/Users/me/ws/api")
        vm.sessionsByProject[api.path] = [
            SessionSummary(id: "recent", agentID: .codex, workspace: api,
                           title: "Latest", lastActivity: Date(), messageCount: 3),
        ]
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "web-1", model: nil,
                                          cwd: URL(fileURLWithPath: "/Users/me/ws/web")))
        await drain()

        vm.selectProject(path: api.path)
        try? await Task.sleep(for: .milliseconds(60))

        #expect(vm.workspace?.path == api.path)
        #expect(port.commands.contains {
            if case .openProject(let path, let resume) = $0 {
                return path == api.path && resume == "recent"
            }
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

    @Test("openSession locks composer until history appears")
    func openSessionLocksComposerUntilResumeReady() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let clock = FakeClock()
        let vm = EngineViewModel(engine: port, bus: bus, clock: clock, random: FakeRandomSource())
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.openSession(projectPath: "/Users/me/ws", id: "sess-42")
        #expect(vm.isComposerLockedForSessionResume)

        vm.sendPrompt("too early")
        #expect(vm.messages.isEmpty)

        await bus.publish(.userTurn(id: UUID().uuidString, text: "historical"))
        await drain()
        #expect(!vm.isSwitchingSession)
        #expect(!vm.isComposerLockedForSessionResume)

        vm.sendPrompt("now allowed")
        #expect(vm.messages.count == 2)

        await bus.shutdown()
    }

    @Test("Claude openSession keeps composer locked past JSONL history until live resume settles")
    func claudeOpenSessionWaitsForLiveResumeBeforeUnlockingComposer() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let clock = FakeClock()
        let vm = EngineViewModel(engine: port, bus: bus, clock: clock, random: FakeRandomSource())
        vm.subscribe()
        defer { vm.unsubscribe() }

        let workspace = URL(fileURLWithPath: "/Users/me/ws")
        vm.sessionsByProject[workspace.path] = [
            SessionSummary(id: "sess-42",
                           agentID: .claudeCode,
                           workspace: workspace,
                           title: "Claude",
                           lastActivity: Date(),
                           messageCount: 2)
        ]

        vm.openSession(projectPath: workspace.path, id: "sess-42")
        #expect(vm.isComposerLockedForSessionResume)

        await bus.publish(.userTurn(id: UUID().uuidString, text: "historical"))
        await drain()
        #expect(!vm.isSwitchingSession)
        #expect(vm.isComposerLockedForSessionResume)

        await bus.publish(.sessionStarted(sessionID: "sess-42",
                                          model: "sonnet",
                                          cwd: workspace))
        await drain()
        #expect(vm.isComposerLockedForSessionResume)

        clock.advance(by: SessionSwitchingTiming.claudeCodeComposerHookUnlock + .milliseconds(1))
        try? await Task.sleep(for: .milliseconds(40))

        #expect(!vm.isComposerLockedForSessionResume)

        await bus.shutdown()
    }

    @Test("openSession unlocks composer on hook SessionStart with model")
    func openSessionUnlocksComposerOnHookSessionStart() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.openSession(projectPath: "/Users/me/ws", id: "sess-42")
        #expect(vm.isComposerLockedForSessionResume)

        await bus.publish(.sessionStarted(sessionID: "sess-42",
                                          model: "sonnet",
                                          cwd: URL(fileURLWithPath: "/Users/me/ws")))
        await drain()

        #expect(!vm.isComposerLockedForSessionResume)

        await bus.shutdown()
    }

    @Test("openSession keeps switching state while empty resume still locks the composer")
    func openSessionKeepsSwitchingWhileComposerLockedOnEmptyResume() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let clock = FakeClock()
        let vm = EngineViewModel(engine: port, bus: bus, clock: clock, random: FakeRandomSource())
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.openSession(projectPath: "/Users/me/ws", id: "sess-42")
        #expect(vm.isSwitchingSession)
        #expect(vm.isComposerLockedForSessionResume)

        await waitForPendingSleeps(clock, count: 2)
        clock.advance(by: SessionSwitchingTiming.emptySessionFallback + .milliseconds(1))
        try? await Task.sleep(for: .milliseconds(40))

        #expect(vm.isSwitchingSession)
        #expect(vm.isComposerLockedForSessionResume)

        clock.advance(by: SessionSwitchingTiming.composerHardUnlock + .milliseconds(1))
        try? await Task.sleep(for: .milliseconds(40))

        #expect(!vm.isSwitchingSession)
        #expect(!vm.isComposerLockedForSessionResume)

        await bus.shutdown()
    }

    @Test("openSession composer lock has a hard fallback")
    func openSessionComposerLockHardFallback() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let clock = FakeClock()
        let vm = EngineViewModel(engine: port, bus: bus, clock: clock, random: FakeRandomSource())
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.openSession(projectPath: "/Users/me/ws", id: "sess-42")
        #expect(vm.isComposerLockedForSessionResume)

        await waitForPendingSleeps(clock, count: 2)
        clock.advance(by: SessionSwitchingTiming.composerHardUnlock + .milliseconds(1))
        try? await Task.sleep(for: .milliseconds(40))

        #expect(!vm.isComposerLockedForSessionResume)

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
    func createProjectPersistsMixedDefault() async throws {
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
        try await vm.adoptEmptyWorkspace(workspace)

        await AdapterRegistry.shared.register(MockAdapter(
            id: .claudeCode,
            displayName: "Claude Code",
            models: [AgentModelOption(id: "sonnet", label: "Sonnet")]
        ))
        await AdapterRegistry.shared.register(MockAdapter(
            id: .codex,
            displayName: "Codex",
            models: [AgentModelOption(id: "gpt", label: "GPT")]
        ))
        await AdapterRegistry.shared.register(MockAdapter(
            id: .cursorCLI,
            displayName: "Cursor",
            models: [AgentModelOption(id: "auto", label: "Auto")]
        ))

        await vm.createProject(name: "mixed", projectType: .mixed(defaultAgent: .claudeCode))
        try? await Task.sleep(for: .milliseconds(40))

        let project = await store.project(path: workspace.appendingPathComponent("mixed").path)
        #expect(project?.projectType == .mixed(defaultAgent: .claudeCode))
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

    @Test("sessionStarted for a previous project does not auto-switch the active project")
    func sessionStartedIgnoresStaleProject() async {
        let (vm, bus, _) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let cursor = URL(fileURLWithPath: "/Users/me/ws/cursor")
        let claude = URL(fileURLWithPath: "/Users/me/ws/claude")
        vm.workspaceRoot = URL(fileURLWithPath: "/Users/me/ws")
        vm.workspace = claude
        vm.sessionID = "claude-1"
        vm.availableModels = [AgentModelOption(id: "sonnet", label: "Sonnet")]
        vm.availableAgentModes = [
            AgentModeOption(id: "think", label: "Think", selectCommands: []),
        ]

        // Late SessionStart from the Cursor project the user already left.
        await bus.publish(.sessionStarted(sessionID: "cursor-late", model: "auto", cwd: cursor))
        await drain()

        #expect(vm.workspace?.path == claude.path)
        #expect(vm.sessionID == "claude-1")
        #expect(vm.availableModels.map(\.id) == ["sonnet"])
        #expect(vm.availableAgentModes.map(\.id) == ["think"])

        await bus.shutdown()
    }

    @Test("sessionStarted for a subproject keeps workspaceRoot and project sections")
    func sessionStartedSubprojectKeepsWorkspaceProjects() async throws {
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
        try await vm.adoptEmptyWorkspace(workspace)

        let ref = try! await store.createProject(name: "api", projectType: .claudeCode, in: workspace)
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

        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: ws))
        await drain()
        #expect(listerCalls.count == 1)

        await bus.shutdown()
    }

    @Test("sessionStarted with a real session id after bootstrap empty id reloads sessions")
    func sessionStartedRealIDReloadsSessions() async {
        final class CallCounter: @unchecked Sendable {
            var count = 0
            var lastURL: URL?
        }
        let listerCalls = CallCounter()
        let (vm, bus, _) = makeModel()
        vm.supportsResumableSessions = true
        vm.sessionLister = { url in
            listerCalls.count += 1
            listerCalls.lastURL = url
            if listerCalls.count == 1 { return [] }
            return [
                SessionSummary(id: "thread-1", agentID: .codex, workspace: url,
                               title: "First chat", lastActivity: Date(), messageCount: 1),
            ]
        }
        vm.subscribe()
        defer { vm.unsubscribe() }

        let project = URL(fileURLWithPath: "/Users/me/ws/api")
        // Engine bootstrap publishes an empty session id before Codex thread/start.
        await bus.publish(.sessionStarted(sessionID: "", model: nil, cwd: project))
        await drain()
        #expect(listerCalls.count == 1)
        #expect(vm.sessionsByProject[project.path] == [])

        await bus.publish(.sessionStarted(sessionID: "thread-1", model: nil, cwd: project))
        await drain()
        #expect(listerCalls.count == 2)
        #expect(vm.sessionsByProject[project.path]?.map(\.id) == ["thread-1"])
        #expect(listerCalls.lastURL?.path == project.path)

        await bus.shutdown()
    }

    @Test("new Codex session id on the same project reloads the sidebar session list")
    func newSessionIDReloadsSessions() async {
        final class CallCounter: @unchecked Sendable {
            var count = 0
        }
        let listerCalls = CallCounter()
        let (vm, bus, _) = makeModel()
        vm.supportsResumableSessions = true
        vm.sessionLister = { url in
            listerCalls.count += 1
            return [
                SessionSummary(id: "thread-\(listerCalls.count)", agentID: .codex,
                               workspace: url, title: "Chat \(listerCalls.count)",
                               lastActivity: Date(), messageCount: 1),
            ]
        }
        vm.subscribe()
        defer { vm.unsubscribe() }

        let project = URL(fileURLWithPath: "/Users/me/ws/api")
        await bus.publish(.sessionStarted(sessionID: "thread-1", model: nil, cwd: project))
        await drain()
        #expect(listerCalls.count == 1)

        // File → New Chat / .newSession eventually yields a new thread id.
        await bus.publish(.sessionStarted(sessionID: "thread-2", model: nil, cwd: project))
        await drain()
        #expect(listerCalls.count == 2)
        #expect(vm.sessionsByProject[project.path]?.first?.id == "thread-2")

        await bus.shutdown()
    }

    @Test("modelCatalogAgentIDs only includes shipping adapters used by workspace projects")
    func modelCatalogAgentIDsScopedToWorkspaceProjects() {
        let ids = EngineViewModel.modelCatalogAgentIDs(in: [
            .init(path: "/ws/claude", displayName: "Claude", projectType: .claudeCode),
            .init(path: "/ws/cursor", displayName: "Cursor", projectType: .cursorCLI),
            .init(path: "/ws/mixed", displayName: "Mixed",
                  projectType: .mixed(defaultAgent: .codex)),
            .init(path: "/ws/custom", displayName: "Custom",
                  projectType: .custom(CustomAgentRef(
                    id: "x",
                    displayName: "X",
                    transport: .agentClientProtocol,
                    executablePath: "/bin/x",
                    arguments: []
                  ))),
        ])
        // Mixed expands to every shipping agent; custom contributes none.
        #expect(ids == [.claudeCode, .cursorCLI, .codex])
        #expect(EngineViewModel.modelCatalogAgentIDs(for: .mixed(defaultAgent: .claudeCode))
                == SupportedBuiltInAgent.shippingIDs())
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

private func waitForPendingSleeps(_ clock: FakeClock, count: Int) async {
    let start = ContinuousClock.now
    while clock.pendingSleepCount < count, start.duration(to: .now) < .seconds(2) {
        try? await Task.sleep(for: .milliseconds(10))
    }
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
