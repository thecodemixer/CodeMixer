import Foundation
import Testing
@testable import ClaudeCode
import AgentCore
import AgentProtocol

@Suite("ClaudeHookDecoder — per-event decoding")
struct ClaudeHookDecoderTests {

    private let decoder = ClaudeHookDecoder()

    // MARK: - SessionStart

    @Test("SessionStart yields sessionStarted with id, model and cwd")
    func sessionStart() {
        let json = #"{"session_id":"sid-42","cwd":"/var/project","model":"claude-sonnet-4-5"}"#
        let request = HookRequest(id: UUID(), eventName: "SessionStart", jsonPayload: data(json))
        let events = decoder.events(from: request)
        guard case .sessionStarted(let id, let model, let cwd)? = events.first else {
            Issue.record("no sessionStarted"); return
        }
        #expect(id == "sid-42")
        #expect(model == "claude-sonnet-4-5")
        #expect(cwd.path == "/var/project")
    }

    @Test("SessionStart without session_id yields no events")
    func sessionStartMissingID() {
        let json = #"{"cwd":"/tmp"}"#
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "SessionStart",
                                                       jsonPayload: data(json)))
        #expect(events.isEmpty)
    }

    // MARK: - UserPromptSubmit

    @Test("UserPromptSubmit yields userTurn with prompt text")
    func userPromptSubmit() {
        let json = #"{"prompt":"Hello world","session_id":"s1"}"#
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "UserPromptSubmit",
                                                       jsonPayload: data(json)))
        guard case .userTurn(_, let text)? = events.first else {
            Issue.record("no userTurn"); return
        }
        #expect(text == "Hello world")
    }

    // MARK: - PreToolUse

    @Test("PreToolUse without needs_permission yields only toolStart")
    func preToolUseNoPermission() {
        let id = UUID()
        let json = #"{"tool_name":"Bash","tool_input":{"command":"ls -la"}}"#
        let events = decoder.events(from: HookRequest(id: id,
                                                       eventName: "PreToolUse",
                                                       jsonPayload: data(json)))
        let hasPermission = events.contains {
            if case .permissionRequest = $0 { return true }; return false
        }
        let hasStart = events.contains {
            if case .toolStart(_, let name, _, _) = $0 { return name == "Bash" }; return false
        }
        // needs_permission absent → no permission prompt, just toolStart
        #expect(!hasPermission)
        #expect(hasStart)
    }

    @Test("PreToolUse with needs_permission=true yields permissionRequest and toolStart")
    func preToolUseWithPermission() {
        let id = UUID()
        let json = #"{"tool_name":"Bash","tool_input":{"command":"rm -rf"},"needs_permission":true}"#
        let events = decoder.events(from: HookRequest(id: id,
                                                       eventName: "PreToolUse",
                                                       jsonPayload: data(json)))
        let hasPermission = events.contains {
            if case .permissionRequest(let p) = $0 { return p.toolName == "Bash" }; return false
        }
        let hasStart = events.contains {
            if case .toolStart(_, let name, _, _) = $0 { return name == "Bash" }; return false
        }
        #expect(hasPermission)
        #expect(hasStart)
    }

    @Test("PreToolUse for Bash surfaces human summary containing the command")
    func preToolUseBashSummary() {
        let json = #"{"tool_name":"Bash","tool_input":{"command":"git status"}}"#
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "PreToolUse",
                                                       jsonPayload: data(json)))
        let start = events.compactMap { e -> ToolInput? in
            if case .toolStart(_, _, let input, _) = e { return input }; return nil
        }.first
        #expect(start?.summary.contains("git status") == true)
    }

    @Test("PreToolUse for Edit surfaces file_path in summary")
    func preToolUseEditSummary() {
        let json = #"{"tool_name":"Edit","tool_input":{"file_path":"/src/main.swift"}}"#
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "PreToolUse",
                                                       jsonPayload: data(json)))
        let start = events.compactMap { e -> ToolInput? in
            if case .toolStart(_, _, let input, _) = e { return input }; return nil
        }.first
        #expect(start?.summary.contains("/src/main.swift") == true)
    }

    @Test("PreToolUse for Read surfaces file_path in summary")
    func preToolUseReadSummary() {
        let json = #"{"tool_name":"Read","tool_input":{"file_path":"/README.md"}}"#
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "PreToolUse",
                                                       jsonPayload: data(json)))
        let start = events.compactMap { e -> ToolInput? in
            if case .toolStart(_, _, let input, _) = e { return input }; return nil
        }.first
        #expect(start?.summary.contains("README.md") == true)
    }

    @Test("PreToolUse for Grep surfaces pattern in summary")
    func preToolUseGrepSummary() {
        let json = #"{"tool_name":"Grep","tool_input":{"pattern":"TODO"}}"#
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "PreToolUse",
                                                       jsonPayload: data(json)))
        let start = events.compactMap { e -> ToolInput? in
            if case .toolStart(_, _, let input, _) = e { return input }; return nil
        }.first
        #expect(start?.summary.contains("TODO") == true)
    }

    @Test("PreToolUse for unknown tool falls back to 'Use <ToolName>'")
    func preToolUseUnknownTool() {
        let json = #"{"tool_name":"SuperTool","tool_input":{}}"#
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "PreToolUse",
                                                       jsonPayload: data(json)))
        let start = events.compactMap { e -> ToolInput? in
            if case .toolStart(_, _, let input, _) = e { return input }; return nil
        }.first
        #expect(start?.summary == "Use SuperTool")
    }

    // MARK: - PostToolUse

    @Test("PostToolUse yields toolEnd with success=true when is_error is absent")
    func postToolUseSuccess() {
        let json = #"{"tool_name":"Bash","tool_input":{},"tool_response":{},"duration_ms":123}"#
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "PostToolUse",
                                                       jsonPayload: data(json)))
        guard case .toolEnd(_, let success, _, let ms)? = events.first(where: {
            if case .toolEnd = $0 { return true }; return false
        }) else { Issue.record("no toolEnd"); return }
        #expect(success)
        #expect(ms == 123)
    }

    @Test("PostToolUse yields toolEnd with success=false when is_error=true")
    func postToolUseFailure() {
        let json = #"{"tool_name":"Bash","tool_input":{},"tool_response":{"error":"segfault"},"is_error":true,"duration_ms":5}"#
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "PostToolUse",
                                                       jsonPayload: data(json)))
        guard case .toolEnd(_, let success, let output, _)? = events.first(where: {
            if case .toolEnd = $0 { return true }; return false
        }) else { Issue.record("no toolEnd"); return }
        #expect(!success)
        #expect(output.errorMessage?.contains("segfault") == true)
    }

    @Test("PostToolUse for Edit/Write also yields fileTouched")
    func postToolUseFileTouched() {
        let json = #"{"tool_name":"Edit","tool_input":{"file_path":"/src/foo.swift"},"tool_response":{},"duration_ms":10}"#
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "PostToolUse",
                                                       jsonPayload: data(json)))
        let hasTouched = events.contains {
            if case .fileTouched(let url, let kind) = $0 {
                return url.path == "/src/foo.swift" && kind == .hookReported
            }
            return false
        }
        #expect(hasTouched)
    }

    @Test("PostToolUse for Write also yields fileTouched")
    func postToolUseWriteFileTouched() {
        let json = #"{"tool_name":"Write","tool_input":{"file_path":"/tmp/out.txt"},"tool_response":{},"duration_ms":2}"#
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "PostToolUse",
                                                       jsonPayload: data(json)))
        #expect(events.contains { if case .fileTouched(_, .hookReported) = $0 { return true }; return false })
    }

    // MARK: - Notification

    @Test("Notification yields statusPhraseChanged with hookHint source")
    func notification() {
        let json = #"{"message":"Reading files…"}"#
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "Notification",
                                                       jsonPayload: data(json)))
        guard case .statusPhraseChanged(let src, let phrase)? = events.first else {
            Issue.record("no statusPhraseChanged"); return
        }
        #expect(src == .hookHint)
        #expect(phrase == "Reading files…")
    }

    // MARK: - Stop

    @Test("Stop yields idle activity, not process stop")
    func stop() {
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "Stop",
                                                       jsonPayload: data("{}")))
        guard case .activityStateChanged(.idle)? = events.first else {
            Issue.record("no idle activity"); return
        }
    }

    @Test("SubagentStop also yields idle activity")
    func subagentStop() {
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "SubagentStop",
                                                       jsonPayload: data("{}")))
        #expect(events.contains { if case .activityStateChanged(.idle) = $0 { return true }; return false })
    }

    @Test("Unknown event name yields no events")
    func unknownEvent() {
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "FutureThing",
                                                       jsonPayload: data("{}")))
        #expect(events.isEmpty)
    }

    @Test("Malformed JSON yields no events")
    func malformedJSON() {
        let events = decoder.events(from: HookRequest(id: UUID(),
                                                       eventName: "SessionStart",
                                                       jsonPayload: Data("not json".utf8)))
        #expect(events.isEmpty)
    }

    private func data(_ json: String) -> Data { Data(json.utf8) }
}

