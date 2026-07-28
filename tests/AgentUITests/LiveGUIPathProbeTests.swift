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
/// CODEMIXER_LIVE_CLAUDE_PROJECT=/path/to/claude-project \
/// CODEMIXER_LIVE_CODEX_PROJECT=/path/to/codex-project \
/// CODEMIXER_LIVE_CURSOR_PROJECT=/path/to/cursor-project \
///   swift test --no-parallel --filter LiveGUIPathProbeTests
/// ```
@Suite("Live GUI path — EngineViewModel openSession + sendPrompt", .serialized)
@MainActor
struct LiveGUIPathProbeTests {

    private static let enableVariable = "CODEMIXER_LIVE_GUI_PATH"

    @Test("Claude Code project: resume shows history and answers a follow-up")
    func claudeResumeHistoryAndReply() async throws {
        guard ProcessInfo.processInfo.environment[Self.enableVariable] == "1" else { return }
        guard let projectPath = Self.projectPath(envKey: "CODEMIXER_LIVE_CLAUDE_PROJECT") else {
            Issue.record("set CODEMIXER_LIVE_CLAUDE_PROJECT to a trusted Claude project directory")
            return
        }
        try await runResumeProbe(
            label: "claude",
            projectPath: projectPath,
            adapter: ClaudeAdapter(),
            seedPrompt: "Reply with exactly: gui-claude-pong",
            seedNeedle: "gui-claude-pong",
            followUpPrompt: "Reply with exactly: gui-claude-resume",
            followUpNeedle: "gui-claude-resume"
        )
    }

    @Test("Codex project: resume shows history and answers a follow-up")
    func codexResumeHistoryAndReply() async throws {
        guard ProcessInfo.processInfo.environment[Self.enableVariable] == "1" else { return }
        guard let projectPath = Self.projectPath(envKey: "CODEMIXER_LIVE_CODEX_PROJECT") else {
            Issue.record("set CODEMIXER_LIVE_CODEX_PROJECT to a trusted Codex project directory")
            return
        }
        try await runResumeProbe(
            label: "codex",
            projectPath: projectPath,
            adapter: CodexAdapter(),
            seedPrompt: "Reply with exactly: gui-codex-pong",
            seedNeedle: "gui-codex-pong",
            followUpPrompt: "Reply with exactly: gui-codex-resume",
            followUpNeedle: "gui-codex-resume"
        )
    }

    @Test("Cursor CLI project: resume shows history and answers a follow-up")
    func cursorResumeHistoryAndReply() async throws {
        guard ProcessInfo.processInfo.environment[Self.enableVariable] == "1" else { return }
        guard let projectPath = Self.projectPath(envKey: "CODEMIXER_LIVE_CURSOR_PROJECT") else {
            Issue.record("set CODEMIXER_LIVE_CURSOR_PROJECT to a trusted Cursor project directory")
            return
        }
        try await runResumeProbe(
            label: "cursor",
            projectPath: projectPath,
            adapter: CursorACPAdapter(),
            seedPrompt: "Reply with exactly: gui-cursor-pong",
            seedNeedle: "gui-cursor-pong",
            followUpPrompt: "Reply with exactly: gui-cursor-resume",
            followUpNeedle: "gui-cursor-resume"
        )
    }

