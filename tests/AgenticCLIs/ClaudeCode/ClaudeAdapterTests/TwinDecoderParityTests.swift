import Foundation
import Testing
@testable import ClaudeCode
import AgentCore
import AgentProtocol

/// Parity guarantee: every JSON payload the twin emits through
/// `ClaudeCodeTwinHookEmitter` must survive a `ClaudeHookDecoder` round-trip
/// and produce the correct `AgentEvent` kind.
///
/// If this suite ever fails, either:
///   1. Anthropic changed the hook schema → update the twin emitter, the
///      decoder, and the digital-twin README in lockstep.
///   2. We changed the decoder without updating the twin → fix the twin.
@Suite("Twin ↔ HookDecoder parity")
struct TwinDecoderParityTests {

    private let decoder = ClaudeHookDecoder()

    @Test("sessionStart → .sessionStarted with matching sessionID and model")
    func sessionStartParity() {
        let data = ClaudeCodeTwinHookEmitter.sessionStart(
            sessionID: "sess-1",
            project: URL(fileURLWithPath: "/tmp/test"),
            model: "claude-parity-model"
        )
        let request = HookRequest(id: UUID(), eventName: "SessionStart", jsonPayload: data)
        let events = decoder.events(from: request)

        guard case let .sessionStarted(id, model, _) = events.first else {
            Issue.record("expected .sessionStarted, got \(events)")
            return
        }
        #expect(id == "sess-1")
        #expect(model == "claude-parity-model")
    }

    @Test("userPromptSubmit → .userTurn with matching prompt text")
    func userPromptParity() {
        let data = ClaudeCodeTwinHookEmitter.userPromptSubmit(
            sessionID: "sess-2",
            prompt: "What is 2+2?"
        )
        let request = HookRequest(id: UUID(), eventName: "UserPromptSubmit", jsonPayload: data)
        let events = decoder.events(from: request)

        guard case let .userTurn(_, text) = events.first else {
            Issue.record("expected .userTurn, got \(events)")
            return
        }
        #expect(text == "What is 2+2?")
    }

    @Test("preToolUse (needsPermission=false) → .toolStart but no permissionRequest")
    func preToolUseNoPermissionParity() {
        let data = ClaudeCodeTwinHookEmitter.preToolUse(
            sessionID: "sess-3",
            toolUseID: "toolu_abc",
            toolName: "Bash",
            input: ["command": "ls"],
            needsPermission: false
        )
        let request = HookRequest(id: UUID(), eventName: "PreToolUse", jsonPayload: data)
        let events = decoder.events(from: request)

        let hasPermission = events.contains { if case .permissionRequest = $0 { return true }; return false }
        let hasStart = events.contains { if case .toolStart = $0 { return true }; return false }
        #expect(!hasPermission)
        #expect(hasStart)
    }

    @Test("preToolUse (needsPermission=true) → .permissionRequest + .toolStart")
    func preToolUseNeedsPermissionParity() {
        let data = ClaudeCodeTwinHookEmitter.preToolUse(
            sessionID: "sess-4",
            toolUseID: "toolu_xyz",
            toolName: "Bash",
            input: ["command": "rm -rf /"],
            needsPermission: true
        )
        let request = HookRequest(id: UUID(), eventName: "PreToolUse", jsonPayload: data)
        let events = decoder.events(from: request)

        let hasPermission = events.contains { if case .permissionRequest = $0 { return true }; return false }
        let hasStart = events.contains { if case .toolStart = $0 { return true }; return false }
        #expect(hasPermission)
        #expect(hasStart)
    }

    @Test("postToolUse (isError=false) → .toolEnd with success=true")
    func postToolUseSuccessParity() {
        let data = ClaudeCodeTwinHookEmitter.postToolUse(
            sessionID: "sess-5",
            toolUseID: "toolu_q",
            toolName: "Bash",
            output: "ok",
            exitCode: 0,
            isError: false,
            durationMS: 25
        )
        let request = HookRequest(id: UUID(), eventName: "PostToolUse", jsonPayload: data)
        let events = decoder.events(from: request)

        guard case let .toolEnd(_, success, _, ms) = events.first(where: { if case .toolEnd = $0 { return true }; return false }) else {
            Issue.record("expected .toolEnd, got \(events)")
            return
        }
        #expect(success == true)
        #expect(ms == 25)
    }

    @Test("postToolUse (isError=true) → .toolEnd with success=false")
    func postToolUseErrorParity() {
        let data = ClaudeCodeTwinHookEmitter.postToolUse(
            sessionID: "sess-6",
            toolUseID: "toolu_r",
            toolName: "Bash",
            output: "Permission denied",
            exitCode: 1,
            isError: true
        )
        let request = HookRequest(id: UUID(), eventName: "PostToolUse", jsonPayload: data)
        let events = decoder.events(from: request)

        guard case let .toolEnd(_, success, _, _) = events.first(where: { if case .toolEnd = $0 { return true }; return false }) else {
            Issue.record("expected .toolEnd, got \(events)")
            return
        }
        #expect(success == false)
    }

    @Test("notification → .statusPhraseChanged with hookHint source")
    func notificationParity() {
        let data = ClaudeCodeTwinHookEmitter.notification(
            sessionID: "sess-7",
            message: "Searching codebase…"
        )
        let request = HookRequest(id: UUID(), eventName: "Notification", jsonPayload: data)
        let events = decoder.events(from: request)

        guard case let .statusPhraseChanged(source, phrase) = events.first else {
            Issue.record("expected .statusPhraseChanged, got \(events)")
            return
        }
        #expect(source == .hookHint)
        #expect(phrase == "Searching codebase…")
    }

    @Test("stop without last message -> idle only")
    func stopParity() {
        let data = ClaudeCodeTwinHookEmitter.stop(sessionID: "sess-8")
        let request = HookRequest(id: UUID(), eventName: "Stop", jsonPayload: data)
        let events = decoder.events(from: request)

        #expect(events.count == 1)
        guard case .activityStateChanged(.idle) = events.first else {
            Issue.record("expected .activityStateChanged(.idle), got \(events)")
            return
        }
    }

    @Test("stop with last_assistant_message -> assistantText + idle")
    func stopWithLastMessageParity() {
        let data = ClaudeCodeTwinHookEmitter.stop(sessionID: "sess-9",
                                                  lastAssistantMessage: "Final.")
        let request = HookRequest(id: UUID(), eventName: "Stop", jsonPayload: data)
        let events = decoder.events(from: request)

        #expect(events.contains { if case .assistantText(_, _, let t, _) = $0 { return t == "Final." }; return false })
        #expect(events.contains { if case .activityStateChanged(.idle) = $0 { return true }; return false })
    }
}
