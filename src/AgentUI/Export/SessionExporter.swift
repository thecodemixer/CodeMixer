import Foundation

/// Pure session export helpers shared by the app shell and tests.
public enum SessionExporter {

    public static func markdown(_ messages: [EngineViewModel.Message]) -> Data {
        let lines = messages.compactMap { message -> String? in
            switch message {
            case .user(_, let text):
                return "**You:** \(text)"
            case .assistant(_, let text), .assistantStreaming(_, let text):
                return text
            case .clientAction(let action):
                let body = action.detail.map { "\(action.title): \($0)" } ?? action.title
                return "*\(body)*"
            case .thinkingChunk, .thinkingComplete, .toolCall:
                return nil
            }
        }.joined(separator: "\n\n")
        return Data(lines.utf8)
    }

    public static func jsonl(_ messages: [EngineViewModel.Message]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let lines = messages.compactMap { message -> Data? in
            struct Line: Encodable {
                let role: String
                let text: String
            }
            switch message {
            case .user(_, let text):
                return try? encoder.encode(Line(role: "user", text: text))
            case .assistant(_, let text), .assistantStreaming(_, let text):
                return try? encoder.encode(Line(role: "assistant", text: text))
            case .clientAction(let action):
                let text = action.detail.map { "\(action.title): \($0)" } ?? action.title
                return try? encoder.encode(Line(role: "action", text: text))
            case .thinkingChunk, .thinkingComplete, .toolCall:
                return nil
            }
        }
        return Data(lines.flatMap { $0 + "\n".utf8 })
    }

    public static func html(_ messages: [EngineViewModel.Message]) -> Data {
        let rows = messages.compactMap { message -> String? in
            switch message {
            case .user(_, let text):
                return "<div class=\"user\"><strong>You:</strong> \(htmlEscaped(text))</div>"
            case .assistant(_, let text), .assistantStreaming(_, let text):
                return "<div class=\"assistant\">\(htmlEscaped(text))</div>"
            case .clientAction(let action):
                let body = action.detail.map { "\(action.title): \($0)" } ?? action.title
                return "<div class=\"action\">\(htmlEscaped(body))</div>"
            case .thinkingChunk, .thinkingComplete, .toolCall:
                return nil
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

    public static func htmlEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
