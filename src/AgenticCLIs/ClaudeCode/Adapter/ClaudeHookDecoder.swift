import Foundation
import AgentCore
import AgentProtocol

/// Decode Claude Code hook JSON payloads into `AgentEvent` values.
///
/// Claude's hook schema is mostly stable but documented loosely; we model
/// only the fields we use, leaving the rest as opaque JSON.
struct ClaudeHookDecoder: Sendable {
    private let clock: any AgentClock
    private let random: any RandomSource

    init(clock: any AgentClock = SystemClock(),
         random: any RandomSource = SystemRandomSource()) {
        self.clock = clock
        self.random = random
    }

    /// Convert a single hook request into zero-or-more events.
    func events(from request: HookRequest) -> [AgentEvent] {
        switch request.eventName {
        case "SessionStart":
            return [decodeSessionStart(request.jsonPayload)].compactMap { $0 }
        case "UserPromptSubmit":
            return [decodeUserPrompt(request.jsonPayload)].compactMap { $0 }
        case "PreToolUse":
            var events: [AgentEvent] = []
            if let prompt = decodePermissionPrompt(request.jsonPayload, requestID: request.id) {
                events.append(.permissionRequest(prompt: prompt))
            }
            if let start = decodePreToolStart(request.jsonPayload, requestID: request.id) {
                events.append(start)
            }
            return events
        case "PostToolUse":
            return decodePostToolUse(request.jsonPayload, requestID: request.id)
        case "Notification":
            return decodeNotification(request.jsonPayload)
        case "Stop", "SubagentStop":
            return decodeStop(request.jsonPayload) + [.activityStateChanged(.idle)]
        default:
            break
        }
        return []
    }

    private func decodePreToolStart(_ data: Data, requestID: UUID) -> AgentEvent? {
        struct Body: Decodable {
            let tool_name: String?
            let tool_input: [String: AnyCodableValue]?
        }
        guard let b = try? JSONDecoder().decode(Body.self, from: data),
              let toolName = b.tool_name else { return nil }
        let summary = humanSummary(tool: toolName, args: b.tool_input)
        let json = b.tool_input.flatMap(prettyJSON)
        return .toolStart(id: requestID.uuidString,
                          name: toolName,
                          input: ToolInput(summary: summary, jsonPayload: json),
                          startedAt: clock.now())
    }

    // MARK: - Per-event decoders

    private func decodeSessionStart(_ data: Data) -> AgentEvent? {
        struct Body: Decodable {
            let session_id: String?
            let cwd: String?
            let model: String?
        }
        guard let b = try? JSONDecoder().decode(Body.self, from: data),
              let id = b.session_id else { return nil }
        let cwd = b.cwd.map(URL.init(fileURLWithPath:)) ?? URL(fileURLWithPath: ".")
        return .sessionStarted(sessionID: id, model: b.model, cwd: cwd)
    }

    private func decodeUserPrompt(_ data: Data) -> AgentEvent? {
        struct Body: Decodable {
            let prompt: String?
            let session_id: String?
        }
        guard let b = try? JSONDecoder().decode(Body.self, from: data),
              let text = b.prompt else { return nil }
        return .userTurn(id: b.session_id ?? random.uuid().uuidString, text: text)
    }

    private func decodePermissionPrompt(_ data: Data, requestID: UUID) -> PermissionPrompt? {
        struct Body: Decodable {
            let tool_name: String?
            let tool_input: [String: AnyCodableValue]?
            let needs_permission: Bool?
        }
        guard let b = try? JSONDecoder().decode(Body.self, from: data),
              let toolName = b.tool_name,
              b.needs_permission == true else { return nil }
        let argsSummary = b.tool_input.flatMap(prettyJSON) ?? ""
        return PermissionPrompt(id: requestID,
                                toolName: toolName,
                                summary: humanSummary(tool: toolName, args: b.tool_input),
                                argumentsSummary: argsSummary,
                                requestedAt: clock.now())
    }

