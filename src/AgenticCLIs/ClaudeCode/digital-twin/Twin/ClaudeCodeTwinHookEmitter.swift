import Foundation
import AgentCore
import AgentProtocol

/// Emits hook payloads in the *exact* shape Claude Code sends them, suitable
/// for handing to `ClaudeHookDecoder` in cross-package tests.
public enum ClaudeCodeTwinHookEmitter {

    public struct Context: Sendable {
        public var sessionID: String
        public var workspace: URL
        public var claudeDirectory: URL
        public var permissionMode: String

        public init(sessionID: String,
                    workspace: URL,
                    claudeDirectory: URL,
                    permissionMode: String = "default") {
            self.sessionID = sessionID
            self.workspace = workspace
            self.claudeDirectory = claudeDirectory
            self.permissionMode = permissionMode
        }

        public var transcriptPath: String {
            ClaudeProjectPaths.transcriptURL(sessionID: sessionID,
                                             workspace: workspace,
                                             claudeDirectory: claudeDirectory).path
        }
    }

    public static func sessionStart(sessionID: String,
                                    project: URL,
                                    model: String,
                                    permissionMode: String = "default",
                                    context: Context? = nil) -> Data {
        var body = common(sessionID: sessionID,
                          cwd: project.path,
                          permissionMode: permissionMode,
                          context: context)
        body["hook_event_name"] = "SessionStart"
        body["model"] = model
        return json(body)
    }

    public static func userPromptSubmit(sessionID: String,
                                        prompt: String,
                                        context: Context? = nil) -> Data {
        var body = common(sessionID: sessionID, context: context)
        body["hook_event_name"] = "UserPromptSubmit"
        body["prompt"] = prompt
        return json(body)
    }

    public static func preToolUse(sessionID: String,
                                  toolUseID: String,
                                  toolName: String,
                                  input: [String: Any],
                                  needsPermission: Bool,
                                  context: Context? = nil) -> Data {
        var body = common(sessionID: sessionID, context: context)
        body["hook_event_name"] = "PreToolUse"
        body["tool_use_id"] = toolUseID
        body["tool_name"] = toolName
        body["tool_input"] = input
        if needsPermission {
            body["needs_permission"] = true
            body["permission_id"] = "perm_\(UUID().uuidString.prefix(8))"
        }
        return json(body)
    }

    public static func postToolUse(sessionID: String,
                                   toolUseID: String,
                                   toolName: String,
                                   output: String,
                                   exitCode: Int = 0,
                                   isError: Bool = false,
                                   durationMS: Int = 0,
                                   context: Context? = nil) -> Data {
        var body = common(sessionID: sessionID, context: context)
        body["hook_event_name"] = "PostToolUse"
        body["tool_use_id"] = toolUseID
        body["tool_name"] = toolName
        body["tool_input"] = [:] as [String: Any]
        body["tool_response"] = ["output": output, "exit_code": exitCode]
        body["is_error"] = isError
        body["duration_ms"] = durationMS
        return json(body)
    }

    public static func notification(sessionID: String,
                                    message: String,
                                    context: Context? = nil) -> Data {
        var body = common(sessionID: sessionID, context: context)
        body["hook_event_name"] = "Notification"
        body["message"] = message
        return json(body)
    }

    public static func stop(sessionID: String,
                            lastAssistantMessage: String? = nil,
                            context: Context? = nil) -> Data {
        var body = common(sessionID: sessionID, context: context)
        body["hook_event_name"] = "Stop"
        body["stop_hook_active"] = false
        if let lastAssistantMessage {
            body["last_assistant_message"] = lastAssistantMessage
        }
        return json(body)
    }

    public static func subagentStop(sessionID: String,
                                    agentID: String,
                                    agentType: String,
                                    agentTranscriptPath: String,
                                    lastAssistantMessage: String?,
                                    context: Context? = nil) -> Data {
        var body = common(sessionID: sessionID, context: context)
        body["hook_event_name"] = "SubagentStop"
        body["agent_id"] = agentID
        body["agent_type"] = agentType
        body["agent_transcript_path"] = agentTranscriptPath
        body["stop_hook_active"] = false
        if let lastAssistantMessage {
            body["last_assistant_message"] = lastAssistantMessage
        }
        return json(body)
    }

    private static func common(sessionID: String,
                               cwd: String? = nil,
                               permissionMode: String? = nil,
                               context: Context?) -> [String: Any] {
        var body: [String: Any] = [
            "session_id": sessionID,
            "hook_event_name": "",
        ]
        if let context {
            body["transcript_path"] = context.transcriptPath
            body["cwd"] = context.workspace.path
            body["permission_mode"] = context.permissionMode
        }
        if let cwd { body["cwd"] = cwd }
        if let permissionMode { body["permission_mode"] = permissionMode }
        return body
    }

    private static func json(_ body: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
