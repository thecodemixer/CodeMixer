import Foundation

import AgentCore

/// Persists Codex thread metadata needed by Codemixer's resumable-session list.
///
/// Codex owns the conversation transcript; this index stores only lightweight
/// navigation metadata under Codemixer's Application Support directory.
public actor CodexThreadIndex {
    private struct Entry: Sendable, Codable {
        let id: String
        let workspacePath: String
        var title: String
        var lastActivity: Date
        var messageCount: Int
        var superseded: Bool
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
        self.url = AppSupportPaths.codexThreadsURL(
            in: environment.appSupportDirectory
        )
    }

    public func recordThread(id: String, workspace: URL) async {
        await loadIfNeeded()
        let path = workspace.standardizedFileURL.path
        let existing = entries[id]
        entries[id] = Entry(
            id: id,
            workspacePath: path,
            title: existing?.title ?? id,
            lastActivity: clock.now(),
            messageCount: existing?.messageCount ?? 0,
            superseded: false
        )
        await persist()
    }

    public func recordTurn(threadID: String, title: String?) async {
        await loadIfNeeded()
        guard var entry = entries[threadID] else { return }
        if entry.title == threadID, let title, !title.isEmpty {
            entry.title = Self.title(from: title)
        }
        entry.lastActivity = clock.now()
        entry.messageCount += 1
        entries[threadID] = entry
        await persist()
    }

    public func supersede(threadID: String) async {
        await loadIfNeeded()
        guard var entry = entries[threadID] else { return }
        entry.superseded = true
        entry.lastActivity = clock.now()
        entries[threadID] = entry
        await persist()
    }

    public func summaries(workspace: URL) async -> [SessionSummary] {
        await loadIfNeeded()
        let path = workspace.standardizedFileURL.path
        return entries.values
            .filter { $0.workspacePath == path && !$0.superseded }
            .map {
                SessionSummary(
                    id: $0.id,
                    agentID: .codex,
                    workspace: workspace,
                    title: $0.title,
                    lastActivity: $0.lastActivity,
                    messageCount: $0.messageCount
                )
            }
            .sorted { $0.lastActivity > $1.lastActivity }
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
            let store = try Self.decoder.decode(Store.self, from: data)
            entries = Dictionary(uniqueKeysWithValues: store.entries.map { ($0.id, $0) })
        } catch {
            entries = [:]
            await recordFailure("index load failed", error: error)
        }
    }

    private func persist() async {
        do {
            let ordered = entries.values.sorted { $0.id < $1.id }
            let data = try Self.encoder.encode(Store(entries: ordered))
            try fileSystem.writeAtomically(data, to: url)
        } catch {
            await recordFailure("index write failed", error: error)
        }
    }

    private func recordFailure(_ summary: String, error: any Error) async {
        await SilentDiagnostics.shared.record(
            kind: .other,
            owner: "CodexThreadIndex",
            summary: summary,
            details: CodexAgentError.persistence(
                detail: String(describing: error)
            ).detail
        )
    }

    private static func title(from prompt: String) -> String {
        let line = prompt.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? prompt
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 80
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
