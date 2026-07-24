import Foundation
import Testing
@testable import AgentUI
@testable import AgentCore
import AgentProtocol
import ClaudeCode
import Codex
import ACPCLIs

/// Live probe of the **GUI command path**: `EngineViewModel.openSession` /
/// `sendPrompt` → `AgentCommand.openProject` / `sendPrompt` → bus → messages.
///
/// Harness suites call `AgentEngine.start` directly. This suite mirrors what
/// the sidebar + composer do, so ViewModel gating / SessionStart filtering /
/// composer lock bugs surface here even when adapter harnesses are green.
///
/// ```bash
/// CODEMIXER_LIVE_GUI_PATH=1 \
///   swift test --no-parallel --filter LiveGUIPathProbeTests
/// ```
@Suite("Live GUI path — EngineViewModel openSession + sendPrompt", .serialized)
@MainActor
struct LiveGUIPathProbeTests {

    private static let enableVariable = "CODEMIXER_LIVE_GUI_PATH"

    @Test("Claude Code project: resume shows history and answers a follow-up")
    func claudeResumeHistoryAndReply() async throws {
        try await runResumeProbe(
            label: "claude",
            projectPath: "/Users/hari/Documents/codemixer workspace/hiya",
            adapter: ClaudeAdapter(),
            seedPrompt: "Reply with exactly: gui-claude-pong",
            seedNeedle: "gui-claude-pong",
            followUpPrompt: "Reply with exactly: gui-claude-resume",
            followUpNeedle: "gui-claude-resume"
        )
    }

    @Test("Codex project: resume shows history and answers a follow-up")
    func codexResumeHistoryAndReply() async throws {
        try await runResumeProbe(
            label: "codex",
            projectPath: "/Users/hari/Documents/codemixer workspace/hiya/code",
            adapter: CodexAdapter(),
            seedPrompt: "Reply with exactly: gui-codex-pong",
            seedNeedle: "gui-codex-pong",
            followUpPrompt: "Reply with exactly: gui-codex-resume",
            followUpNeedle: "gui-codex-resume"
        )
    }

    @Test("Cursor CLI project: resume shows history and answers a follow-up")
    func cursorResumeHistoryAndReply() async throws {
        try await runResumeProbe(
            label: "cursor",
            projectPath: "/Users/hari/Documents/codemixer workspace/hiya/cur",
            adapter: CursorACPAdapter(),
            seedPrompt: "Reply with exactly: gui-cursor-pong",
            seedNeedle: "gui-cursor-pong",
            followUpPrompt: "Reply with exactly: gui-cursor-resume",
            followUpNeedle: "gui-cursor-resume"
        )
    }

    // MARK: - Driver

