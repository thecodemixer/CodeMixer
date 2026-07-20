import Foundation

import AgentCore

/// Project-local ACP session index + dual-write JSONL transcripts under
/// `<project>/.codemixer/acp/<customAgentID>/`.
public actor ACPProjectSessionStore: ACPSessionIndexing {
    private struct JSONLLine: Encodable {
        let v: Int
        let ts: Date
        let role: String
        let text: String
        let toolCallID: String?
        let toolSuccess: Bool?
        let toolOutputSummary: String?
        let toolInputJSON: String?
    }

    private let customAgentID: String
    private let fileSystem: any FileSystem
    private let clock: any AgentClock
    private let environment: any AgentEnvironment
    private var projectRoot: URL?
    private var entries: [String: ACPSessionStoreCodec.Entry] = [:]
    private var hasLoaded = false
    private var didAttemptMigrate = false

    public init(customAgentID: String,
                environment: any AgentEnvironment = SystemEnvironment(),
                fileSystem: any FileSystem = SystemFileSystem(),
                clock: any AgentClock = SystemClock()) {
        self.customAgentID = customAgentID
        self.environment = environment
        self.fileSystem = fileSystem
        self.clock = clock
    }

    public func recordSession(id: String,
                              customAgentID: String,
                              workspace: URL,
                              title: String?) async {
        await ensureRoot(workspace)
        let path = workspace.standardizedFileURL.path
        let key = ACPSessionStoreCodec.key(customAgentID: customAgentID, sessionID: id)
        let existing = entries[key]
        entries[key] = ACPSessionStoreCodec.Entry(
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
        guard let root = projectRoot else { return }
        await ensureRoot(root)
        let key = ACPSessionStoreCodec.key(customAgentID: customAgentID, sessionID: sessionID)
        guard var entry = entries[key] else { return }
        if entry.title == sessionID, let title, !title.isEmpty {
            entry.title = String(title.prefix(80))
        }
        entry.lastActivity = clock.now()
        entry.messageCount += 1
        entries[key] = entry
        await persist()
    }

    public func appendConversationTurn(sessionID: String,
                                       customAgentID: String,
                                       role: String,
                                       text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await appendTurn(
            sessionID: sessionID,
            customAgentID: customAgentID,
            turn: ACPConversationTurn(role: role, text: trimmed),
            titleFromUserText: role == "user" ? trimmed : nil
        )
    }

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
            turn: ACPConversationTurn(
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

    public func localHistoryEvents(sessionID: String,
                                   customAgentID: String,
                                   random: any RandomSource) async -> [AgentEvent] {
        if let root = projectRoot {
            await ensureRoot(root)
        } else {
            await loadIfNeeded()
        }
        let key = ACPSessionStoreCodec.key(customAgentID: customAgentID, sessionID: sessionID)
        guard let entry = entries[key] else { return [] }
        return ACPSessionStoreCodec.events(from: entry.turns, clock: clock, random: random)
    }

    public func summaries(workspace: URL, customAgentID: String) async -> [SessionSummary] {
        await ensureRoot(workspace)
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
                            turn: ACPConversationTurn,
                            titleFromUserText: String?) async {
        guard let root = projectRoot else { return }
        await ensureRoot(root)
        let key = ACPSessionStoreCodec.key(customAgentID: customAgentID, sessionID: sessionID)
        guard var entry = entries[key] else { return }
        entry.turns.append(turn)
        let beforeTrimCount = entry.turns.count
        entry.turns = ACPSessionStoreCodec.trimmedTurns(entry.turns)
        let didTrim = entry.turns.count < beforeTrimCount
        entry.lastActivity = clock.now()
        entry.messageCount = ACPSessionStoreCodec.chatMessageCount(in: entry.turns)
        if entry.title == sessionID, let titleFromUserText {
            entry.title = String(titleFromUserText.prefix(80))
        }
        entries[key] = entry
        await persist()
        if didTrim {
            await rewriteJSONL(sessionID: sessionID, turns: entry.turns, projectRoot: root)
        } else {
            await appendJSONL(sessionID: sessionID, turn: turn, projectRoot: root)
        }
    }

    private func ensureRoot(_ workspace: URL) async {
        let root = workspace.standardizedFileURL
        if projectRoot != root {
            projectRoot = root
            hasLoaded = false
            didAttemptMigrate = false
            entries = [:]
        }
        await loadIfNeeded()
    }

    private func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let root = projectRoot else { return }
        let indexURL = ACPProjectPaths.sessionsIndexURL(
            projectRoot: root,
            customAgentID: customAgentID
        )
        do {
            try fileSystem.createDirectory(
                at: indexURL.deletingLastPathComponent(),
                withIntermediates: true
            )
            if fileSystem.fileExists(at: indexURL) {
                let data = try fileSystem.readData(at: indexURL)
                let store = try ACPSessionStoreCodec.makeDecoder()
                    .decode(ACPSessionStoreCodec.Store.self, from: data)
                entries = Dictionary(
                    uniqueKeysWithValues: store.entries.map {
                        (ACPSessionStoreCodec.key(customAgentID: $0.customAgentID, sessionID: $0.id), $0)
                    }
                )
            }
        } catch {
            await SilentDiagnostics.shared.record(
                kind: .other,
                owner: "ACPProjectSessionStore",
                summary: "Failed to load project ACP session index",
                details: String(describing: error)
            )
        }
        await migrateFromAppSupportIfNeeded(projectRoot: root)
    }

    private func migrateFromAppSupportIfNeeded(projectRoot: URL) async {
        guard !didAttemptMigrate else { return }
        didAttemptMigrate = true
        guard entries.isEmpty else { return }
        let legacy = ACPSessionIndex(
            environment: environment,
            fileSystem: fileSystem,
            clock: clock
        )
        let migrated = await legacy.exportEntries(
            customAgentID: customAgentID,
            workspace: projectRoot
        )
        guard !migrated.isEmpty else { return }
        for entry in migrated {
            let key = ACPSessionStoreCodec.key(
                customAgentID: entry.customAgentID,
                sessionID: entry.id
            )
            entries[key] = entry
            await rewriteJSONL(
                sessionID: entry.id,
                turns: entry.turns,
                projectRoot: projectRoot
            )
        }
        await persist()
    }

    private func persist() async {
        guard let root = projectRoot else { return }
        let indexURL = ACPProjectPaths.sessionsIndexURL(
            projectRoot: root,
            customAgentID: customAgentID
        )
        do {
            try fileSystem.createDirectory(
                at: indexURL.deletingLastPathComponent(),
                withIntermediates: true
            )
            let store = ACPSessionStoreCodec.Store(schemaVersion: 1, entries: Array(entries.values))
            let data = try ACPSessionStoreCodec.makeEncoder().encode(store)
            try fileSystem.writeAtomically(data, to: indexURL)
        } catch {
            await SilentDiagnostics.shared.record(
                kind: .other,
                owner: "ACPProjectSessionStore",
                summary: "Failed to persist project ACP session index",
                details: String(describing: error)
            )
        }
    }

    private func appendJSONL(sessionID: String,
                             turn: ACPConversationTurn,
                             projectRoot: URL) async {
        let url = ACPProjectPaths.transcriptURL(
            projectRoot: projectRoot,
            customAgentID: customAgentID,
            sessionID: sessionID
        )
        do {
            try fileSystem.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediates: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.dateEncodingStrategy = .iso8601
            let line = JSONLLine(
                v: 1,
                ts: clock.now(),
                role: turn.role,
                text: turn.text,
                toolCallID: turn.toolCallID,
                toolSuccess: turn.toolSuccess,
                toolOutputSummary: turn.toolOutputSummary,
                toolInputJSON: turn.toolInputJSON
            )
            var data = try encoder.encode(line)
            data.append(contentsOf: "\n".utf8)
            if fileSystem.fileExists(at: url) {
                var existing = try fileSystem.readData(at: url)
                existing.append(data)
                try fileSystem.writeAtomically(existing, to: url)
            } else {
                try fileSystem.writeAtomically(data, to: url)
            }
        } catch {
            await SilentDiagnostics.shared.record(
                kind: .other,
                owner: "ACPProjectSessionStore",
                summary: "Failed to append ACP transcript JSONL",
                details: String(describing: error)
            )
        }
    }

    private func rewriteJSONL(sessionID: String,
                              turns: [ACPConversationTurn],
                              projectRoot: URL) async {
        let url = ACPProjectPaths.transcriptURL(
            projectRoot: projectRoot,
            customAgentID: customAgentID,
            sessionID: sessionID
        )
        do {
            try fileSystem.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediates: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            encoder.dateEncodingStrategy = .iso8601
            var data = Data()
            let now = clock.now()
            for turn in turns {
                let line = JSONLLine(
                    v: 1,
                    ts: now,
                    role: turn.role,
                    text: turn.text,
                    toolCallID: turn.toolCallID,
                    toolSuccess: turn.toolSuccess,
                    toolOutputSummary: turn.toolOutputSummary,
                    toolInputJSON: turn.toolInputJSON
                )
                data.append(try encoder.encode(line))
                data.append(contentsOf: "\n".utf8)
            }
            try fileSystem.writeAtomically(data, to: url)
        } catch {
            await SilentDiagnostics.shared.record(
                kind: .other,
                owner: "ACPProjectSessionStore",
                summary: "Failed to rewrite ACP transcript JSONL",
                details: String(describing: error)
            )
        }
    }
}
