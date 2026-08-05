import A2UICore
import Foundation
import AgentCore

/// Pure session export helpers shared by the app shell and tests.
///
/// Prefer `SnapshotService.SnapshotMessage` (domain transcript projection).
/// The `EngineViewModel.Message` overloads exist for unit tests and adapt
/// live UI rows into the same domain shape.
public enum SessionExporter {

    public static func markdown(_ messages: [SnapshotService.SnapshotMessage]) -> Data {
        let lines = messages.map { message -> String in
            switch message.role {
            case .user:
                return "**You:** \(message.text)"
            case .assistant:
                return message.text
            case .action:
                return "*\(message.text)*"
            }
        }
        return Data(lines.joined(separator: "\n\n").utf8)
    }

    public static func jsonl(_ messages: [SnapshotService.SnapshotMessage]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        struct Line: Encodable {
            let role: SnapshotService.TranscriptRole
            let text: String
        }
        let lines = messages.compactMap { message -> Data? in
            try? encoder.encode(Line(role: message.role, text: message.text))
        }
        return Data(lines.flatMap { $0 + "\n".utf8 })
    }

    public static func html(_ messages: [SnapshotService.SnapshotMessage]) -> Data {
        let rows = messages.map { message -> String in
            switch message.role {
            case .user:
                return "<div class=\"user\"><strong>You:</strong> \(htmlEscaped(message.text))</div>"
            case .assistant:
                return "<div class=\"assistant\">\(htmlEscaped(message.text))</div>"
            case .action:
                return "<div class=\"action\">\(htmlEscaped(message.text))</div>"
            }
        }.joined(separator: "\n")
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <title>Codemixer Session</title>
        <style>
          body { font-family: system-ui; max-width: 800px; margin: 2rem auto; }
          .user { background: #f0f4ff; padding: .75rem 1rem; border-radius: 12px; margin: .5rem 0; }
          .assistant { padding: .75rem 0; white-space: pre-wrap; }
          .action { color: #6b7280; text-align: center; font-size: .875rem; margin: .5rem 0; }
        </style></head><body>
        \(rows)
        </body></html>
        """
        return Data(html.utf8)
    }

    public static func markdown(_ messages: [EngineViewModel.Message],
                                a2uiSurfaces: [String: A2UISurfaceState] = [:]) -> Data {
        markdown(snapshotMessages(from: messages, a2uiSurfaces: a2uiSurfaces))
    }

    public static func jsonl(_ messages: [EngineViewModel.Message],
                             a2uiSurfaces: [String: A2UISurfaceState] = [:]) -> Data {
        jsonl(snapshotMessages(from: messages, a2uiSurfaces: a2uiSurfaces))
    }

    public static func html(_ messages: [EngineViewModel.Message],
                            a2uiSurfaces: [String: A2UISurfaceState] = [:]) -> Data {
        html(snapshotMessages(from: messages, a2uiSurfaces: a2uiSurfaces))
    }

    public static func htmlEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// `a2uiSurfaces` supplies the live canonical state for `.a2uiSurface`
    /// ordering markers, which — like `.toolCall` — carry no text inline.
    /// Exports the same redacted `A2UITextSummary` used for durable
    /// transcript snapshots rather than raw JSON.
    public static func snapshotMessages(from messages: [EngineViewModel.Message],
                                        a2uiSurfaces: [String: A2UISurfaceState] = [:])
        -> [SnapshotService.SnapshotMessage] {
        let now = Date()
        return messages.compactMap { message in
            switch message {
            case .user(_, let text):
                return .init(role: .user, text: text, timestamp: now)
            case .assistant(_, let text), .assistantStreaming(_, let text):
                return .init(role: .assistant, text: text, timestamp: now)
            case .clientAction(let action):
                let text = action.detail.map { "\(action.title): \($0)" } ?? action.title
                return .init(role: .action, text: text, timestamp: now)
            case .a2uiSurface(let surfaceID):
                guard let surface = a2uiSurfaces[surfaceID] else { return nil }
                return .init(role: .assistant, text: A2UITextSummary.summary(for: surface), timestamp: now)
            case .thinkingChunk, .thinkingComplete, .toolCall:
                return nil
            }
        }
    }
}
