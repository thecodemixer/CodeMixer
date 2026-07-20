import Foundation

import AgentCore

/// Persists ACP session metadata and a Codemixer-owned turn cache for the
/// resumable-session list. Cursor's `session/load` currently returns modes /
/// models without replaying history; the turn cache restores chat rows
/// (user / thinking / tool / assistant) when the agent does not stream load chunks.
public actor ACPSessionIndex {
    private struct Turn: Sendable, Codable {
        let role: String
        let text: String
        let toolCallID: String?
        let toolSuccess: Bool?
        let toolOutputSummary: String?
        let toolInputJSON: String?

        enum CodingKeys: String, CodingKey {
            case role, text, toolCallID, toolSuccess, toolOutputSummary, toolInputJSON
        }

        init(role: String,
             text: String,
             toolCallID: String? = nil,
             toolSuccess: Bool? = nil,
             toolOutputSummary: String? = nil,
             toolInputJSON: String? = nil) {
            self.role = role
            self.text = text
            self.toolCallID = toolCallID
            self.toolSuccess = toolSuccess
            self.toolOutputSummary = toolOutputSummary
            self.toolInputJSON = toolInputJSON
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try c.decode(String.self, forKey: .role)
            text = try c.decode(String.self, forKey: .text)
            toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
            toolSuccess = try c.decodeIfPresent(Bool.self, forKey: .toolSuccess)
            toolOutputSummary = try c.decodeIfPresent(String.self, forKey: .toolOutputSummary)
            toolInputJSON = try c.decodeIfPresent(String.self, forKey: .toolInputJSON)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(role, forKey: .role)
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(toolCallID, forKey: .toolCallID)
            try c.encodeIfPresent(toolSuccess, forKey: .toolSuccess)
            try c.encodeIfPresent(toolOutputSummary, forKey: .toolOutputSummary)
            try c.encodeIfPresent(toolInputJSON, forKey: .toolInputJSON)
        }
    }

    private struct Entry: Sendable, Codable {
        let id: String
        let customAgentID: String
        let workspacePath: String
        var title: String
        var lastActivity: Date
        var messageCount: Int
        var turns: [Turn]

        enum CodingKeys: String, CodingKey {
            case id, customAgentID, workspacePath, title, lastActivity, messageCount, turns
        }

        init(id: String,
             customAgentID: String,
             workspacePath: String,
             title: String,
             lastActivity: Date,
             messageCount: Int,
             turns: [Turn]) {
            self.id = id
            self.customAgentID = customAgentID
            self.workspacePath = workspacePath
            self.title = title
            self.lastActivity = lastActivity
            self.messageCount = messageCount
            self.turns = turns
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            customAgentID = try c.decode(String.self, forKey: .customAgentID)
            workspacePath = try c.decode(String.self, forKey: .workspacePath)
            title = try c.decode(String.self, forKey: .title)
            lastActivity = try c.decode(Date.self, forKey: .lastActivity)
            messageCount = try c.decode(Int.self, forKey: .messageCount)
            turns = try c.decodeIfPresent([Turn].self, forKey: .turns) ?? []
        }
    }

    private struct Store: Sendable, Codable {
        var entries: [Entry]
    }

    private let fileSystem: any FileSystem
    private let clock: any AgentClock
    private let url: URL
    private var entries: [String: Entry] = [:]
    private var hasLoaded = false

    public init(environment: any AgentEnvironment = SystemEnvironment(),
                fileSystem: any FileSystem = SystemFileSystem(),
                clock: any AgentClock = SystemClock()) {
        self.fileSystem = fileSystem
        self.clock = clock
        self.url = AppSupportPaths.acpSessionsURL(in: environment.appSupportDirectory)
    }

    public func recordSession(id: String,
                              customAgentID: String,
                              workspace: URL,
                              title: String?) async {
        await loadIfNeeded()
        let path = workspace.standardizedFileURL.path
        let key = Self.key(customAgentID: customAgentID, sessionID: id)
        let existing = entries[key]
        entries[key] = Entry(
            id: id,
            customAgentID: customAgentID,
            workspacePath: path,
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? existing?.title ?? id,
            lastActivity: clock.now(),
            messageCount: existing?.messageCount ?? 0,
            turns: existing?.turns ?? []
        )
        await persist()
    }

    public func recordTurn(sessionID: String, customAgentID: String, title: String?) async {
        await loadIfNeeded()
        let key = Self.key(customAgentID: customAgentID, sessionID: sessionID)
        guard var entry = entries[key] else { return }
        if entry.title == sessionID, let title, !title.isEmpty {
            entry.title = String(title.prefix(80))
        }
        entry.lastActivity = clock.now()
        entry.messageCount += 1
        entries[key] = entry
        await persist()
    }

    /// Append a user / thinking / assistant turn for local history replay on `session/load`.
    public func appendConversationTurn(sessionID: String,
                                       customAgentID: String,
                                       role: String,
                                       text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await appendTurn(
            sessionID: sessionID,
            customAgentID: customAgentID,
            turn: Turn(role: role, text: trimmed),
            titleFromUserText: role == "user" ? trimmed : nil
        )
    }

    /// Append a completed tool call for local history replay on `session/load`.
    public func appendToolTurn(sessionID: String,
                               customAgentID: String,
                               toolCallID: String,
                               name: String,
                               success: Bool,
                               outputSummary: String,
                               inputJSON: String?) async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        await appendTurn(
            sessionID: sessionID,
            customAgentID: customAgentID,
            turn: Turn(
                role: "tool",
                text: trimmedName,
                toolCallID: toolCallID,
                toolSuccess: success,
                toolOutputSummary: outputSummary,
                toolInputJSON: inputJSON
            ),
            titleFromUserText: nil
        )
    }

    /// Rebuild Codemixer events from the local turn cache (Cursor fallback).
    public func localHistoryEvents(sessionID: String,
                                   customAgentID: String,
                                   random: any RandomSource) async -> [AgentEvent] {
        await loadIfNeeded()
        let key = Self.key(customAgentID: customAgentID, sessionID: sessionID)
        guard let entry = entries[key] else { return [] }
        let now = clock.now()
        return entry.turns.flatMap { turn -> [AgentEvent] in
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

    public func summaries(workspace: URL, customAgentID: String) async -> [SessionSummary] {
        await loadIfNeeded()
        let path = workspace.standardizedFileURL.path
        return entries.values
            .filter { $0.workspacePath == path && $0.customAgentID == customAgentID }
            .map {
                SessionSummary(
                    id: $0.id,
                    agentID: .other,
                    workspace: workspace,
                    title: $0.title,
                    lastActivity: $0.lastActivity,
                    messageCount: $0.messageCount
                )
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    private func appendTurn(sessionID: String,
                            customAgentID: String,
                            turn: Turn,
                            titleFromUserText: String?) async {
        await loadIfNeeded()
        let key = Self.key(customAgentID: customAgentID, sessionID: sessionID)
        guard var entry = entries[key] else { return }
        entry.turns.append(turn)
        if entry.turns.count > 200 {
            entry.turns = Array(entry.turns.suffix(200))
        }
        entry.lastActivity = clock.now()
        // Sidebar count is chat turns only — thinking/tool are transcript detail.
        entry.messageCount = entry.turns.filter { $0.role == "user" || $0.role == "assistant" }.count
        if entry.title == sessionID, let titleFromUserText {
            entry.title = String(titleFromUserText.prefix(80))
        }
        entries[key] = entry
        await persist()
    }

    private static func key(customAgentID: String, sessionID: String) -> String {
        "\(customAgentID)::\(sessionID)"
    }

    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            try fileSystem.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediates: true
            )
            guard fileSystem.fileExists(at: url) else { return }
            let data = try fileSystem.readData(at: url)
            let store = try JSONDecoder().decode(Store.self, from: data)
            entries = Dictionary(
                uniqueKeysWithValues: store.entries.map {
                    (Self.key(customAgentID: $0.customAgentID, sessionID: $0.id), $0)
                }
            )
        } catch {
            await SilentDiagnostics.shared.record(
                kind: .other,
                owner: "ACPSessionIndex",
                summary: "Failed to load ACP session index",
                details: String(describing: error)
            )
        }
    }

    private func persist() async {
        do {
            let store = Store(entries: Array(entries.values))
            let data = try JSONEncoder().encode(store)
            try fileSystem.writeAtomically(data, to: url)
        } catch {
            await SilentDiagnostics.shared.record(
                kind: .other,
                owner: "ACPSessionIndex",
                summary: "Failed to persist ACP session index",
                details: String(describing: error)
            )
        }
    }
}