    private func decodePostToolUse(_ data: Data, requestID: UUID) -> [AgentEvent] {
        struct Body: Decodable {
            let tool_name: String?
            let tool_input: [String: AnyCodableValue]?
            let tool_response: [String: AnyCodableValue]?
            let duration_ms: Int?
            let is_error: Bool?
        }
        guard let b = try? JSONDecoder().decode(Body.self, from: data),
              let toolName = b.tool_name else { return [] }

        var events: [AgentEvent] = []
        if toolName == "Edit" || toolName == "Write" || toolName == "MultiEdit" {
            if case .string(let path) = b.tool_input?["file_path"] {
                events.append(.fileTouched(URL(fileURLWithPath: path), kind: .hookReported))
            }
        }

        let success = !(b.is_error ?? false)
        let summary = humanSummary(tool: toolName, args: b.tool_input)
        let errMessage: String? = {
            guard b.is_error == true else { return nil }
            if case .string(let s) = b.tool_response?["error"] { return s }
            return "Tool reported an error"
        }()
        let output = ToolOutput(summary: summary,
                                jsonPayload: b.tool_response.flatMap(prettyJSON),
                                errorMessage: errMessage)
        events.append(.toolEnd(id: requestID.uuidString,
                               success: success,
                               output: output,
                               durationMS: b.duration_ms ?? 0))
        return events
    }

    private func decodeNotification(_ data: Data) -> [AgentEvent] {
        struct Body: Decodable {
            let message: String?
        }
        guard let b = try? JSONDecoder().decode(Body.self, from: data),
              let message = b.message else { return [] }
        return [.statusPhraseChanged(source: .hookHint, phrase: message)]
    }

    private func decodeStop(_ data: Data) -> [AgentEvent] {
        struct Body: Decodable {
            let last_assistant_message: String?
        }
        guard let b = try? JSONDecoder().decode(Body.self, from: data),
              let text = b.last_assistant_message,
              !text.isEmpty else { return [] }
        let id = random.uuid().uuidString
        return [.assistantText(id: id,
                               blockID: random.uuid().uuidString,
                               text: text,
                               isFinal: true)]
    }

    // MARK: - Helpers

    func humanSummary(tool: String,
                      args: [String: AnyCodableValue]?) -> String {
        switch tool {
        case "Bash":
            if case .string(let cmd) = args?["command"] {
                return "Run: \(truncate(cmd, to: 80))"
            }
            return "Run a shell command"
        case "Edit", "Write", "MultiEdit":
            if case .string(let path) = args?["file_path"] {
                return "Modify \(path)"
            }
            return "Modify a file"
        case "Read":
            if case .string(let path) = args?["file_path"] {
                return "Read \(path)"
            }
            return "Read a file"
        case "Grep":
            if case .string(let pattern) = args?["pattern"] {
                return "Search for \(pattern)"
            }
            return "Search files"
        default:
            return "Use \(tool)"
        }
    }

    private func prettyJSON(_ dict: [String: AnyCodableValue]) -> String? {
        guard let data = try? JSONEncoder().encode(dict),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private func truncate(_ s: String, to max: Int) -> String {
        s.count <= max ? s : (String(s.prefix(max - 1)) + "…")
    }
}

/// Catch-all JSON value used when we want to read a few fields out of an
/// arbitrary tool-input dictionary without modelling the whole schema.
enum AnyCodableValue: Codable, Sendable, Hashable {
    case string(String), number(Double), bool(Bool), null
    case array([AnyCodableValue]), object([String: AnyCodableValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Double.self) { self = .number(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([AnyCodableValue].self) { self = .array(v); return }
        if let v = try? container.decode([String: AnyCodableValue].self) { self = .object(v); return }
        self = .null
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:           try container.encodeNil()
        case .bool(let v):    try container.encode(v)
        case .number(let v):  try container.encode(v)
        case .string(let v):  try container.encode(v)
        case .array(let v):   try container.encode(v)
        case .object(let v):  try container.encode(v)
        }
    }
}
