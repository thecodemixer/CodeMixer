import Foundation
import os
import Testing
@testable import AgentUI
@testable import AgentCore
@testable import AgentTestSupport
import AgentProtocol

@Suite("EngineViewModel — event reduction")
@MainActor
struct EngineViewModelTests {

    @Test("User turn followed by assistant text appends two messages")
    func reducerAppendsMessages() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.userTurn(id: UUID().uuidString, text: "hi"))
        await bus.publish(.assistantText(id: UUID().uuidString, blockID: UUID().uuidString,
                                         text: "Hello.", isFinal: true))
        await drain()

        #expect(vm.messages.count == 2)
        if case .user(_, let text) = vm.messages[0] { #expect(text == "hi") }
        if case .assistant(_, let text) = vm.messages[1] { #expect(text == "Hello.") }

        await bus.shutdown()
    }

    @Test("Activity state transitions to .idle resets the status line")
    func activityResetsStatus() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.statusPhraseChanged(source: .heuristic, phrase: "Thinking…"))
        await bus.publish(.activityStateChanged(.idle))
        await drain()

        #expect(vm.activity == .idle)
        if case .idle = vm.status { } else { #expect(Bool(false), "expected idle status") }

        await bus.shutdown()
    }

    @Test("sessionStarted resets messages, workspace and token rate")
    func sessionStartedResets() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.userTurn(id: UUID().uuidString, text: "old"))
        await drain()
        #expect(vm.messages.count == 1)

        let cwd = URL(fileURLWithPath: "/tmp/proj")
        await bus.publish(.sessionStarted(sessionID: "sess-1", model: nil, cwd: cwd))
        await drain()

        #expect(vm.messages.isEmpty)
        #expect(vm.workspace == cwd)
        #expect(vm.tokenRatePerSecond == nil)
        #expect(!vm.stalledToastVisible)

        await bus.shutdown()
    }

    @Test("streaming textDelta messages accumulate into assistantStreaming bubble")
    func textDeltaAccumulates() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.textDelta(messageID: UUID(), delta: "Hello"))
        await bus.publish(.textDelta(messageID: UUID(), delta: ", world"))
        await drain()

        #expect(vm.messages.count == 1)
        if case .assistantStreaming(_, let text) = vm.messages[0] {
            #expect(text == "Hello, world")
        } else {
            #expect(Bool(false), "expected assistantStreaming")
        }

        await bus.shutdown()
    }

    @Test("thinkingChunk accumulates into a single message by blockID")
    func thinkingChunkAccumulates() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let id = UUID()
        await bus.publish(.thinkingChunk(blockID: id, delta: "Let me think…"))
        await bus.publish(.thinkingChunk(blockID: id, delta: " OK."))
        await drain()

        #expect(vm.messages.count == 1)
        if case .thinkingChunk(_, let text) = vm.messages[0] {
            #expect(text == "Let me think… OK.")
        } else {
            #expect(Bool(false), "expected thinkingChunk")
        }

        await bus.shutdown()
    }

    @Test("thinkingComplete replaces thinkingChunk with final duration bubble")
    func thinkingComplete() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let id = UUID()
        await bus.publish(.thinkingChunk(blockID: id, delta: "Pondering…"))
        await bus.publish(.thinkingComplete(blockID: id, duration: .seconds(3)))
        await drain()

        #expect(vm.messages.count == 1)
        if case .thinkingComplete(_, let text, let dur) = vm.messages[0] {
            #expect(text == "Pondering…")
            #expect(dur == .seconds(3))
        } else {
            #expect(Bool(false), "expected thinkingComplete")
        }

        await bus.shutdown()
    }

    @Test("noEventGap > 90 s shows stalled toast")
    func stalledToastAppearsOver90s() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("hello")
        await bus.publish(.noEventGap(turnID: UUID(), elapsed: .seconds(91)))
        await drain()

        #expect(vm.stalledToastVisible)

        await bus.shutdown()
    }

    @Test("resume startup gap without a sent prompt does not show stalled toast")
    func resumeStartupGapDoesNotShowStalledToast() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.activityStateChanged(.probablyStuck))
        await bus.publish(.noEventGap(turnID: UUID(), elapsed: .seconds(91)))
        await drain()

        #expect(!vm.stalledToastVisible)

        await bus.shutdown()
    }

    @Test("resume startup gap without a sent prompt does not show still-working status")
    func resumeStartupGapDoesNotShowStillWorkingStatus() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.activityStateChanged(.probablyStuck))
        await bus.publish(.noEventGap(turnID: UUID(), elapsed: .seconds(11)))
        await drain()

        if case .idle = vm.status {} else {
            #expect(Bool(false), "status should stay idle before the user sends a prompt")
        }

        await bus.shutdown()
    }

    @Test("first agent reply prevents later no-event gap from showing stalled toast")
    func firstReplySuppressesLaterStalledToast() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("hello")
        await bus.publish(.textDelta(messageID: UUID(), delta: "Working"))
        await bus.publish(.noEventGap(turnID: UUID(), elapsed: .seconds(91)))
        await drain()

        #expect(!vm.stalledToastVisible)

        await bus.shutdown()
    }

    @Test("noEventGap ≤ 10 s updates status phrase but does not show toast")
    func shortGapUpdatesStatusOnly() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("hello")
        await bus.publish(.noEventGap(turnID: UUID(), elapsed: .seconds(11)))
        await drain()

        if case .working(let phrase) = vm.status {
            #expect(phrase == "Still working…")
        } else {
            #expect(Bool(false), "expected working status")
        }
        #expect(!vm.stalledToastVisible)

        await bus.shutdown()
    }

    @Test("Stalled toast is single-fire per turn")
    func stalledToastSingleFire() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("hello")
        await bus.publish(.noEventGap(turnID: UUID(), elapsed: .seconds(91)))
        await drain()
        #expect(vm.stalledToastVisible)

        // Second 91-second event — flag prevents a reset that re-fires auto-dismiss.
        await bus.publish(.noEventGap(turnID: UUID(), elapsed: .seconds(95)))
        await drain()
        #expect(vm.stalledToastVisible)

        await bus.shutdown()
    }

    @Test("stopped event clears stalled toast and resets activity")
    func stoppedClearsToast() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("hello")
        await bus.publish(.noEventGap(turnID: UUID(), elapsed: .seconds(91)))
        await drain()
        #expect(vm.stalledToastVisible)

        await bus.publish(.stopped(reason: .naturalExit))
        await drain()

        #expect(!vm.stalledToastVisible)
        #expect(vm.activity == .idle)

        await bus.shutdown()
    }

    @Test("cancelCurrentTurn hides stalled toast immediately and forwards cancel")
    func cancelCurrentTurnClearsStalledToast() async {
        let port = RecordingCommandPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus)
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("hello")
        await bus.publish(.noEventGap(turnID: UUID(), elapsed: .seconds(91)))
        await drain()
        #expect(vm.stalledToastVisible)

        vm.cancelCurrentTurn()
        await drain()

        #expect(!vm.stalledToastVisible)
        #expect(vm.activity == .idle)
        if case .idle = vm.status {} else { #expect(Bool(false), "status should be idle") }
        #expect(port.commands.contains {
            if case .cancelCurrentTurn = $0 { return true }
            return false
        })

        await bus.shutdown()
    }

    @Test("idle activity clears stalled toast after recovery")
    func idleActivityClearsStalledToast() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("hello")
        await bus.publish(.noEventGap(turnID: UUID(), elapsed: .seconds(91)))
        await drain()
        #expect(vm.stalledToastVisible)

        await bus.publish(.activityStateChanged(.idle))
        await drain()

        #expect(!vm.stalledToastVisible)
        #expect(vm.activity == .idle)

        await bus.shutdown()
    }

    @Test("final assistant text settles the turn idle")
    func finalAssistantTextSettlesIdle() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("hello")
        #expect(vm.activity == .awaitingFirstChunk)

        await bus.publish(.assistantText(id: UUID().uuidString,
                                         blockID: UUID().uuidString,
                                         text: "hi",
                                         isFinal: true))
        await drain()

        #expect(vm.activity == .idle)
        if case .idle = vm.status {} else { #expect(Bool(false), "status should be idle") }
        #expect(!vm.canCancel)

        await bus.shutdown()
    }

    @Test("stale noEventGap does not revive still-working state after idle")
    func staleNoEventGapIgnoredAfterIdle() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("hello")
        await bus.publish(.activityStateChanged(.idle))
        await bus.publish(.noEventGap(turnID: UUID(), elapsed: .seconds(91)))
        await drain()

        #expect(vm.activity == .idle)
        if case .idle = vm.status {} else { #expect(Bool(false), "status should remain idle") }
        #expect(!vm.stalledToastVisible)

        await bus.shutdown()
    }

    @Test("toolStart adds an entry to activeToolCalls")
    func toolStartAddsEntry() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.toolStart(id: "call-1", name: "Bash",
                                     input: ToolInput(summary: "echo hi"),
                                     startedAt: Date()))
        await drain()

        #expect(vm.activeToolCalls.count == 1)
        #expect(vm.activeToolCalls[0].name == "Bash")
        #expect(!vm.activeToolCalls[0].finished)

        await bus.shutdown()
    }

    @Test(".toolProgress with .generic appends to subagentLines of the matching entry")
    func subagentLinesAccumulate() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let callID = UUID()
        await bus.publish(.toolStart(id: callID.uuidString, name: "Task",
                                     input: ToolInput(summary: "Subagent"),
                                     startedAt: Date()))
        await bus.publish(.toolProgress(callID: callID, progress: .generic(message: "Step 1")))
        await bus.publish(.toolProgress(callID: callID, progress: .generic(message: "Step 2")))
        await drain()

        let entry = vm.activeToolCalls.first(where: { $0.id == callID.uuidString })
        #expect(entry?.subagentLines == ["Step 1", "Step 2"])

        await bus.shutdown()
    }

    @Test("fileTouched appends a relative path to changedFiles")
    func fileTouchedRelative() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let cwd = URL(fileURLWithPath: "/tmp/myproject")
        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: cwd))
        await bus.publish(.fileTouched(cwd.appendingPathComponent("src/main.swift"),
                                       kind: .fsObserved))
        await drain()

        #expect(vm.changedFiles == ["src/main.swift"])

        await bus.shutdown()
    }

    @Test("fileReverted removes the path from changedFiles")
    func fileReverted() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let cwd = URL(fileURLWithPath: "/tmp/myproject")
        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: cwd))
        await bus.publish(.fileTouched(cwd.appendingPathComponent("src/main.swift"),
                                       kind: .fsObserved))
        await drain()
        #expect(vm.changedFiles == ["src/main.swift"])

        await bus.publish(.fileReverted(path: "src/main.swift"))
        await drain()
        #expect(vm.changedFiles.isEmpty)

        await bus.shutdown()
    }

    @Test("lastUserBubbleID tracks the latest user turn UUID")
    func lastUserBubbleIDTracked() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let id1 = UUID()
        await bus.publish(.userTurn(id: id1.uuidString, text: "first"))
        await drain()
        #expect(vm.lastUserBubbleID == id1)

        let id2 = UUID()
        await bus.publish(.userTurn(id: id2.uuidString, text: "second"))
        await drain()
        #expect(vm.lastUserBubbleID == id2)

        await bus.shutdown()
    }

    @Test("slashCommands is publicly settable and readable")
    func slashCommandsSettable() {
        let (vm, _) = makeModel()
        #expect(vm.slashCommands.isEmpty)

        let cmds = [SlashCommand(id: "c1", name: "/test", summary: "Test command")]
        vm.slashCommands = cmds
        #expect(vm.slashCommands.count == 1)
        #expect(vm.slashCommands[0].name == "/test")
    }

    // MARK: - toolEnd

    @Test("toolEnd marks the matching activeToolCall as finished with success + output")
    func toolEndUpdatesEntry() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.toolStart(id: "call-1", name: "Write",
                                     input: ToolInput(summary: "write foo.swift"),
                                     startedAt: Date()))
        await bus.publish(.toolEnd(id: "call-1", success: true,
                                   output: ToolOutput(summary: "written", jsonPayload: nil),
                                   durationMS: 42))
        await drain()

        let entry = vm.activeToolCalls.first(where: { $0.id == "call-1" })
        #expect(entry?.finished == true)
        #expect(entry?.success == true)
        #expect(entry?.output?.summary == "written")

        await bus.shutdown()
    }

    @Test("toolEnd with success=false sets entry.success to false")
    func toolEndFailure() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.toolStart(id: "call-2", name: "Bash",
                                     input: ToolInput(summary: "rm -rf /"),
                                     startedAt: Date()))
        await bus.publish(.toolEnd(id: "call-2", success: false,
                                   output: ToolOutput(summary: "error", errorMessage: "permission denied"),
                                   durationMS: 5))
        await drain()

        let entry = vm.activeToolCalls.first(where: { $0.id == "call-2" })
        #expect(entry?.finished == true)
        #expect(entry?.success == false)
        #expect(entry?.output?.errorMessage == "permission denied")

        await bus.shutdown()
    }

    // MARK: - Permissions

    @Test("permissionRequest sets pendingPermission and moves activity to .waitingPermission")
    func permissionRequestSetsState() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let prompt = PermissionPrompt(toolName: "Bash",
                                       summary: "Run ls",
                                       argumentsSummary: "{}",
                                       requestedAt: Date())
        await bus.publish(.permissionRequest(prompt: prompt))
        await drain()

        #expect(vm.pendingPermission?.id == prompt.id)
        #expect(vm.activity == .waitingPermission)

        await bus.shutdown()
    }

    @Test("permissionAlreadyResolved clears pendingPermission")
    func permissionAlreadyResolvedClearsPrompt() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let prompt = PermissionPrompt(toolName: "Bash",
                                       summary: "Run ls",
                                       argumentsSummary: "{}",
                                       requestedAt: Date())
        await bus.publish(.permissionRequest(prompt: prompt))
        await drain()
        #expect(vm.pendingPermission != nil)

        await bus.publish(.permissionAlreadyResolved(id: prompt.id, byDevice: "timeout"))
        await drain()

        #expect(vm.pendingPermission == nil)

        await bus.shutdown()
    }

    @Test("canCancel is false when activity is idle or waitingPermission, true otherwise")
    func canCancelTransitions() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        // idle by default
        #expect(!vm.canCancel)

        await bus.publish(.activityStateChanged(.awaitingFirstChunk))
        await drain()
        #expect(vm.canCancel)

        await bus.publish(.activityStateChanged(.streamingText))
        await drain()
        #expect(vm.canCancel)

        await bus.publish(.activityStateChanged(.runningTool))
        await drain()
        #expect(vm.canCancel)

        await bus.publish(.activityStateChanged(.waitingPermission))
        await drain()
        #expect(!vm.canCancel)

        await bus.publish(.activityStateChanged(.idle))
        await drain()
        #expect(!vm.canCancel)

        await bus.shutdown()
    }

    // MARK: - Errors

    @Test("error event appends a .error DiagnosticEntry")
    func errorAppendsdiagnostic() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.error(.unsupportedOperation(detail: "hunk revert not supported")))
        await drain()

        #expect(vm.diagnostics.count == 1)
        #expect(vm.diagnostics[0].level == .error)
        #expect(vm.diagnostics[0].message.contains("hunk revert"))

        await bus.shutdown()
    }

    @Test("Multiple errors accumulate in diagnostics without replacing previous")
    func errorsAccumulate() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.error(.unsupportedOperation(detail: "err-1")))
        await bus.publish(.error(.unsupportedOperation(detail: "err-2")))
        await drain()

        #expect(vm.diagnostics.count == 2)

        await bus.shutdown()
    }

    // MARK: - Usage

    @Test("usage event does not crash and produces no visible state change")
    func usageIsNoOp() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.usage(tokens: 1234, costUSD: 0.002))
        await drain()

        // usage is intentionally a no-op in the VM; only verify we don't crash.
        #expect(vm.messages.isEmpty)
        #expect(vm.diagnostics.isEmpty)

        await bus.shutdown()
    }

    // MARK: - Snapshots

    @Test("snapshotReady sets pendingExport with matching kind and payload")
    func snapshotReadySetsPendingExport() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let payload = Data("{}".utf8)
        await bus.publish(.snapshotReady(kind: .prefs, payload: payload))
        await drain()

        #expect(vm.pendingExport?.kind == .prefs)
        #expect(vm.pendingExport?.payload == payload)

        vm.clearPendingExport()
        #expect(vm.pendingExport == nil)

        await bus.shutdown()
    }

    @Test("snapshotReady replaces a prior pendingExport")
    func snapshotReadyReplaces() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.snapshotReady(kind: .prefs, payload: Data()))
        await drain()
        await bus.publish(.snapshotReady(kind: .diff, payload: Data("diff".utf8)))
        await drain()

        #expect(vm.pendingExport?.kind == .diff)

        await bus.shutdown()
    }

    // MARK: - send() forwarding

    @Test("send() with a command that throws AgentError appends to diagnostics")
    func sendForwardsAgentError() async {
        let stub = ThrowingCommandPort(error: AgentError.unsupportedOperation(detail: "no adapter"))
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: stub, bus: bus)
        vm.subscribe()
        defer { vm.unsubscribe(); vm.send(.cancelCurrentTurn) }

        vm.send(.cancelCurrentTurn)
        // Allow the fire-and-forget task inside send() to settle.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(vm.diagnostics.contains { $0.level == .error && $0.message.contains("no adapter") })

        await bus.shutdown()
    }

    @Test("send() with a non-AgentError falls back to localizedDescription in diagnostics")
    func sendForwardsGenericError() async {
        struct DummyError: Error, LocalizedError {
            var errorDescription: String? { "dummy error" }
        }
        let stub = ThrowingCommandPort(error: DummyError())
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: stub, bus: bus)
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.send(.cancelCurrentTurn)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(vm.diagnostics.contains { $0.level == .error && $0.message.contains("dummy error") })

        await bus.shutdown()
    }

    @Test("send() with a non-throwing command produces no diagnostic")
    func sendNoThrowProducesNoDiagnostic() async {
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: StubCommandPort(), bus: bus)
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.send(.cancelCurrentTurn)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(vm.diagnostics.isEmpty)

        await bus.shutdown()
    }
}

// MARK: - Helpers

@MainActor
private func makeModel() -> (EngineViewModel, MulticastEventBus) {
    let bus = MulticastEventBus()
    let vm = EngineViewModel(engine: StubCommandPort(), bus: bus)
    return (vm, bus)
}

/// Allow the event bus to deliver events to the subscriber task.
@MainActor
private func drain() async {
    try? await Task.sleep(for: .milliseconds(40))
}

private final class StubCommandPort: AgentEngineCommandPort, @unchecked Sendable {
    func send(_ command: AgentCommand) async throws {}
}

private final class RecordingCommandPort: AgentEngineCommandPort, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<[AgentCommand]>(initialState: [])
    var commands: [AgentCommand] { state.withLock { $0 } }

    func send(_ command: AgentCommand) async throws {
        state.withLock { $0.append(command) }
    }
}

private final class ThrowingCommandPort: AgentEngineCommandPort, @unchecked Sendable {
    private let error: any Error
    init(error: any Error) { self.error = error }
    func send(_ command: AgentCommand) async throws { throw error }
}
