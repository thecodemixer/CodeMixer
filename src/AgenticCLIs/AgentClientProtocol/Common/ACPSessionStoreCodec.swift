import Foundation

import AgentCore

/// Shared Codable envelope used by app-support and project ACP session stores.
enum ACPSessionStoreCodec {
    static let maxTurns = 200

    /// ISO-8601 on disk. Decode also accepts legacy reference-date doubles from
    /// older `ACPSessionIndex` writes that used the default `JSONEncoder`.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                let fractional = ISO8601DateFormatter()
                fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = fractional.date(from: string) { return date }
                let basic = ISO8601DateFormatter()
                basic.formatOptions = [.withInternetDateTime]
                if let date = basic.date(from: string) { return date }
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognized ISO-8601 date: \(string)"
                )
            }
            let seconds = try container.decode(Double.self)
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        return decoder
    }

    struct Entry: Sendable, Codable {
        let id: String
        let customAgentID: String
        let workspacePath: String
        var title: String
        var lastActivity: Date
        var messageCount: Int
        var turns: [ACPConversationTurn]
        var archived: Bool?
        var needsAttention: Bool?
        var isOverview: Bool?
        var overviewURL: String?

        enum CodingKeys: String, CodingKey {
            case id, customAgentID, workspacePath, title, lastActivity, messageCount, turns
            case archived, needsAttention, isOverview, overviewURL
        }

        init(id: String,
             customAgentID: String,
             workspacePath: String,
             title: String,
             lastActivity: Date,
             messageCount: Int,
             turns: [ACPConversationTurn],
             archived: Bool? = nil,
             needsAttention: Bool? = nil,
             isOverview: Bool? = nil,
             overviewURL: String? = nil) {
            self.id = id
            self.customAgentID = customAgentID
            self.workspacePath = workspacePath
            self.title = title
            self.lastActivity = lastActivity
            self.messageCount = messageCount
            self.turns = turns
            self.archived = archived
            self.needsAttention = needsAttention
            self.isOverview = isOverview
            self.overviewURL = overviewURL
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            customAgentID = try c.decode(String.self, forKey: .customAgentID)
            workspacePath = try c.decode(String.self, forKey: .workspacePath)
            title = try c.decode(String.self, forKey: .title)
            lastActivity = try c.decode(Date.self, forKey: .lastActivity)
            messageCount = try c.decode(Int.self, forKey: .messageCount)
            turns = try c.decodeIfPresent([ACPConversationTurn].self, forKey: .turns) ?? []
            archived = try c.decodeIfPresent(Bool.self, forKey: .archived)
            needsAttention = try c.decodeIfPresent(Bool.self, forKey: .needsAttention)
            isOverview = try c.decodeIfPresent(Bool.self, forKey: .isOverview)
            overviewURL = try c.decodeIfPresent(String.self, forKey: .overviewURL)
        }
    }

    struct Store: Sendable, Codable {
        var schemaVersion: Int?
        var entries: [Entry]
    }

    static func key(customAgentID: String, sessionID: String) -> String {
        "\(customAgentID)::\(sessionID)"
    }

    static func events(from turns: [ACPConversationTurn],
                       clock: any AgentClock,
                       random: any RandomSource) -> [AgentEvent] {
        let now = clock.now()
        return turns.flatMap { turn -> [AgentEvent] in
            switch turn.role {
            case "user":
                return [.userTurn(id: random.uuid().uuidString, text: turn.text)]
            case "thinking":
                let blockID = random.uuid()
                return [
                    .thinkingChunk(blockID: blockID, delta: turn.text),
                    .thinkingComplete(blockID: blockID, duration: .zero),
                ]
            case "tool":
                let id = turn.toolCallID ?? random.uuid().uuidString
                return [
                    .toolStart(
                        id: id,
                        name: turn.text,
                        input: ToolInput(summary: turn.text, jsonPayload: turn.toolInputJSON),
                        startedAt: now
                    ),
                    .toolEnd(
                        id: id,
                        success: turn.toolSuccess ?? true,
                        output: ToolOutput(summary: turn.toolOutputSummary ?? ""),
                        durationMS: 0
                    ),
                ]
            case "assistant":
                let id = random.uuid().uuidString
                return [.assistantText(id: id, blockID: id, text: turn.text, isFinal: true)]
            default:
                return []
            }
        }
    }

    static func trimmedTurns(_ turns: [ACPConversationTurn]) -> [ACPConversationTurn] {
        guard turns.count > maxTurns else { return turns }
        return Array(turns.suffix(maxTurns))
    }

    static func chatMessageCount(in turns: [ACPConversationTurn]) -> Int {
        turns.filter { $0.role == "user" || $0.role == "assistant" }.count
    }
}
