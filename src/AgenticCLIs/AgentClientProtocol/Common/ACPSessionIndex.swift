import Foundation

import AgentCore

/// Persists ACP session metadata and a Codemixer-owned turn cache for the
/// resumable-session list. Cursor's `session/load` currently returns modes /
/// models without replaying history; the turn cache restores chat rows
/// (user / thinking / tool / assistant) when the agent does not stream load chunks.
///
/// Default location: app-support `acp-sessions.json`. Custom ACP adapters inject
/// `ACPProjectSessionStore` instead (project `.codemixer/acp/<id>/`).
public actor ACPSessionIndex: ACPSessionIndexing {
    private let fileSystem: any FileSystem
    private let clock: any AgentClock
    private let url: URL
    private var entries: [String: ACPSessionStoreCodec.Entry] = [:]
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
        let key = ACPSessionStoreCodec.key(customAgentID: customAgentID, sessionID: id)
        let existing = entries[key]
        entries[key] = ACPSessionStoreCodec.Entry(
            id: id,
            customAgentID: customAgentID,
            workspacePath: path,
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? existing?.title ?? id,
            lastActivity: clock.now(),
            messageCount: existing?.messageCount ?? 0,
            turns: existing?.turns ?? [],
            archived: existing?.archived,
            needsAttention: existing?.needsAttention,
            isOverview: existing?.isOverview,
            overviewURL: existing?.overviewURL
        )
        await persist()
    }

    public func recordTurn(sessionID: String, customAgentID: String, title: String?) async {
        await loadIfNeeded()
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
        await loadIfNeeded()
        let key = ACPSessionStoreCodec.key(customAgentID: customAgentID, sessionID: sessionID)
        guard let entry = entries[key] else { return [] }
        return ACPSessionStoreCodec.events(from: entry.turns, clock: clock, random: random)
    }

    public func summaries(workspace: URL, customAgentID: String) async -> [SessionSummary] {
        await loadIfNeeded()
        let path = workspace.standardizedFileURL.path
        return entries.values
            .filter {
                $0.workspacePath == path
                    && $0.customAgentID == customAgentID
                    && $0.archived != true
            }
            .map {
                SessionSummary(
                    id: $0.id,
                    agentID: .other,
                    workspace: workspace,
                    title: $0.title,
                    lastActivity: $0.lastActivity,
                    messageCount: $0.messageCount,
                    needsAttention: $0.needsAttention == true,
                    isOverview: $0.isOverview == true,
                    overviewURL: $0.overviewURL.flatMap(URL.init(string:))
                )
            }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    public func setArchived(sessionID: String, customAgentID: String, archived: Bool) async {
        await loadIfNeeded()
        let key = ACPSessionStoreCodec.key(customAgentID: customAgentID, sessionID: sessionID)
        guard var entry = entries[key] else { return }
        entry.archived = archived
        if archived {
            entry.needsAttention = false
        }
        entries[key] = entry
        await persist()
    }

    public func setNeedsAttention(sessionID: String, customAgentID: String, needsAttention: Bool) async {
        await loadIfNeeded()
        let key = ACPSessionStoreCodec.key(customAgentID: customAgentID, sessionID: sessionID)
        guard var entry = entries[key] else { return }
        entry.needsAttention = needsAttention
        entries[key] = entry
        await persist()
    }

    public func setIsOverview(sessionID: String,
                              customAgentID: String,
                              isOverview: Bool,
                              overviewURL: URL?) async {
        await loadIfNeeded()
        let key = ACPSessionStoreCodec.key(customAgentID: customAgentID, sessionID: sessionID)
        guard var entry = entries[key] else { return }
        if isOverview {
            for (otherKey, var other) in entries where otherKey != key {
                guard other.customAgentID == customAgentID,
                      other.workspacePath == entry.workspacePath else { continue }
                var changed = false
                if other.isOverview == true {
                    other.isOverview = false
                    other.overviewURL = nil
                    changed = true
                }
                if other.title == entry.title {
                    other.archived = true
                    changed = true
                }
                if changed {
                    entries[otherKey] = other
                }
            }
        }
        entry.isOverview = isOverview
        if let overviewURL {
            entry.overviewURL = overviewURL.absoluteString
        }
        entries[key] = entry
        await persist()
    }

    /// Entries matching `customAgentID` + workspace path — used when migrating
    /// to a project-local store.
    func exportEntries(customAgentID: String, workspace: URL) async -> [ACPSessionStoreCodec.Entry] {
        await loadIfNeeded()
        let path = workspace.standardizedFileURL.path
        return entries.values.filter {
            $0.customAgentID == customAgentID && $0.workspacePath == path
        }
    }

    private func appendTurn(sessionID: String,
                            customAgentID: String,
                            turn: ACPConversationTurn,
                            titleFromUserText: String?) async {
        await loadIfNeeded()
        let key = ACPSessionStoreCodec.key(customAgentID: customAgentID, sessionID: sessionID)
        // Foreign stream cache can land before `recordSession` for a reverse
        // session/new — mint a minimal entry so turns are not dropped.
        var entry = entries[key] ?? ACPSessionStoreCodec.Entry(
            id: sessionID,
            customAgentID: customAgentID,
            workspacePath: "",
            title: titleFromUserText.map { String($0.prefix(80)) } ?? sessionID,
            lastActivity: clock.now(),
            messageCount: 0,
            turns: []
        )
        entry.turns.append(turn)
        entry.turns = ACPSessionStoreCodec.trimmedTurns(entry.turns)
        entry.lastActivity = clock.now()
        entry.messageCount = ACPSessionStoreCodec.chatMessageCount(in: entry.turns)
        if entry.title == sessionID, let titleFromUserText {
            entry.title = String(titleFromUserText.prefix(80))
        }
        entries[key] = entry
        await persist()
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
            let store = try ACPSessionStoreCodec.makeDecoder()
                .decode(ACPSessionStoreCodec.Store.self, from: data)
            entries = Dictionary(
                uniqueKeysWithValues: store.entries.map {
                    (ACPSessionStoreCodec.key(customAgentID: $0.customAgentID, sessionID: $0.id), $0)
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
            let store = ACPSessionStoreCodec.Store(schemaVersion: 1, entries: Array(entries.values))
            let data = try ACPSessionStoreCodec.makeEncoder().encode(store)
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
