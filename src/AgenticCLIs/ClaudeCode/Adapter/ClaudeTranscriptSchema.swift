import Foundation
import OSLog
import AgentCore

extension ClaudeTranscriptTailer {

    public struct Record: Decodable, Sendable {
        public let type: String
        public let message: Message?
        public let uuid: String?
        public let sessionId: String?
        public let toolUseID: String?
        public let content: [ContentBlock]?
        public let text: String?
        public let isError: Bool?
        public let durationMS: Int?
        /// Set when this record belongs to a subagent conversation.
        /// The value is the parent tool-use message ID that spawned the subagent.
        public let parentMessageId: String?
        /// Human-readable label for the subagent, e.g. "SubagentTask".
        public let subagentType: String?

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            message = try? container.decode(Message.self, forKey: .message)
            uuid = try? container.decode(String.self, forKey: .uuid)
            sessionId = try? container.decode(String.self, forKey: .sessionId)
            toolUseID = try? container.decode(String.self, forKey: .toolUseID)
            if let blocks = try? container.decode([ContentBlock].self, forKey: .content) {
                content = blocks
                text = nil
            } else {
                content = nil
                text = try? container.decode(String.self, forKey: .content)
            }
            isError = try? container.decode(Bool.self, forKey: .isError)
            durationMS = try? container.decode(Int.self, forKey: .durationMS)
            parentMessageId = try? container.decode(String.self, forKey: .parentMessageId)
            subagentType = try? container.decode(String.self, forKey: .subagentType)
        }

        private enum CodingKeys: String, CodingKey {
            case type, message, uuid, sessionId
            case toolUseID = "tool_use_id"
            case content
            case isError = "is_error"
            case durationMS = "duration_ms"
            case parentMessageId = "parentMessageId"
            case subagentType = "subagentType"
        }
    }

    public struct Message: Decodable, Sendable {
        public let role: String?
        public let content: [ContentBlock]?
        public let text: String?
        public let usage: Usage?

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try? container.decode(String.self, forKey: .role)
            usage = try? container.decode(Usage.self, forKey: .usage)
            if let blocks = try? container.decode([ContentBlock].self, forKey: .content) {
                content = blocks
                text = nil
            } else {
                content = nil
                text = try? container.decode(String.self, forKey: .content)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case role, content, usage
        }
    }

    public struct Usage: Decodable, Sendable {
        public let input_tokens: Int?
        public let output_tokens: Int?
        public let cost_usd: Double?
    }

    public enum ContentBlock: Decodable, Sendable {
        case text(String)
        case thinking(String)
        case toolUse(id: String?, name: String, inputJSON: String)
        case toolResult(id: String?, content: String, isError: Bool)
        case other

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = (try? container.decode(String.self, forKey: .type)) ?? ""
            switch kind {
            case "text":
                self = .text((try? container.decode(String.self, forKey: .text)) ?? "")
            case "thinking":
                self = .thinking((try? container.decode(String.self, forKey: .thinking)) ?? "")
            case "tool_use":
                let id = try? container.decode(String.self, forKey: .id)
                let name = (try? container.decode(String.self, forKey: .name)) ?? "tool"
                let input = (try? container.decode(AnyCodableValue.self, forKey: .input))
                    .flatMap { try? JSONEncoder().encode($0) }
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                self = .toolUse(id: id, name: name, inputJSON: input)
            case "tool_result":
                let id = try? container.decode(String.self, forKey: .toolUseID)
                let isError = (try? container.decode(Bool.self, forKey: .isError)) ?? false
                self = .toolResult(id: id,
                                   content: Self.textContent(from: container),
                                   isError: isError)
            default:
                self = .other
            }
        }

        private static func textContent(from container: KeyedDecodingContainer<CodingKeys>) -> String {
            if let text = try? container.decode(String.self, forKey: .content) {
                return text
            }
            if let blocks = try? container.decode([ContentBlock].self, forKey: .content) {
                return blocks.compactMap { block in
                    if case .text(let text) = block { return text }
                    return nil
                }.joined(separator: "\n")
            }
            return ""
        }

        private enum CodingKeys: String, CodingKey {
            case type, text, thinking, id, name, input, content
            case toolUseID = "tool_use_id"
            case isError = "is_error"
        }
    }
}
