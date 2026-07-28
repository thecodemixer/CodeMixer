import Foundation

import AgentCore

/// Decoder for the retired project-local ACP store, used only during import.
enum ACPSessionStoreCodec {
    /// ISO-8601 on disk. Decode also accepts legacy reference-date doubles from
    /// older retired-store writes that used the default `JSONEncoder`.
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
        var flags: SessionRecordFlags

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
             flags: SessionRecordFlags = SessionRecordFlags()) {
            self.id = id
            self.customAgentID = customAgentID
            self.workspacePath = workspacePath
            self.title = title
            self.lastActivity = lastActivity
            self.messageCount = messageCount
            self.turns = turns
            self.flags = flags
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
            // Older writes omit these keys entirely for a never-flagged session.
            flags = SessionRecordFlags(
                archived: try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false,
                needsAttention: try c.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false,
                isOverview: try c.decodeIfPresent(Bool.self, forKey: .isOverview) ?? false,
                overviewURL: try c.decodeIfPresent(String.self, forKey: .overviewURL).flatMap(URL.init(string:))
            )
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(customAgentID, forKey: .customAgentID)
            try c.encode(workspacePath, forKey: .workspacePath)
            try c.encode(title, forKey: .title)
            try c.encode(lastActivity, forKey: .lastActivity)
            try c.encode(messageCount, forKey: .messageCount)
            try c.encode(turns, forKey: .turns)
            try c.encode(flags.archived, forKey: .archived)
            try c.encode(flags.needsAttention, forKey: .needsAttention)
            try c.encode(flags.isOverview, forKey: .isOverview)
            try c.encodeIfPresent(flags.overviewURL?.absoluteString, forKey: .overviewURL)
        }
    }

    /// Lifecycle and overview state retained by the retired store.
    struct SessionRecordFlags: Sendable, Equatable {
        var archived = false
        var needsAttention = false
        var isOverview = false
        var overviewURL: URL?
    }

    struct Store: Sendable, Codable {
        var schemaVersion: Int?
        var entries: [Entry]
    }

    static func events(from turns: [ACPConversationTurn],
                       sessionID: String,
                       clock: any AgentClock,
                       random: any RandomSource) -> [AgentEvent] {
        let now = clock.now()
        return turns.flatMap { turn -> [AgentEvent] in
            switch turn.role {
            case .user:
                return [.userTurn(id: random.uuid().uuidString, text: turn.text)]
            case .thinking:
                let blockID = random.uuid()
                return [
                    .thinkingChunk(blockID: blockID, delta: turn.text),
                    .thinkingComplete(blockID: blockID, duration: .zero),
                ]
            case .tool:
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
            case .assistant, .agent:
                let id = random.uuid().uuidString
                return [.assistantText(id: id, blockID: id, text: turn.text, isFinal: true)]
            case .phase:
                guard let phase = turn.phase else { return [] }
                return [.sessionPhaseChanged(sessionID: sessionID, phase: phase)]
            case .unknown:
                return []
            }
        }
    }

}
