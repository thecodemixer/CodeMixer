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

        let ws = TestPaths.workspace("ws")
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
        vm.loadSessions(for: TestPaths.workspacePath("ws"))
        #expect(vm.sessionsByProject[TestPaths.workspacePath("ws")] == [])
        await bus.shutdown()
    }

    @Test("loadSessions uses project-specific support when the current adapter is non-resumable")
    func loadSessionsUsesProjectSpecificSupport() async {
        let (vm, bus, _) = makeModel()
        let path = TestPaths.workspacePath("ws/claude")
        vm.supportsResumableSessions = false
        vm.projectCapabilities[path] = .init(
            supportsResumableSessions: true,
            requiresSessionHandshakeGate: false
        )
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
        let path = TestPaths.workspacePath("ws")
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

    @Test("openOverview with known dashboard URL selects dashboard without session load")
    func openOverviewKnownDashboardSkipsSessionLoad() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let project = TestPaths.workspace("ws/migration")
        let dashboardURL = URL(string: "http://127.0.0.1:9422/")!
        vm.workspace = project
        vm.sessionID = "file:Orders.cs"
        vm.dashboardURL = dashboardURL
        vm.dashboardTitle = "Migration Dashboard"
        vm.messages = [.assistant(bubbleID: UUID(), text: "file chat")]
        vm.supportsResumableSessions = true
        vm.projectCapabilities[project.path] = .init(
            supportsResumableSessions: true,
            requiresSessionHandshakeGate: true,
            supportsOverviewDashboard: true
        )
        vm.sessionsByProject[project.path] = [
            SessionSummary(
                id: "control",
                agentID: .other,
                workspace: project,
                title: "Migration Dashboard",
                lastActivity: .distantPast,
                messageCount: 0,
                isOverview: true,
                overviewURL: dashboardURL
            ),
            SessionSummary(
                id: "file:Orders.cs",
                agentID: .other,
                workspace: project,
                title: "Orders.cs",
                lastActivity: .distantPast,
                messageCount: 1,
                isOverview: false
            ),
        ]

        vm.openOverview(projectPath: project.path)
        await drain()

        #expect(vm.showsOverviewDashboard)
        #expect(vm.sessionID == nil)
        #expect(vm.dashboardURL == dashboardURL)
        #expect(vm.messages.isEmpty)
        #expect(!port.commands.contains {
            if case .openProject = $0 { return true }
            return false
        })

        await bus.shutdown()
    }

    @Test("selectProject for an overview-capable project opens Overview")
    func selectProjectOpensOverviewForDashboardCapableAgent() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let other = TestPaths.workspace("ws/other")
        let migration = TestPaths.workspace("ws/migration")
        let dashboardURL = URL(string: "http://127.0.0.1:9422/")!
        vm.workspace = other
        vm.sessionID = "other-chat"
        vm.projectCapabilities[migration.path] = .init(
            supportsResumableSessions: true,
            requiresSessionHandshakeGate: true,
            supportsOverviewDashboard: true
        )
        vm.sessionsByProject[migration.path] = [
            SessionSummary(
                id: "control",
                agentID: .other,
                workspace: migration,
                title: "Migration Dashboard",
                lastActivity: .distantPast,
                messageCount: 0,
                isOverview: true,
                overviewURL: dashboardURL
            ),
        ]

        vm.selectProject(path: migration.path)
        await drain()

        #expect(vm.workspace?.path == migration.path)
        #expect(vm.showsOverviewDashboard)
        #expect(vm.sessionID == nil)
        #expect(vm.dashboardURL == dashboardURL)
        #expect(port.commands.contains {
            if case .openProject(let path, let resume) = $0 {
                return path == migration.path && resume == nil
            }
            return false
        })

        await bus.shutdown()
    }

    @Test("renameProject follows the renamed active project path")
    func renameProjectFollowsRenamedActivePath() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        let workspace = TestPaths.workspace("ws")
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
        vm.projectCapabilities[oldPath] = .init(
            supportsResumableSessions: true,
            requiresSessionHandshakeGate: false
        )

        vm.renameProject(path: oldPath, newName: "Backend")
        await drain()

        #expect(vm.workspace?.path == newPath)
        #expect(vm.projects.map(\.path) == [newPath])
        #expect(vm.sessionsByProject[oldPath] == nil)
        #expect(vm.sessionsByProject[newPath]?.first?.id == "s1")
        #expect(!vm.loadingProjectPaths.contains(oldPath))
        #expect(vm.loadingProjectPaths.contains(newPath))
        #expect(vm.projectCapabilities[oldPath] == nil)
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
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        let workspace = TestPaths.workspace("ws")
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

        let ws = TestPaths.workspace("ws")
        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: ws))
        await drain()

        vm.messages = [.user(bubbleID: UUID(), text: "old")]
        vm.newChat(in: ws.path)
        vm.newChat(in: TestPaths.workspacePath("other"))
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
                return path == TestPaths.workspacePath("other") && resume == nil
            }
            return false
        })
        #expect(vm.messages.isEmpty)
        #expect(vm.workspace?.path == TestPaths.workspacePath("other"))

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

        let project = TestPaths.workspace("ws/api")
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
            .init(path: TestPaths.workspacePath("ws/api"), displayName: "API", projectType: .codex),
            .init(path: TestPaths.workspacePath("ws/web"), displayName: "Web", projectType: .claudeCode),
        ]
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "old", model: nil,
                                          cwd: TestPaths.workspace("ws/web")))
        await drain()
        #expect(vm.currentProjectDisplayName == "Web")

        vm.openSession(projectPath: TestPaths.workspacePath("ws/api"), id: "sess-42")
        #expect(vm.workspace?.path == TestPaths.workspacePath("ws/api"))
        #expect(vm.currentProjectDisplayName == "API")

        await bus.shutdown()
    }

    @Test("selectProject opens the most recent session when available")
    func selectProjectOpensRecentSession() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let api = TestPaths.workspace("ws/api")
        vm.sessionsByProject[api.path] = [
            SessionSummary(id: "recent", agentID: .codex, workspace: api,
                           title: "Latest", lastActivity: Date(), messageCount: 3),
        ]
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "web-1", model: nil,
                                          cwd: TestPaths.workspace("ws/web")))
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

        vm.openSession(projectPath: TestPaths.workspacePath("ws"), id: "sess-42")
        try? await Task.sleep(for: .milliseconds(60))

        #expect(port.commands.contains {
            if case .openProject(let path, let resume) = $0 {
                return path == TestPaths.workspacePath("ws") && resume == "sess-42"
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

        vm.openSession(projectPath: TestPaths.workspacePath("ws"), id: "sess-42")
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

        vm.openSession(projectPath: TestPaths.workspacePath("ws"), id: "sess-42")
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

    @Test("Cursor openSession stays locked through history until live SessionStart")
    func cursorOpenSessionKeepsComposerLockedThroughHistoryReplay() async {
        await AdapterRegistry.shared.register(MockAdapter(
            id: .cursorCLI,
            displayName: "Cursor",
            capabilities: [.sessionHandshakeGate, .resumableSessions]
        ))
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let clock = FakeClock()
        let vm = EngineViewModel(engine: port, bus: bus, clock: clock, random: FakeRandomSource())
        let project = TestPaths.workspace("ws/cursor")
        vm.projects = [
            .init(path: project.path, displayName: "Cursor", projectType: .cursorCLI),
        ]
        vm.projectCapabilities[project.path] = .init(
            supportsResumableSessions: true,
            requiresSessionHandshakeGate: true
        )
        vm.sessionsByProject[project.path] = [
            SessionSummary(
                id: "sess-cursor",
                agentID: .cursorCLI,
                workspace: project,
                title: "Prior",
                lastActivity: Date(),
                messageCount: 2
            ),
        ]
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.openSession(projectPath: project.path, id: "sess-cursor")
        #expect(vm.isComposerLockedForSessionResume)

        // Past the short Codex-style unlock — handshake gate must still hold.
        clock.advance(by: SessionSwitchingTiming.composerHardUnlock + .milliseconds(1))
        await drain()
        #expect(vm.isComposerLockedForSessionResume)

        await bus.publish(.userTurn(id: UUID().uuidString, text: "prior user"))
        await bus.publish(.assistantText(
            id: UUID().uuidString,
            blockID: "a",
            text: "prior assistant",
            isFinal: true
        ))
        await drain()
        #expect(vm.messages.count >= 2)
        #expect(vm.isComposerLockedForSessionResume)

        await bus.publish(.sessionStarted(
            sessionID: "sess-cursor",
            model: "auto",
            cwd: project
        ))
        await drain()
        #expect(!vm.isComposerLockedForSessionResume)

        await bus.shutdown()
    }

    @Test("same-project openSession on a live ACP process uses warm switch lock")
    func openSessionOnLiveProjectUsesWarmSwitchLock() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let project = TestPaths.workspace("ws/custom-acp")
        vm.workspace = project
        vm.sessionID = "overview"
        vm.dashboardURL = URL(string: "http://127.0.0.1:9/")
        vm.projects = [
            .init(path: project.path, displayName: "Migration", projectType: .cursorCLI),
        ]
        vm.projectCapabilities[project.path] = .init(
            supportsResumableSessions: true,
            requiresSessionHandshakeGate: true,
            supportsOverviewDashboard: true
        )
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.openSession(projectPath: project.path, id: "file:Orders.cs")
        #expect(vm.isWarmSessionSwitch)
        #expect(vm.isComposerLockedForSessionHandshake)
        #expect(vm.isComposerLockedForSessionResume)

        await bus.publish(.sessionStarted(
            sessionID: "file:Orders.cs",
            model: "auto",
            cwd: project
        ))
        await drain()
        #expect(!vm.isComposerLockedForSessionResume)
        #expect(!vm.isWarmSessionSwitch)

        await bus.shutdown()
    }

    @Test("new Cursor chat locks composer until the ACP session is ready")
    func newCursorChatLocksComposerUntilACPSessionReady() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let project = TestPaths.workspace("ws/cursor")
        vm.projects = [
            .init(path: project.path, displayName: "Cursor", projectType: .cursorCLI),
        ]
        vm.projectCapabilities[project.path] = .init(
            supportsResumableSessions: true,
            requiresSessionHandshakeGate: true
        )
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.newChat(in: project.path)
        #expect(vm.isComposerLockedForSessionResume)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(port.commands.contains {
            if case .openProject(let path, let resume) = $0 {
                return path == project.path && resume == nil
            }
            return false
        })

        vm.sendPrompt("too early")
        #expect(vm.messages.isEmpty)

        // Engine bootstrap publishes an empty id before Cursor ACP completes
        // initialize/auth/session-new; that is not prompt-ready.
        await bus.publish(.sessionStarted(sessionID: "", model: nil, cwd: project))
        await drain()
        #expect(vm.isComposerLockedForSessionResume)

        await bus.publish(.sessionStarted(sessionID: "cursor-session", model: nil, cwd: project))
        await drain()
        #expect(!vm.isComposerLockedForSessionResume)

        vm.sendPrompt("now allowed")
        #expect(vm.messages.count == 1)

        await bus.shutdown()
    }

    @Test("new Cursor chat on the same project reuses session/new instead of respawning")
    func newCursorChatOnSameProjectUsesNewSession() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let project = TestPaths.workspace("ws/cursor")
        vm.projects = [
            .init(path: project.path, displayName: "Cursor", projectType: .cursorCLI),
        ]
        vm.projectCapabilities[project.path] = .init(
            supportsResumableSessions: true,
            requiresSessionHandshakeGate: true
        )
        vm.workspace = project
        vm.sessionID = "cursor-session"
        vm.messages = [.user(bubbleID: UUID(), text: "old")]
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.newChat(in: project.path)
        try? await Task.sleep(for: .milliseconds(60))

        #expect(vm.isComposerLockedForSessionResume)
        #expect(vm.messages.contains {
            if case .clientAction(let action) = $0 {
                return action.kind == .sessionLifecycle && action.detail == "New session"
            }
            return false
        } || port.commands.contains {
            if case .newSession = $0 { return true }
            if case .recordClientAction = $0 { return true }
            return false
        })
        #expect(!port.commands.contains {
            if case .openProject = $0 { return true }
            return false
        })

        await bus.shutdown()
    }

    @Test("new Codex chat keeps the composer immediately available")
    func newCodexChatDoesNotUseACPComposerLock() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let project = TestPaths.workspace("ws/api")
        vm.projects = [
            .init(path: project.path, displayName: "API", projectType: .codex),
        ]
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.newChat(in: project.path)
        #expect(!vm.isComposerLockedForSessionResume)

        vm.sendPrompt("ready")
        #expect(vm.messages.count == 1)

        await bus.shutdown()
    }

    @Test("prepareProjectOpen gates mixed projects when a handshake-capable adapter is registered")
    func prepareProjectOpenGatesMixedWithoutDefaultWhenHandshakeAdapterRegistered() async {
        await AdapterRegistry.shared.register(MockAdapter(
            id: .cursorCLI,
            displayName: "Cursor Mock",
            capabilities: [.sessionHandshakeGate, .resumableSessions]
        ))
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let project = TestPaths.workspace("ws/mixed")

        await vm.prepareProjectOpen(url: project, projectType: .mixed(defaultAgent: nil))
        #expect(vm.isComposerLockedForSessionResume)
        #expect(vm.projectCapabilities.requiresSessionHandshakeGate(for: project.path))

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

        let workspace = TestPaths.workspace("ws")
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

        vm.openSession(projectPath: TestPaths.workspacePath("ws"), id: "sess-42")
        #expect(vm.isComposerLockedForSessionResume)

        await bus.publish(.sessionStarted(sessionID: "sess-42",
                                          model: "sonnet",
                                          cwd: TestPaths.workspace("ws")))
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

        vm.openSession(projectPath: TestPaths.workspacePath("ws"), id: "sess-42")
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

        vm.openSession(projectPath: TestPaths.workspacePath("ws"), id: "sess-42")
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

        vm.openSession(projectPath: TestPaths.workspacePath("ws"), id: "sess-42")
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
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store
        vm.subscribe()
        defer { vm.unsubscribe() }

        let workspace = TestPaths.workspace("ws")
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

    @Test("createOrAddProject(ProjectDraft) persists preferFresh and opens the project")
    func createOrAddProjectDraftPreferFresh() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store
        vm.subscribe()
        defer { vm.unsubscribe() }

        let workspace = TestPaths.workspace("ws-info-create")
        try await vm.adoptEmptyWorkspace(workspace)
        await AdapterRegistry.shared.register(MockAdapter(
            id: .claudeCode,
            displayName: "Claude Code",
            models: [AgentModelOption(id: "sonnet", label: "Sonnet")]
        ))

        await vm.createOrAddProject(ProjectDraft(
            name: "freshy",
            projectType: .claudeCode,
            preferFreshAgentProcess: true
        ))
        try? await Task.sleep(for: .milliseconds(40))

        let project = await store.project(path: workspace.appendingPathComponent("freshy").path)
        #expect(project?.preferFreshAgentProcess == true)
        #expect(project?.agentInstanceIdentity != .shared)
        #expect(port.commands.contains {
            if case .openProject(let path, let resume) = $0 {
                return path == project?.path && resume == nil
            }
            return false
        })

        await bus.shutdown()
    }

    @Test("createOrAddProject(ProjectDraft) with existingFolderURL adopts the folder")
    func createOrAddProjectDraftExistingFolder() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store
        vm.subscribe()
        defer { vm.unsubscribe() }

        let workspace = TestPaths.workspace("ws-info-add")
        try await vm.adoptEmptyWorkspace(workspace)
        await AdapterRegistry.shared.register(MockAdapter(
            id: .claudeCode,
            displayName: "Claude Code",
            models: [AgentModelOption(id: "sonnet", label: "Sonnet")]
        ))

        let external = TestPaths.underTemporary("external-proj")
        try fileSystem.createDirectory(at: external, withIntermediates: true)
        let info = ProjectDraft.existingFolder(external, preferFreshAgentProcess: true)
            .withProjectType(.claudeCode)
        await vm.createOrAddProject(info)
        try? await Task.sleep(for: .milliseconds(40))

        let project = await store.project(path: external.path)
        #expect(project?.preferFreshAgentProcess == true)
        #expect(project?.displayName == external.lastPathComponent)
        #expect(vm.workspaceRoot?.path == workspace.path)
        #expect(vm.projects.contains { $0.path == external.path })
        #expect(port.commands.contains {
            if case .openProject(let path, let resume) = $0 {
                return path == external.path && resume == nil
            }
            return false
        })

        await bus.shutdown()
    }

    @Test("addExistingProject keeps workspaceRoot and lists the external folder")
    func addExistingProjectKeepsWorkspaceRoot() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store
        vm.subscribe()
        defer { vm.unsubscribe() }

        let workspace = TestPaths.workspace("ws-add-existing")
        try await vm.adoptEmptyWorkspace(workspace)
        await AdapterRegistry.shared.register(MockAdapter(
            id: .codex,
            displayName: "Codex",
            models: [AgentModelOption(id: "gpt", label: "GPT")]
        ))

        let external = TestPaths.underTemporary("add-existing-repo")
        try fileSystem.createDirectory(at: external, withIntermediates: true)
        await vm.addExistingProject(
            url: external,
            projectType: .codex,
            displayName: "External Repo"
        )
        try? await Task.sleep(for: .milliseconds(40))

        #expect(vm.workspaceRoot?.path == workspace.path)
        #expect(vm.projects.contains {
            $0.path == external.path && $0.displayName == "External Repo"
        })
        let stored = await store.project(path: external.path)
        #expect(stored?.projectType == .codex)
        #expect(stored?.displayName == "External Repo")
        let listed = await store.projects(for: workspace)
        #expect(listed.contains { $0.path == external.path })

        await bus.shutdown()
    }

    @Test("createProject for a folder type opens the browser without openProject")
    func createFolderProjectDoesNotOpenAgent() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store
        vm.subscribe()
        defer { vm.unsubscribe() }

        let workspace = TestPaths.workspace("ws-folder")
        try await vm.adoptEmptyWorkspace(workspace)
        await vm.createProject(name: "logs", projectType: .folder(.logs))
        try? await Task.sleep(for: .milliseconds(40))

        let project = await store.project(path: workspace.appendingPathComponent("logs").path)
        #expect(project?.projectType == .folder(.logs))
        #expect(vm.showsFolderBrowser)
        #expect(vm.activeFolderProjectKind == .logs)
        #expect(vm.workspace?.path == project?.path)
        #expect(!port.commands.contains {
            if case .openProject = $0 { return true }
            return false
        })

        await bus.shutdown()
    }

    @Test("selectProject for a folder type never sends openProject")
    func selectFolderProjectSkipsAgent() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store

        let workspace = TestPaths.workspace("ws-folder-select")
        try await vm.adoptEmptyWorkspace(workspace)
        let ref = try await store.createProject(name: "docs", projectType: .folder(.docs), in: workspace)
        await vm.applyProjectList(await store.projects(for: workspace))
        vm.selectProject(path: ref.path)

        #expect(vm.showsFolderBrowser)
        #expect(vm.activeFolderProjectKind == .docs)
        #expect(port.commands.isEmpty)

        await bus.shutdown()
    }

    @Test("openFolderShortcut enters preview-only mode for the pinned path")
    func openFolderShortcutFocusesPreview() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store

        let workspace = TestPaths.workspace("ws-folder-pin")
        try await vm.adoptEmptyWorkspace(workspace)
        let ref = try await store.createProject(name: "docs", projectType: .folder(.docs), in: workspace)
        await vm.applyProjectList(await store.projects(for: workspace))

        vm.openFolderShortcut(projectPath: ref.path, relativePath: "readme.md")
        #expect(vm.showsFolderBrowser)
        #expect(vm.showsPreviewOnly)
        #expect(vm.activeFolderSelectionRelativePath == "readme.md")
        #expect(vm.pendingFolderSelectionRelativePath == nil)

        vm.exitFolderPreviewOnly()
        #expect(!vm.showsPreviewOnly)
        #expect(vm.activeFolderSelectionRelativePath == "readme.md")

        await bus.shutdown()
    }

    @Test("openFolderShortcut for files does not enter preview-only mode")
    func openFolderShortcutFilesKeepsList() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store

        let workspace = TestPaths.workspace("ws-folder-files-pin")
        try await vm.adoptEmptyWorkspace(workspace)
        let ref = try await store.createProject(name: "files", projectType: .folder(.files), in: workspace)
        await vm.applyProjectList(await store.projects(for: workspace))

        vm.openFolderShortcut(projectPath: ref.path, relativePath: "notes.txt")
        #expect(vm.showsFolderBrowser)
        #expect(!vm.showsPreviewOnly)
        #expect(vm.activeFolderSelectionRelativePath == "notes.txt")
        #expect(vm.pendingFolderSelectionRelativePath == "notes.txt")

        await bus.shutdown()
    }

    @Test("sessionStarted for a previous project does not auto-switch the active project")
    func sessionStartedIgnoresStaleProject() async {
        let (vm, bus, _) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let cursor = TestPaths.workspace("ws/cursor")
        let claude = TestPaths.workspace("ws/claude")
        vm.workspaceRoot = TestPaths.workspace("ws")
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
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store
        vm.subscribe()
        defer { vm.unsubscribe() }

        let workspace = TestPaths.workspace("ws")
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

        let ws = TestPaths.workspace("ws")
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

        let project = TestPaths.workspace("ws/api")
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

        let project = TestPaths.workspace("ws/api")
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

    @Test("restartCustomACPCLI closes then cold-opens and waits for a fresh dashboard")
    func restartCustomACPCLIRespawnsProcess() async {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let clock = FakeClock()
        let vm = EngineViewModel(engine: port, bus: bus, clock: clock, random: FakeRandomSource())
        vm.subscribe()
        defer { vm.unsubscribe() }

        let customRef = CustomAgentRef(
            id: "mig",
            displayName: "Migrator",
            transport: .agentClientProtocol,
            executablePath: "/usr/bin/env",
            arguments: ["bun", "run", "src/main.ts"]
        )
        let custom = WorkspaceProjectsStore.ProjectRef(
            path: TestPaths.workspacePath("ws/mig"),
            displayName: "mig",
            projectType: .custom(customRef)
        )
        let claude = WorkspaceProjectsStore.ProjectRef(
            path: TestPaths.workspacePath("ws/claude"),
            displayName: "claude",
            projectType: .claudeCode
        )
        vm.projects = [custom, claude]
        vm.projectCapabilities[custom.path] = .init(
            supportsResumableSessions: true,
            requiresSessionHandshakeGate: true,
            supportsOverviewDashboard: true
        )
        vm.dashboardURL = URL(string: "http://127.0.0.1:9/")
        vm.dashboardTitle = "Migration Dashboard"
        vm.messages = [.user(bubbleID: UUID(), text: "stale")]
        vm.detailPane = .dashboard
        let reviewPrompt = PermissionPrompt(toolName: "Review",
                                            summary: "stale review",
                                            argumentsSummary: "{}",
                                            requestedAt: Date())
        vm.sessionsByProject[custom.path] = [
            SessionSummary(
                id: "file:Orders.cs",
                agentID: .other,
                workspace: URL(fileURLWithPath: custom.path),
                title: "Orders.cs",
                lastActivity: .distantPast,
                messageCount: 1,
                needsAttention: true
            ),
        ]
        vm.pendingPermissionsBySession["file:Orders.cs"] = reviewPrompt

        #expect(vm.isCustomACPProject(custom))
        #expect(!vm.isCustomACPProject(claude))

        vm.restartCustomACPCLI(projectPath: claude.path)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(port.commands.isEmpty)
        #expect(vm.dashboardURL != nil)

        let generationBeforeRestart = vm.dashboardLoadGeneration
        vm.restartCustomACPCLI(projectPath: custom.path)
        #expect(vm.dashboardLoadGeneration == generationBeforeRestart + 1)
        #expect(vm.isRestartingCustomACPCLI)
        #expect(vm.dashboardURL == nil)
        #expect(vm.showsOverviewDashboard)
        #expect(vm.pendingPermissionsBySession.isEmpty)
        #expect(vm.sessionsByProject[custom.path]?.allSatisfy { !$0.needsAttention } == true)

        await bus.publish(.agentDashboard(url: URL(string: "http://127.0.0.1:9/")!, title: "Old Dashboard"))
        await drain()
        #expect(vm.isRestartingCustomACPCLI)
        #expect(vm.dashboardURL == nil)

        await waitForPendingSleeps(clock, count: 1)
        clock.advance(by: .milliseconds(300))
        try? await Task.sleep(for: .milliseconds(80))

        let commands = port.commands
        let closeIndex = commands.firstIndex { $0 == .closeSession }
        let openIndex = commands.firstIndex {
            if case .openProject(let path, let resume) = $0 {
                return path == custom.path && resume == nil
            }
            return false
        }
        #expect(closeIndex != nil)
        #expect(openIndex != nil)
        if let closeIndex, let openIndex {
            #expect(closeIndex < openIndex)
        }
        #expect(commands.contains {
            if case .recordClientAction(let action) = $0 {
                return action.detail == "Restart ACP CLI"
            }
            return false
        })
        #expect(vm.isRestartingCustomACPCLI)
        #expect(vm.customACPRestartAwaitingDashboard)
        #expect(vm.workspace?.path == custom.path)

        await bus.publish(.agentDashboard(url: URL(string: "http://127.0.0.1:99/")!, title: "Migration Dashboard"))
        await drain()
        #expect(!vm.isRestartingCustomACPCLI)
        #expect(vm.dashboardURL?.absoluteString == "http://127.0.0.1:99/")

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
