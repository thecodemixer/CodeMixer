import Foundation
import AgentProtocol

import AgentCore

/// Reconstructs Codemixer events from Codex `thread.turns` payloads returned by
/// `thread/resume`, `thread/start`, and `thread/read`.
enum CodexThreadHistoryReplay {
  static func events(from turns: [JSONValue],
                     random: any RandomSource) -> [AgentEvent] {
    turns.flatMap { turn in
      guard let items = turn["items"]?.arrayValue else { return [AgentEvent]() }
      return items.compactMap { item in event(for: item, random: random) }
    }
  }

  private static func event(for item: JSONValue,
                            random: any RandomSource) -> AgentEvent? {
    guard let type = item["type"]?.stringValue else { return nil }
    let itemID = item["id"]?.stringValue ?? random.uuid().uuidString
    switch type {
    case "userMessage":
      let text = userMessageText(from: item)
      guard !text.isEmpty else { return nil }
      return .userTurn(id: itemID, text: text)
    case "agentMessage", "plan":
      let text = item["text"]?.stringValue ?? ""
      guard !text.isEmpty else { return nil }
      return .assistantText(id: itemID, blockID: itemID, text: text, isFinal: true)
    case "exitedReviewMode":
      let text = item["review"]?.stringValue ?? ""
      guard !text.isEmpty else { return nil }
      return .assistantText(id: itemID, blockID: itemID, text: text, isFinal: true)
    default:
      return nil
    }
  }

  private static func userMessageText(from item: JSONValue) -> String {
    guard let parts = item["content"]?.arrayValue else { return "" }
    return parts.compactMap { part -> String? in
      guard part["type"]?.stringValue == "text" else { return nil }
      return part["text"]?.stringValue
    }
    .joined(separator: "\n")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
