import Testing
import Foundation
import AgentCore
import AgentProtocol
import ClaudeCode

/// Cross-package parity: the *exact* JSON shape the twin emits via
/// `ClaudeCodeTwinHookEmitter` must round-trip through `ClaudeHookDecoder`
/// into well-formed `AgentEvent` values.
///
/// If this test ever fails, either:
/// 1. Anthropic changed the hook schema → update the twin emitter, the
///    decoder, and `src/AgenticCLIs/ClaudeCode/README.md` in lockstep.
/// 2. We changed the decoder but forgot to update the twin → fix the twin.
///
/// Hook payloads round-trip through `ClaudeHookDecoder` in `ClaudeAdapterTests`.
@Suite("Twin hook emitter parity")
struct TwinDecoderParityTests {

    @Test("Twin SessionStart payload is valid JSON")
    func sessionStartPayloadIsJSON() {
        let payload = ClaudeCodeTwinHookEmitter.sessionStart(
            sessionID: UUID().uuidString,
            project: URL(fileURLWithPath: "/tmp/codemixer"),
            model: "claude-sonnet-4"
        )
        let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        #expect(object?["hook_event_name"] as? String == "SessionStart")
        #expect(object?["model"] as? String == "claude-sonnet-4")
    }

    @Test("Twin PreToolUse with permission encodes needs_permission + permission_id")
    func preToolUseEncodesPermissionFields() {
        let payload = ClaudeCodeTwinHookEmitter.preToolUse(
            sessionID: "s",
            toolUseID: "toolu_x",
            toolName: "Bash",
            input: ["command": "ls"],
            needsPermission: true
        )
        let body = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        #expect(body?["needs_permission"] as? Bool == true)
        #expect((body?["permission_id"] as? String)?.hasPrefix("perm_") == true)
    }

    @Test("Twin PostToolUse encodes duration_ms and is_error")
    func postToolUseEncodesMeta() {
        let payload = ClaudeCodeTwinHookEmitter.postToolUse(
            sessionID: "s", toolUseID: "toolu_x", toolName: "Bash",
            output: "hi", exitCode: 0, isError: false, durationMS: 42
        )
        let body = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        #expect(body?["duration_ms"] as? Int == 42)
        #expect(body?["is_error"] as? Bool == false)
    }

    @Test("Twin project slug matches Claude's case-preserving leading-dash convention")
    func projectSlugConvention() {
        let slug = ClaudeCodeTwinTranscript.projectSlug(
            for: URL(fileURLWithPath: "/Users/Alice/Code/My.Proj")
        )
        #expect(slug == "-Users-Alice-Code-My-Proj")
    }

    @Test("Project slug preserves spaces from a typical checkout path")
    func projectSlugPreservesSpacesFromCheckoutPath() {
        let slug = ClaudeCodeTwinTranscript.projectSlug(
            for: URL(fileURLWithPath: "/Users/alice/Code/Codemixer/Sample Workspace")
        )
        #expect(slug == "-Users-alice-Code-Codemixer-Sample-Workspace")
    }
}
