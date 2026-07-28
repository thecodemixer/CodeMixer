/// Decodes the stable message leaves referenced by Cursor's root blob.
import Foundation

import AgentCore
import AgentProtocol

struct CursorTranscriptDecoder: Sendable {
    let sqlite: any SQLiteReading
    let random: any RandomSource

    func events(databaseURL: URL,
                rootBlobID: String,
                sessionID: String,
                timestamp: Date) throws -> [AgentEvent] {
        guard let root = try blob(id: rootBlobID, databaseURL: databaseURL) else {
            return []
        }
        let messageIDs = Self.lengthDelimitedFields(in: root, fieldNumber: 1)
            .map(Self.hexString)
        var events: [AgentEvent] = []
        for (index, messageID) in messageIDs.enumerated() {
            guard let data = try blob(id: messageID, databaseURL: databaseURL),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
                continue
            }
            events.append(contentsOf: projectedEvents(
                value,
                idPrefix: "\(sessionID)-\(index)",
                timestamp: timestamp
            ))
        }
        return events
    }

    private func blob(id: String, databaseURL: URL) throws -> Data? {
        try sqlite.rows(
            in: databaseURL,
            query: "SELECT data FROM blobs WHERE id = ? LIMIT 1",
            textBindings: [id]
        ).first?["data"]
    }

    private func projectedEvents(_ message: JSONValue,
                                 idPrefix: String,
                                 timestamp: Date) -> [AgentEvent] {
        let role = message["role"]?.stringValue
        let blocks = contentBlocks(message["content"])
        switch role {
        case "user":
            let text = blocks.compactMap(\.text).joined(separator: "\n")
            guard !text.isEmpty else { return [] }
            return [.userTurn(id: idPrefix, text: Self.userPrompt(from: text))]
        case "assistant":
            return assistantEvents(blocks, idPrefix: idPrefix, timestamp: timestamp)
        case "tool":
            return blocks.compactMap {
                toolEndEvent($0, fallbackID: idPrefix)
            }
        default:
            return []
        }
    }

    private func assistantEvents(_ blocks: [ContentBlock],
                                 idPrefix: String,
                                 timestamp: Date) -> [AgentEvent] {
        var events: [AgentEvent] = []
        for (index, block) in blocks.enumerated() {
            let blockID = "\(idPrefix)-\(index)"
            switch block.type {
            case "reasoning":
                guard let text = block.text, !text.isEmpty else { continue }
                let thinkingID = random.uuid()
                events.append(.thinkingChunk(blockID: thinkingID, delta: text))
                events.append(.thinkingComplete(blockID: thinkingID, duration: .zero))
            case "text":
                guard let text = block.text, !text.isEmpty else { continue }
                events.append(.assistantText(
                    id: idPrefix,
                    blockID: blockID,
                    text: text,
                    isFinal: true
                ))
            case "tool-call", "toolCall", "tool_use":
                events.append(.toolStart(
                    id: block.toolID ?? blockID,
                    name: block.toolName ?? "Tool",
                    input: ToolInput(
                        summary: block.toolName ?? "Tool call",
                        jsonPayload: block.payload
                    ),
                    startedAt: timestamp
                ))
            case "tool-result", "toolResult":
                if let event = toolEndEvent(block, fallbackID: blockID) {
                    events.append(event)
                }
            default:
                continue
            }
        }
        return events
    }

    private func toolEndEvent(_ block: ContentBlock,
                              fallbackID: String) -> AgentEvent? {
        guard let output = block.text ?? block.payload else { return nil }
        return .toolEnd(
            id: block.toolID ?? fallbackID,
            success: true,
            output: ToolOutput(summary: output),
            durationMS: 0
        )
    }

    private func contentBlocks(_ content: JSONValue?) -> [ContentBlock] {
        guard let content else { return [] }
        if let text = content.stringValue {
            return [ContentBlock(type: "text", text: text)]
        }
        return (content.arrayValue ?? []).compactMap { value in
            guard let object = value.objectValue else { return nil }
            return ContentBlock(
                type: object["type"]?.stringValue ?? "text",
                text: object["text"]?.stringValue
                    ?? object["content"]?.stringValue
                    ?? object["output"]?.stringValue,
                toolID: object["toolCallId"]?.stringValue
                    ?? object["toolCallID"]?.stringValue
                    ?? object["id"]?.stringValue,
                toolName: object["toolName"]?.stringValue
                    ?? object["name"]?.stringValue,
                payload: encodedJSON(object["input"] ?? object["args"])
            )
        }
    }

    private func encodedJSON(_ value: JSONValue?) -> String? {
        guard let value,
              let data = try? JSONEncoder().encode(value) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func userPrompt(from text: String) -> String {
        guard let start = text.range(of: "<user_query>"),
              let end = text.range(of: "</user_query>",
                                   range: start.upperBound ..< text.endIndex) else {
            return text
        }
        return String(text[start.upperBound ..< end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func lengthDelimitedFields(in data: Data,
                                              fieldNumber: Int) -> [Data] {
        let bytes = [UInt8](data)
        var index = 0
        var values: [Data] = []
        while index < bytes.count, let key = readVarint(bytes, index: &index) {
            let wireType = Int(key & 7)
            let field = Int(key >> 3)
            guard wireType == 2,
                  let length = readVarint(bytes, index: &index),
                  length <= UInt64(bytes.count - index) else {
                break
            }
            let end = index + Int(length)
            if field == fieldNumber {
                values.append(Data(bytes[index ..< end]))
            }
            index = end
        }
        return values
    }

    private static func readVarint(_ bytes: [UInt8],
                                   index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count, shift < 64 {
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private struct ContentBlock {
        let type: String
        let text: String?
        let toolID: String?
        let toolName: String?
        let payload: String?

        init(type: String,
             text: String? = nil,
             toolID: String? = nil,
             toolName: String? = nil,
             payload: String? = nil) {
            self.type = type
            self.text = text
            self.toolID = toolID
            self.toolName = toolName
            self.payload = payload
        }
    }
}
