import Foundation

import AgentCore

/// Persists ACP session metadata for Codemixer's resumable-session list.
public actor ACPSessionIndex {
    private struct Entry: Sendable, Codable {
        let id: String
        let customAgentID: String
        let workspacePath: String
        var title: String
        var lastActivity: Date
        var messageCount: Int
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
            messageCount: existing?.messageCount ?? 0
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
