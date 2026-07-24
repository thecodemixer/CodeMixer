import Foundation
import AgentProtocol
import AgentCore

/// Turns a raw Codex `item` (from `item/started`/`item/completed`) into the
/// tool name, human summary, and structured output Codemixer's `ToolCall`
/// UI renders — shared by `+TurnNotificationHandler`'s item lifecycle
/// handling. Pure projections: no state reads or writes.
extension CodexEventDecoder {
    /// Non-private: `+TurnNotificationHandler`'s `itemStarted`/`itemCompleted`
    /// gate on this set before emitting `toolStart`/`toolEnd`.
    static let toolTypes: Set<String> = [
        "commandExecution",
        "fileChange",
        "mcpToolCall",
        "dynamicToolCall",
        "collabAgentToolCall",
        "webSearch",
        "imageView",
    ]

    func toolName(type: String, item: JSONValue) -> String {
        if let name = item["name"]?.stringValue { return name }
        switch type {
        case "commandExecution": return "Bash"
        case "fileChange": return "Edit"
        case "mcpToolCall": return item["tool"]?.stringValue ?? "MCP"
        case "dynamicToolCall": return item["tool"]?.stringValue ?? "Tool"
        case "webSearch": return "WebSearch"
        case "imageView": return "ImageView"
        case "collabAgentToolCall": return item["tool"]?.stringValue ?? "Subagent"
        default: return type
        }
    }

    func toolSummary(type: String, item: JSONValue) -> String {
        switch type {
        case "commandExecution":
            return item["command"]?.stringValue ?? "Run command"
        case "fileChange":
            return item["changes"]?.arrayValue?
                .compactMap { $0["path"]?.stringValue }
                .joined(separator: ", ") ?? "Apply file changes"
        case "mcpToolCall", "dynamicToolCall":
            return item["tool"]?.stringValue ?? type
        case "webSearch":
            return item["query"]?.stringValue ?? "Search the web"
        case "imageView":
            return item["path"]?.stringValue ?? "View image"
        default:
            return item["name"]?.stringValue ?? type
        }
    }

    func toolOutput(type: String, item: JSONValue) -> ToolOutput {
        let error = item["error"]?["message"]?.stringValue
            ?? item["error"]?.stringValue
        let summary: String
        switch type {
        case "commandExecution":
            summary = item["aggregatedOutput"]?.stringValue ?? item["status"]?.stringValue ?? ""
        case "fileChange":
            summary = toolSummary(type: type, item: item)
        case "mcpToolCall":
            summary = jsonString(item["result"] ?? .null) ?? item["status"]?.stringValue ?? ""
        default:
            summary = item["status"]?.stringValue ?? toolSummary(type: type, item: item)
        }
        return ToolOutput(summary: summary, jsonPayload: jsonString(item), errorMessage: error)
    }

    func toolSucceeded(_ item: JSONValue) -> Bool {
        if let exitCode = item["exitCode"]?.numberValue {
            return Int(exitCode) == 0
        }
        if let success = item["success"]?.boolValue {
            return success
        }
        return ["completed", "success"].contains(item["status"]?.stringValue ?? "")
    }

    func durationMilliseconds(itemID: String, item: JSONValue) -> Int {
        if let duration = item["durationMs"]?.numberValue {
            return max(0, Int(duration))
        }
        guard let start = state.takeItemStartedAt(itemID) else { return 0 }
        return max(0, Int(clock.now().timeIntervalSince(start) * 1_000))
    }

    func itemDuration(itemID: String, item: JSONValue) -> Duration {
        .milliseconds(durationMilliseconds(itemID: itemID, item: item))
    }

    func fileTouchedEvent(_ change: JSONValue) -> AgentEvent? {
        guard let path = change["path"]?.stringValue else { return nil }
        let url = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : workspace.appendingPathComponent(path)
        return .fileTouched(url, kind: .hookReported)
    }

    /// Non-private: also called from `+ApprovalServerRequestHandler`'s
    /// `approvalPrompt` and `+TurnNotificationHandler`'s `itemStarted`.
    func jsonString(_ value: JSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