    private static func projectPath(envKey: String) -> String? {
        let env = ProcessInfo.processInfo.environment[envKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let env, !env.isEmpty else { return nil }
        return env
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

        await AdapterRegistry.shared.register(id: adapter.id) {
            // Fresh instance per spawn — shared instances leave Cursor/Claude
            // event streams dead after the seed engine shuts down.
            switch adapter.id {
            case .claudeCode: return ClaudeAdapter()
            case .codex: return CodexAdapter()
            case .cursorCLI: return CursorACPAdapter()
            default: return adapter
            }
        }

        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        let projectsStore = WorkspaceProjectsStore(environment: Seams.live.environment,
                                                   fileSystem: Seams.live.fileSystem)
        await projectsStore.load()

        let engine = AgentEngine(seams: .live)
        await engine.bootstrap()
        let vm = EngineViewModel(engine: engine, bus: engine.bus)
        vm.workspaceProjects = projectsStore
        vm.subscribe()
        // Let the bus subscription register before open races SessionStart.
        try? await Task.sleep(for: .milliseconds(100))
        defer {
            vm.unsubscribe()
            Task { await engine.shutdown(reason: .naturalExit) }
        }

        // --- Seed a fresh session via the same open path the sidebar uses ---
        vm.workspaceRoot = projectURL.deletingLastPathComponent()
        if let projectType = await projectsStore.resolveProjectType(for: projectURL) {
            await vm.prepareProjectOpen(url: projectURL, projectType: projectType)
        } else {
            Issue.record("\(label) seed: missing project type at \(projectPath)")
            return
        }
        // Give capability Task a beat before openProject.
        try? await Task.sleep(for: .milliseconds(200))
        vm.openProject(path: projectPath, resumeSessionID: nil)

        // Cold start (first project spawn) can be slow; session resume is short.
        let unlockedSeed = await wait(timeout: ActivityTiming.sessionHandshakeColdStartTimeout) {
            !vm.isComposerLockedForSessionResume
        }
        guard unlockedSeed else {
            Issue.record("""
                \(label) seed: composer stayed locked \
                activation=\(String(describing: vm.sessionActivation)) \
                session=\(vm.sessionID ?? "nil") \
                diagnostics=\(vm.diagnostics.map(\.message)) \
                silent=\(await SilentDiagnostics.shared.snapshot().suffix(8).map(\.summary))
                """)
            return
        }
        print("LIVE_GUI \(label) seed unlocked session=\(vm.sessionID ?? "nil")")
        vm.sendPrompt(seedPrompt)
        let seedOK = await wait(timeout: .seconds(120)) {
            messageListContainsAssistant(vm.messages, needle: seedNeedle)
        }
        guard seedOK else {
            Issue.record("""
                \(label) seed: no assistant reply \
                locked=\(vm.isComposerLockedForSessionResume) \
                activation=\(String(describing: vm.sessionActivation)) \
                session=\(vm.sessionID ?? "nil") \
                messages=\(vm.messages.count) \
                diagnostics=\(vm.diagnostics.map(\.message)) \
                silent=\(await SilentDiagnostics.shared.snapshot().suffix(8).map(\.summary))
                """)
            return
        }
        guard let seedSessionID = vm.sessionID, !seedSessionID.isEmpty else {
            Issue.record("\(label) seed: missing sessionID after reply")
            return
        }
        print("LIVE_GUI \(label) seed ok session=\(seedSessionID)")

        // --- Warm resume via openSession on the same live engine ---
        vm.sessionsByProject[projectPath] = [
            SessionSummary(id: seedSessionID,
                           agentID: adapter.id,
                           workspace: projectURL,
                           title: seedPrompt,
                           lastActivity: Date(),
                           messageCount: 2)
        ]
        vm.openSession(projectPath: projectPath, id: seedSessionID)

        let historyOK = await wait(timeout: .seconds(90)) {
            messageListContainsUser(vm.messages, needle: seedPrompt)
                && messageListContainsAssistant(vm.messages, needle: seedNeedle)
        }
        print(
            "LIVE_GUI \(label) history user=\(messageListContainsUser(vm.messages, needle: seedPrompt)) assistant=\(messageListContainsAssistant(vm.messages, needle: seedNeedle)) locked=\(vm.isComposerLockedForSessionResume) msgs=\(vm.messages.count)"
        )
        #expect(historyOK, "\(label) openSession should replay history")

        let unlocked = await wait(timeout: ActivityTiming.sessionHandshakeResumeTimeout) {
            !vm.isComposerLockedForSessionResume
        }
        guard unlocked else {
            Issue.record("""
                \(label) warm resume: composer stayed locked \
                activation=\(String(describing: vm.sessionActivation)) \
                session=\(vm.sessionID ?? "nil") \
                diagnostics=\(vm.diagnostics.map(\.message))
                """)
            return
        }
        vm.sendPrompt(followUpPrompt)
        let followOK = await wait(timeout: .seconds(120)) {
            messageListContainsAssistant(vm.messages, needle: followUpNeedle)
        }
        print("LIVE_GUI \(label) follow-up ok=\(followOK) msgs=\(vm.messages.count)")
        #expect(followOK, "\(label) follow-up after warm openSession should get a reply")
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
