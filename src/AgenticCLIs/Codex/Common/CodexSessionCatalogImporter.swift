/// Imports complete Codex rollout JSONL files for an added existing project.
import Foundation

import AgentCore
import AgentProtocol

struct CodexSessionCatalogImporter: Sendable {
    private let fileSystem: any FileSystem
    private let clock: any AgentClock

    init(fileSystem: any FileSystem, clock: any AgentClock) {
        self.fileSystem = fileSystem
        self.clock = clock
    }

    func sessions(
        workspace: URL,
        codexHome: URL,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> [ImportedSession] {
        let activeRoot = codexHome.appendingPathComponent("sessions",
                                                          isDirectory: true)
        let archivedRoot = codexHome.appendingPathComponent("archived_sessions",
                                                            isDirectory: true)
        let active = rolloutURLs(under: activeRoot).map { ($0, false) }
        let archived = rolloutURLs(under: archivedRoot).map { ($0, true) }
        let candidates = (active + archived).sorted { $0.0.path < $1.0.path }

        var output: [ImportedSession] = []
        for (offset, candidate) in candidates.enumerated() {
            try Task.checkCancellation()
            if let session = parse(candidate.0,
                                   archived: candidate.1,
                                   workspace: workspace) {
                output.append(session)
            }
            await progress(offset + 1, candidates.count)
        }
        return output
    }

    private func rolloutURLs(under root: URL) -> [URL] {
        guard fileSystem.fileExists(at: root) else { return [] }
        var pending = [root]
        var output: [URL] = []
        while let directory = pending.popLast() {
            for child in (try? fileSystem.contentsOfDirectory(at: directory)) ?? [] {
                if child.pathExtension == "jsonl" {
                    output.append(child)
                } else if child.pathExtension.isEmpty {
                    pending.append(child)
                }
            }
        }
        return output
    }

    private func parse(_ url: URL,
                       archived: Bool,
                       workspace: URL) -> ImportedSession? {
        guard let data = try? fileSystem.readData(at: url),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let records = text.split(separator: "\n").compactMap { line -> RolloutRecord? in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(RolloutRecord.self, from: lineData)
        }
        guard let metadata = records.first(where: { $0.type == "session_meta" }),
              let id = metadata.payload["id"]?.stringValue,
              let cwd = metadata.payload["cwd"]?.stringValue,
              Self.sameFile(URL(fileURLWithPath: cwd), workspace),
              metadata.payload["parent_thread_id"]?.stringValue == nil,
              metadata.payload["source"]?["subagent"] == nil else {
            return nil
        }

        let events = projectEvents(records)
        let firstUser = events.compactMap { event -> String? in
            if case .userTurn(_, let text) = event { return text }
            return nil
        }.first
        let activity = records.compactMap(\.date).max()
            ?? (try? fileSystem.modificationDate(at: url))
            ?? clock.now()
        return ImportedSession(id: id,
                               title: firstUser,
                               lastActivity: activity,
                               archived: archived,
                               events: events)
    }

    private func projectEvents(_ records: [RolloutRecord]) -> [AgentEvent] {
        let hasResponseUser = records.contains {
            $0.type == "response_item"
                && $0.payload["type"]?.stringValue == "message"
                && $0.payload["role"]?.stringValue == "user"
        }
        return records.enumerated().flatMap { index, record in
            events(for: record, index: index, hasResponseUser: hasResponseUser)
        }
    }

    private func events(for record: RolloutRecord,
                        index: Int,
                        hasResponseUser: Bool) -> [AgentEvent] {
        let recordID = "\(record.timestamp ?? "record")-\(index)"
        if record.type == "event_msg" {
            let isFallbackUser = record.payload["type"]?.stringValue == "user_message"
                && !hasResponseUser
            let text = record.payload["message"]?.stringValue ?? ""
            return isFallbackUser && !text.isEmpty
                ? [.userTurn(id: AdapterTurnID(rawValue: recordID), text: text)]
                : []
        }
        guard record.type == "response_item" else { return [] }
        switch record.payload["type"]?.stringValue {
        case "message":
            return messageEvents(record.payload, recordID: recordID)
        case "reasoning":
            let text = Self.reasoningText(record.payload["summary"])
            guard !text.isEmpty else { return [] }
            let id = Self.stableUUID(recordID)
            return [
                .thinkingChunk(blockID: id, delta: text),
                .thinkingComplete(blockID: id, duration: .zero)
            ]
        case "function_call":
            let id = record.payload["call_id"]?.stringValue ?? recordID
            let name = record.payload["name"]?.stringValue ?? "Tool"
            let arguments = record.payload["arguments"]?.stringValue ?? "{}"
            return [.toolStart(id: ToolCallID(rawValue: id),
                               name: name,
                               input: ToolInput(summary: name, jsonPayload: arguments),
                               startedAt: record.date ?? .distantPast)]
        case "function_call_output":
            let id = record.payload["call_id"]?.stringValue ?? recordID
            let result = record.payload["output"]?.stringValue ?? "Tool completed"
            return [.toolEnd(id: ToolCallID(rawValue: id),
                             success: true,
                             output: ToolOutput(summary: result),
                             durationMS: 0)]
        default:
            return []
        }
    }

    private func messageEvents(_ payload: JSONValue,
                               recordID: String) -> [AgentEvent] {
        let text = Self.contentText(payload["content"])
        guard !text.isEmpty else { return [] }
        switch payload["role"]?.stringValue {
        case "user":
            return [.userTurn(id: AdapterTurnID(rawValue: recordID), text: text)]
        case "assistant":
            return [.assistantText(id: recordID,
                                   blockID: recordID,
                                   text: text,
                                   isFinal: true)]
        default:
            return []
        }
    }

    private static func contentText(_ value: JSONValue?) -> String {
        value?.arrayValue?.compactMap { item in
            item["text"]?.stringValue
        }.joined(separator: "\n") ?? ""
    }

    private static func reasoningText(_ value: JSONValue?) -> String {
        if let text = value?.stringValue { return text }
        return value?.arrayValue?.compactMap { $0["text"]?.stringValue }
            .joined(separator: "\n") ?? ""
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
            || lhs.resolvingSymlinksInPath().path == rhs.resolvingSymlinksInPath().path
    }

    private static func stableUUID(_ value: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in value.utf8.enumerated() {
            bytes[index % bytes.count] &+= byte
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

private struct RolloutRecord: Decodable {
    let timestamp: String?
    let type: String
    let payload: JSONValue

    var date: Date? {
        guard let timestamp else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: timestamp)
            ?? ISO8601DateFormatter().date(from: timestamp)
    }
}