// MARK: - ClaudeHookDecoder.humanSummary internal helper

@Suite("ClaudeHookDecoder — humanSummary helper")
struct HumanSummaryTests {
    private let decoder = ClaudeHookDecoder()

    @Test("Bash with command produces Run: prefix")
    func bashWithCommand() {
        let summary = decoder.humanSummary(tool: "Bash", args: ["command": .string("ls -la")])
        #expect(summary.hasPrefix("Run:"))
        #expect(summary.contains("ls -la"))
    }

    @Test("Bash without command produces fallback")
    func bashNoCommand() {
        let summary = decoder.humanSummary(tool: "Bash", args: nil)
        #expect(summary == "Run a shell command")
    }

    @Test("Edit with file_path produces Modify prefix")
    func editWithPath() {
        let summary = decoder.humanSummary(tool: "Edit", args: ["file_path": .string("/tmp/x.swift")])
        #expect(summary.hasPrefix("Modify"))
        #expect(summary.contains("/tmp/x.swift"))
    }

    @Test("Read with file_path produces Read prefix")
    func readWithPath() {
        let summary = decoder.humanSummary(tool: "Read", args: ["file_path": .string("/etc/hosts")])
        #expect(summary.hasPrefix("Read"))
        #expect(summary.contains("/etc/hosts"))
    }

    @Test("Unknown tool produces generic summary")
    func unknownTool() {
        let summary = decoder.humanSummary(tool: "MagicTool", args: nil)
        #expect(summary.lowercased().contains("magiccurl") || !summary.isEmpty)
    }
}
