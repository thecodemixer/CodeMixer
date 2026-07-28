/// Rebuilds and atomically persists the project session index. Journal scans
/// are recovery-only; normal listing reads one index file.
import Foundation

extension ProjectSessionTranscriptStore {
    func loadIndex(in root: URL) throws -> [StoredSessionRecord] {
        try loadStoredIndex(in: root).sessions
    }

    func loadCatalogImportState(in root: URL) throws -> CatalogImportState {
        try loadStoredIndex(in: root).catalogImportState
    }

    func writeIndex(_ records: [StoredSessionRecord], in root: URL) throws {
        var index = try loadStoredIndex(in: root)
        index.sessions = records
        try writeStoredIndex(index, in: root)
    }

    func writeCatalogImportState(_ state: CatalogImportState, in root: URL) throws {
        var index = try loadStoredIndex(in: root)
        index.catalogImportState = state
        try writeStoredIndex(index, in: root)
    }

    func rebuildIndex(in root: URL) throws -> [StoredSessionRecord] {
        let history = ProjectPaths.historyDirectoryURL(in: root)
        guard fileSystem.isDirectory(at: history) else { return [] }
        var records: [StoredSessionRecord] = []
        for namespaceDirectory in try fileSystem.contentsOfDirectory(at: history)
            where fileSystem.isDirectory(at: namespaceDirectory) {
            guard let namespace = decodeBase64URL(namespaceDirectory.lastPathComponent) else {
                continue
            }
            let agentID = AgentID(rawValue: namespace) ?? .other
            for journal in try fileSystem.contentsOfDirectory(at: namespaceDirectory)
                where journal.pathExtension == "jsonl" {
                do {
                    if let record = try rebuiltRecord(journal: journal,
                                                      root: root,
                                                      namespace: namespace,
                                                      agentID: agentID) {
                        records.append(record)
                    }
                } catch {
                    log.error("Skipped unreadable transcript path=\(journal.path, privacy: .private)")
                }
            }
        }
        records.sort { $0.lastActivity > $1.lastActivity }
        try writeStoredIndex(.init(sessions: records), in: root)
        return records
    }

    private func loadStoredIndex(in root: URL) throws -> StoredSessionIndex {
        let url = ProjectPaths.historyIndexURL(in: root)
        guard fileSystem.fileExists(at: url) else {
            return .init()
        }
        do {
            return try decoder.decode(StoredSessionIndex.self,
                                      from: fileSystem.readData(at: url))
        } catch {
            let records = try rebuildIndexWithoutWriting(in: root)
            let index = StoredSessionIndex(sessions: records)
            try writeStoredIndex(index, in: root)
            return index
        }
    }

    private func writeStoredIndex(_ index: StoredSessionIndex, in root: URL) throws {
        let history = ProjectPaths.historyDirectoryURL(in: root)
        if !fileSystem.isDirectory(at: history) {
            try fileSystem.createDirectory(at: history, withIntermediates: true)
        }
        let ignore = ProjectPaths.historyIgnoreURL(in: root)
        if !fileSystem.fileExists(at: ignore) {
            try fileSystem.createExclusively(Data("*\n".utf8), at: ignore)
        }
        try fileSystem.writeAtomically(try encoder.encode(index),
                                       to: ProjectPaths.historyIndexURL(in: root))
    }

    private func rebuildIndexWithoutWriting(in root: URL) throws -> [StoredSessionRecord] {
        let history = ProjectPaths.historyDirectoryURL(in: root)
        guard fileSystem.isDirectory(at: history) else { return [] }
        var records: [StoredSessionRecord] = []
        for namespaceDirectory in try fileSystem.contentsOfDirectory(at: history)
            where fileSystem.isDirectory(at: namespaceDirectory) {
            guard let namespace = decodeBase64URL(namespaceDirectory.lastPathComponent) else {
                continue
            }
            let agentID = AgentID(rawValue: namespace) ?? .other
            for journal in try fileSystem.contentsOfDirectory(at: namespaceDirectory)
                where journal.pathExtension == "jsonl" {
                do {
                    if let record = try rebuiltRecord(journal: journal,
                                                      root: root,
                                                      namespace: namespace,
                                                      agentID: agentID) {
                        records.append(record)
                    }
                } catch {
                    log.error("Skipped unreadable transcript path=\(journal.path, privacy: .private)")
                }
            }
        }
        return records.sorted { $0.lastActivity > $1.lastActivity }
    }

    private func rebuiltRecord(journal: URL,
                               root: URL,
                               namespace: String,
                               agentID: AgentID) throws -> StoredSessionRecord? {
        let data = try fileSystem.readData(at: journal)
        guard let first = data.split(separator: 0x0A).first,
              case .header(let header) = try decoder.decode(
                  StoredTranscriptRecord.self,
                  from: Data(first)
              ) else {
            return nil
        }
        let key = SessionTranscriptKey(projectRoot: root,
                                       namespace: namespace,
                                       sessionID: header.sessionID)
        let mutations = try loadMutations(for: key)
        let fallbackDate = try fileSystem.modificationDate(at: journal)
        let createdAt = mutations.first?.recordedAt ?? fallbackDate
        let lastActivity = mutations.last?.recordedAt ?? fallbackDate
        let users = mutations.compactMap { mutation -> String? in
            if case .appendUser(_, let text, _) = mutation { return text }
            return nil
        }
        return StoredSessionRecord(sessionID: header.sessionID,
                                   namespace: namespace,
                                   agentID: agentID,
                                   title: SessionTitle.from(firstUserText: users.first),
                                   createdAt: createdAt,
                                   lastActivity: lastActivity,
                                   userTurnCount: users.count,
                                   gitBranch: nil,
                                   isOverview: false,
                                   overviewURL: nil,
                                   archived: false,
                                   supersededAt: nil,
                                   historyImportState: .notNeeded)
    }

    private func decodeBase64URL(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