    private func runResumeProbe(
        label: String,
        projectPath: String,
        adapter: any AgentAdapter,
        seedPrompt: String,
        seedNeedle: String,
        followUpPrompt: String,
        followUpNeedle: String
    ) async throws {
        guard ProcessInfo.processInfo.environment[Self.enableVariable] == "1" else { return }

        await AdapterRegistry.shared.register(adapter)

        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        let projectsStore = WorkspaceProjectsStore(environment: Seams.live.environment,
                                                   fileSystem: Seams.live.fileSystem)
        await projectsStore.load()

        let engine = AgentEngine(seams: .live)
        await engine.bootstrap()
        let vm = EngineViewModel(engine: engine, bus: engine.bus)
        vm.workspaceProjects = projectsStore
        vm.subscribe()
        defer {
            vm.unsubscribe()
            Task { await engine.shutdown(reason: .naturalExit) }
        }

        // --- Seed a fresh session via the same openProject(nil) the UI uses ---
        vm.workspace = projectURL
        vm.workspaceRoot = projectURL
        if let projectType = await projectsStore.resolveProjectType(for: projectURL) {
            vm.applyAdapterCapabilities(for: projectType, projectURL: projectURL)
        } else {
            vm.applyAdapterCapabilities(forProjectPath: projectPath)
        }
        // Give capability Task a beat before openProject.
        try? await Task.sleep(for: .milliseconds(200))
        vm.openProject(path: projectPath, resumeSessionID: nil)

        let seeded = await wait(timeout: .seconds(120)) {
            !vm.isComposerLockedForSessionResume
                && vm.messages.contains { messageContains($0, needle: seedNeedle) == false }
                && (vm.sessionID?.isEmpty == false || !vm.isComposerLockedForSessionResume)
        }
        // Wait until composer unlocks (SessionStart), then send.
        let unlockedSeed = await wait(timeout: .seconds(90)) { !vm.isComposerLockedForSessionResume }
        guard unlockedSeed else {
            Issue.record("\(label) seed: composer stayed locked diagnostics=\(vm.diagnostics.map(\.message))")
            return
        }
        vm.sendPrompt(seedPrompt)
        let seedOK = await wait(timeout: .seconds(120)) {
            messageListContainsAssistant(vm.messages, needle: seedNeedle)
        }
        guard seedOK else {
            Issue.record("""
                \(label) seed: no assistant reply \
                locked=\(vm.isComposerLockedForSessionResume) \
                session=\(vm.sessionID ?? "nil") \
                messages=\(vm.messages.count) \
                diagnostics=\(vm.diagnostics.map(\.message)) \
                silent=\(await SilentDiagnostics.shared.snapshot().suffix(6).map(\.summary))
                """)
            return
        }
        guard let seedSessionID = vm.sessionID, !seedSessionID.isEmpty else {
            Issue.record("\(label) seed: missing sessionID after reply")
            return
        }
        print("LIVE_GUI \(label) seed ok session=\(seedSessionID)")

        // --- Cold reopen via openSession (sidebar path) ---
        await engine.shutdown(reason: .naturalExit)
        // New engine + VM — mirrors quitting the chat process and clicking the row.
        let engine2 = AgentEngine(seams: .live)
        await engine2.bootstrap()
        let vm2 = EngineViewModel(engine: engine2, bus: engine2.bus)
        vm2.workspaceProjects = projectsStore
        vm2.subscribe()
        defer {
            vm2.unsubscribe()
            Task { await engine2.shutdown(reason: .naturalExit) }
        }
        vm2.workspaceRoot = projectURL
        if let projectType = await projectsStore.resolveProjectType(for: projectURL) {
            vm2.applyAdapterCapabilities(for: projectType, projectURL: projectURL)
        }
        try? await Task.sleep(for: .milliseconds(200))
        // Preload a fake session list so openSession does not treat the id as overview.
        vm2.sessionsByProject[projectPath] = [
            SessionSummary(id: seedSessionID,
                           agentID: adapter.id,
                           workspace: projectURL,
                           title: seedPrompt,
                           lastActivity: Date(),
                           messageCount: 2)
        ]
        vm2.openSession(projectPath: projectPath, id: seedSessionID)

        let historyOK = await wait(timeout: .seconds(90)) {
            messageListContainsUser(vm2.messages, needle: seedPrompt)
                && messageListContainsAssistant(vm2.messages, needle: seedNeedle)
        }
        print(
            "LIVE_GUI \(label) history user=\(messageListContainsUser(vm2.messages, needle: seedPrompt)) assistant=\(messageListContainsAssistant(vm2.messages, needle: seedNeedle)) locked=\(vm2.isComposerLockedForSessionResume) msgs=\(vm2.messages.count)"
        )
        #expect(historyOK, "\(label) openSession should replay history")

        let unlocked = await wait(timeout: .seconds(90)) { !vm2.isComposerLockedForSessionResume }
        guard unlocked else {
            Issue.record("\(label) resume: composer stayed locked diagnostics=\(vm2.diagnostics.map(\.message))")
            return
        }
        vm2.sendPrompt(followUpPrompt)
        let followOK = await wait(timeout: .seconds(120)) {
            messageListContainsAssistant(vm2.messages, needle: followUpNeedle)
        }
        print("LIVE_GUI \(label) follow-up ok=\(followOK) msgs=\(vm2.messages.count)")
        #expect(followOK, "\(label) follow-up after openSession should get a reply")
        _ = seeded
    }

    private func wait(timeout: Duration, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return condition()
    }

    private func messageListContainsUser(_ messages: [EngineViewModel.Message], needle: String) -> Bool {
        messages.contains {
            if case .user(_, let text) = $0 {
                return text.localizedCaseInsensitiveContains(needle)
            }
            return false
        }
    }

    private func messageListContainsAssistant(_ messages: [EngineViewModel.Message], needle: String) -> Bool {
        messages.contains {
            // Require a settled bubble — streaming can match the needle before
            // ACP `finalizePromptTurn` persists the assistant into the turn cache.
            if case .assistant(_, let text) = $0 {
                return text.localizedCaseInsensitiveContains(needle)
            }
            return false
        }
    }

    private func messageContains(_ message: EngineViewModel.Message, needle: String) -> Bool {
        messageListContainsAssistant([message], needle: needle)
            || messageListContainsUser([message], needle: needle)
    }
}
