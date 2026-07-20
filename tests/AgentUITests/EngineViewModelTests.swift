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

    @Test("assistantText keeps streaming across interleaved tools and stable id on finalize")
    func assistantTextStreamsAcrossTools() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let msgID = UUID()
        await bus.publish(.assistantText(
            id: msgID.uuidString,
            blockID: "agent-message",
            text: "Hello",
            isFinal: false
        ))
        await bus.publish(.toolStart(
            id: "t1",
            name: "Read",
            input: ToolInput(summary: "Read"),
            startedAt: Date(timeIntervalSince1970: 0)
        ))
        await bus.publish(.assistantText(
            id: msgID.uuidString,
            blockID: "agent-message",
            text: "Hello world",
            isFinal: false
        ))
        await drain()

        #expect(vm.messages.contains {
            if case .assistantStreaming(let id, let text) = $0 {
                return id == msgID && text == "Hello world"
            }
            return false
        })
        let streamID = vm.messages.first {
            if case .assistantStreaming = $0 { return true }
            return false
        }?.id

        await bus.publish(.assistantText(
            id: msgID.uuidString,
            blockID: "agent-message",
            text: "Hello world!",
            isFinal: true
        ))
        await drain()

        #expect(vm.messages.contains {
            if case .assistant(let id, let text) = $0 {
                return id == msgID && text == "Hello world!"
            }
            return false
        })
        let finalID = vm.messages.first {
            if case .assistant = $0 { return true }
            return false
        }?.id
        #expect(streamID == finalID)
        #expect(streamID == "asst-\(msgID)")

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
        guard let turnID = vm.lastUserBubbleID else {
            Issue.record("expected lastUserBubbleID after sendPrompt")
            return
        }
        await bus.publish(.noEventGap(turnID: turnID, elapsed: .seconds(91)))
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

    @Test("resume startup gap for a foreign turn id does not stall a just-sent prompt")
    func resumeStartupGapDoesNotStallJustSentPrompt() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        vm.sendPrompt("hello")
        await bus.publish(.activityStateChanged(.probablyStuck))
        await bus.publish(.noEventGap(turnID: UUID(), elapsed: .seconds(91)))
        await drain()

        #expect(!vm.stalledToastVisible)
        if case .working(let phrase) = vm.status {
            #expect(phrase == ActivityTiming.workingPhrase)
        } else {
            #expect(Bool(false), "status should stay on the optimistic working phrase")
        }

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
        guard let turnID = vm.lastUserBubbleID else {
            Issue.record("expected lastUserBubbleID after sendPrompt")
            return
        }
        await bus.publish(.textDelta(messageID: UUID(), delta: "Working"))
        await bus.publish(.noEventGap(turnID: turnID, elapsed: .seconds(91)))
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
        guard let turnID = vm.lastUserBubbleID else {
            Issue.record("expected lastUserBubbleID after sendPrompt")
            return
        }
        await bus.publish(.noEventGap(turnID: turnID, elapsed: .seconds(11)))
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
        guard let turnID = vm.lastUserBubbleID else {
            Issue.record("expected lastUserBubbleID after sendPrompt")
            return
        }
        await bus.publish(.noEventGap(turnID: turnID, elapsed: .seconds(91)))
        await drain()
        #expect(vm.stalledToastVisible)

        // Second 91-second event — flag prevents a reset that re-fires auto-dismiss.
        await bus.publish(.noEventGap(turnID: turnID, elapsed: .seconds(95)))
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
        guard let turnID = vm.lastUserBubbleID else {
            Issue.record("expected lastUserBubbleID after sendPrompt")
            return
        }
        await bus.publish(.noEventGap(turnID: turnID, elapsed: .seconds(91)))
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
        guard let turnID = vm.lastUserBubbleID else {
            Issue.record("expected lastUserBubbleID after sendPrompt")
            return
        }
        await bus.publish(.noEventGap(turnID: turnID, elapsed: .seconds(91)))
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
        guard let turnID = vm.lastUserBubbleID else {
            Issue.record("expected lastUserBubbleID after sendPrompt")
            return
        }
        await bus.publish(.noEventGap(turnID: turnID, elapsed: .seconds(91)))
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

    @Test("activateSlashCommand routes Cursor mode slashes through selectCommands")
    func activateSlashCommandCursorMode() async {
        let port = RecordingCommandPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus)
        vm.subscribe()
        defer { vm.unsubscribe() }
        vm.availableAgentModes = [
            AgentModeOption(
                id: "ask",
                label: "Ask",
                selectCommands: [.runSlashCommand(name: "/ask", args: [])]
            ),
        ]
        vm.activateSlashCommand(
            SlashCommand(id: "/ask", name: "/ask", summary: "Q&A mode", sendsAsPrompt: false)
        )
        await drain()
        #expect(port.commands.count == 2)
        guard case .recordClientAction(let action) = port.commands[0] else {
            Issue.record("expected recordClientAction first"); return
        }
        #expect(action.kind == .mode)
        #expect(action.detail == "Ask")
        #expect(port.commands[1] == .runSlashCommand(name: "/ask", args: []))
        #expect(vm.selectedAgentModeID == "ask")
        await bus.shutdown()
    }

    @Test("activateSlashCommand sends built-in help as a prompt")
    func activateSlashCommandPromptStyle() async {
        let port = RecordingCommandPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus)
        vm.activateSlashCommand(
            SlashCommand(id: "/help", name: "/help", summary: "Show help")
        )
        await drain()
        #expect(port.commands == [.sendPrompt(text: "/help", attachments: [])])
        #expect(vm.messages.count == 1)
        if case .user(_, let text) = vm.messages[0] {
            #expect(text == "/help")
        } else {
            Issue.record("expected optimistic user bubble")
        }
        await bus.shutdown()
    }

    @Test("activateSlashCommand records a non-prompt slash as a client action")
    func activateSlashCommandNonPromptRecordsAction() async {
        let port = RecordingCommandPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus)
        vm.subscribe()
        defer { vm.unsubscribe() }
        vm.activateSlashCommand(
            SlashCommand(id: "/debug", name: "/debug", summary: "Debug", sendsAsPrompt: false)
        )
        await drain()
        #expect(port.commands.count == 2)
        guard case .recordClientAction(let action) = port.commands[0] else {
            Issue.record("expected recordClientAction"); return
        }
        #expect(action.kind == .slashCommand)
        #expect(action.detail == "/debug")
        #expect(port.commands[1] == .runSlashCommand(name: "/debug", args: []))
        await bus.publish(.clientAction(action))
        await drain()
        #expect(vm.messages.count == 1)
        if case .clientAction(let recorded) = vm.messages[0] {
            #expect(recorded.detail == "/debug")
        } else {
            Issue.record("expected clientAction message")
        }
        await bus.shutdown()
    }

    @Test("selectAgentMode records one action then sends selectCommands")
    func selectAgentModeRecordsOneAction() async {
        let port = RecordingCommandPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus)
        let mode = AgentModeOption(
            id: "think",
            label: "Think",
            selectCommands: [
                .toggleThinkMode(enabled: true),
                .toggleReviewMode(enabled: false),
            ]
        )
        vm.selectAgentMode(mode)
        await drain()
        #expect(port.commands.count == 3)
        guard case .recordClientAction(let action) = port.commands[0] else {
            Issue.record("expected recordClientAction"); return
        }
        #expect(action.kind == .mode)
        #expect(action.detail == "Think")
        #expect(port.commands[1] == .toggleThinkMode(enabled: true))
        #expect(port.commands[2] == .toggleReviewMode(enabled: false))
        #expect(vm.selectedAgentModeID == "think")
        await bus.shutdown()
    }

    @Test("respondToPermission records the decision and clears pending prompt")
    func respondToPermissionRecordsDecision() async {
        let port = RecordingCommandPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus)
        let prompt = PermissionPrompt(toolName: "Bash",
                                       summary: "Run ls",
                                       argumentsSummary: "{}",
                                       requestedAt: Date())
        vm.subscribe()
        defer { vm.unsubscribe() }
        await bus.publish(.permissionRequest(prompt: prompt))
        await drain()
        #expect(vm.pendingPermission != nil)

        vm.respondToPermission(id: prompt.id, decision: .allow)
        await drain()
        #expect(vm.pendingPermission == nil)
        #expect(port.commands.count == 2)
        guard case .recordClientAction(let action) = port.commands[0] else {
            Issue.record("expected recordClientAction"); return
        }
        #expect(action.kind == .permissionResponse)
        #expect(action.detail == "Allow")
        #expect(port.commands[1] == .respondToPermission(id: prompt.id, decision: .allow))
        await bus.shutdown()
    }

    @Test("selectModel records a model action then sends selectModel")
    func selectModelRecordsAction() async {
        let port = RecordingCommandPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus)
        vm.availableModels = [
            AgentModelOption(id: "opus", label: "Opus"),
        ]
        vm.selectModel(id: "opus", label: "Opus")
        await drain()
        #expect(port.commands.count == 2)
        guard case .recordClientAction(let action) = port.commands[0] else {
            Issue.record("expected recordClientAction"); return
        }
        #expect(action.kind == .model)
        #expect(action.detail == "Opus")
        #expect(port.commands[1] == .selectModel(id: "opus"))
        await bus.shutdown()
    }

    @Test("startNewSession records a sessionLifecycle action then sends newSession")
    func startNewSessionRecordsAction() async {
        let port = RecordingCommandPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus)
        vm.startNewSession()
        await drain()
        #expect(port.commands.count == 2)
        guard case .recordClientAction(let action) = port.commands[0] else {
            Issue.record("expected recordClientAction"); return
        }
        #expect(action.kind == .sessionLifecycle)
        #expect(action.detail == "New session")
        #expect(port.commands[1] == .newSession)
        await bus.shutdown()
    }

    @Test("compactContext records a sessionLifecycle action then sends compact")
    func compactContextRecordsAction() async {
        let port = RecordingCommandPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus)
        vm.compactContext()
        await drain()
        #expect(port.commands.count == 2)
        guard case .recordClientAction(let action) = port.commands[0] else {
            Issue.record("expected recordClientAction"); return
        }
        #expect(action.kind == .sessionLifecycle)
        #expect(action.detail == "Compact context")
        #expect(port.commands[1] == .compact)
        await bus.shutdown()
    }

    @Test("clientAction event appends a conversation marker")
    func clientActionAppendsMessage() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let action = ClientAction(id: UUID(), kind: .permissionMode, title: "Permission mode", detail: "Plan")
        await bus.publish(.clientAction(action))
        await drain()

        #expect(vm.messages.count == 1)
        if case .clientAction(let recorded) = vm.messages[0] {
            #expect(recorded == action)
        } else {
            Issue.record("expected clientAction message")
        }
        #expect(vm.messages[0].textContent == "Permission mode: Plan")

        await bus.shutdown()
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
