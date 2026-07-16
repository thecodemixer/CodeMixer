import Foundation

/// Materialise transcript JSONL exactly as Claude Code would write it to
/// `~/.claude/projects/<slug>/<session-id>.jsonl`. Used by tests that
/// exercise `ClaudeTranscriptTailer` without depending on `claude` having
/// ever run.
public enum ClaudeCodeTwinTranscript {

    /// Compute the slug Claude uses for a workspace path.
    public static func projectSlug(for workspace: URL) -> String {
        ClaudeProjectPaths.projectSlug(for: workspace)
    }

    public struct TranscriptLine: @unchecked Sendable {
        public let type: String
        public let uuid: String
        public let timestamp: Date
        public let body: [String: Any]

        public init(type: String,
                    uuid: String? = nil,
                    timestamp: Date? = nil,
                    body: [String: Any],
                    runtime: TwinRuntimeSeams = .live) {
            self.type = type
            self.uuid = uuid ?? runtime.uuidString()
            self.timestamp = timestamp ?? runtime.now()
            self.body = body
        }

        public func encoded() -> Data {
            var payload: [String: Any] = [
                "type": type,
                "uuid": uuid,
                "timestamp": ISO8601DateFormatter().string(from: timestamp),
            ]
            for (k, v) in body { payload[k] = v }
            let line = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
            return line + Data("\n".utf8)
        }
    }

    public static func userLine(text: String, runtime: TwinRuntimeSeams = .live) -> TranscriptLine {
        TranscriptLine(type: "user", body: [
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]],
            ],
        ], runtime: runtime)
    }

    public static func assistantTextLine(text: String,
                                         runtime: TwinRuntimeSeams = .live) -> TranscriptLine {
        TranscriptLine(type: "assistant", body: [
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ], runtime: runtime)
    }

    public static func assistantToolUseLine(toolID: String,
                                            tool: String,
                                            input: [String: Any],
                                            runtime: TwinRuntimeSeams = .live) -> TranscriptLine {
        TranscriptLine(type: "assistant", body: [
            "message": [
                "role": "assistant",
                "content": [[
                    "type": "tool_use",
                    "id": toolID,
                    "name": tool,
                    "input": input,
                ]],
            ],
        ], runtime: runtime)
    }

    public static func toolResultLine(toolID: String,
                                      text: String,
                                      isError: Bool = false,
                                      runtime: TwinRuntimeSeams = .live) -> TranscriptLine {
        TranscriptLine(type: "tool_result", body: [
            "tool_use_id": toolID,
            "content": [["type": "text", "text": text]],
            "is_error": isError,
        ], runtime: runtime)
    }

    /// Synthesise a subagent assistant turn.
    ///
    /// When Claude Code spawns a subagent (e.g. via a "Task" tool call), the
    /// subagent's conversational turns appear in the same JSONL session file
    /// with a `parentMessageId` field pointing to the spawning tool-use ID.
    ///
    /// Codemixer uses `parentMessageId` to group these turns under the parent
    /// tool-call card rather than rendering them as top-level assistant messages.
    ///
    /// Schema (as observed from Claude Code ≥ 1.x):
    /// ```json
    /// {
    ///   "type": "assistant",
    ///   "uuid": "<record-uuid>",
    ///   "sessionId": "<session-id>",
    ///   "parentMessageId": "<parent-tool-use-id>",
    ///   "subagentType": "TaskAgent",
    ///   "message": { "role": "assistant", "content": [...] }
    /// }
    /// ```
    public static func assistantThinkingLine(text: String,
                                             runtime: TwinRuntimeSeams = .live) -> TranscriptLine {
        TranscriptLine(type: "assistant", body: [
            "message": [
                "role": "assistant",
                "content": [["type": "thinking", "thinking": text]],
            ],
        ], runtime: runtime)
    }

    public static func assistantUsageLine(inputTokens: Int,
                                          outputTokens: Int,
                                          costUSD: Double?,
                                          runtime: TwinRuntimeSeams = .live) -> TranscriptLine {
        var usage: [String: Any] = [
            "input_tokens": inputTokens,
            "output_tokens": outputTokens,
        ]
        if let costUSD { usage["cost_usd"] = costUSD }
        return TranscriptLine(type: "assistant", body: [
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": ""]],
                "usage": usage,
            ],
        ], runtime: runtime)
    }

    public static func subagentAssistantLine(text: String,
                                              parentToolUseID: String,
                                              subagentType: String = "TaskAgent",
                                              runtime: TwinRuntimeSeams = .live) -> TranscriptLine {
        TranscriptLine(type: "assistant", body: [
            "parentMessageId": parentToolUseID,
            "subagentType": subagentType,
            "message": [
                "role": "assistant",
                "content": [["type": "text", "text": text]],
            ],
        ], runtime: runtime)
    }
}
