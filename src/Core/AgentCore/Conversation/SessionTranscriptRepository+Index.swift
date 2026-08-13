/// Projects transcript mutations into the project session index used by the
/// sidebar and mixed-agent routing.
import Foundation

extension SessionTranscriptRepository {
    func sessions(inProject root: URL,
                  attentionSessionIDs: Set<String> = []) throws -> [SessionSummary] {
        try indexRecords(in: root)
            .sorted { $0.lastActivity > $1.lastActivity }
            .map {
                $0.summary(in: root.standardizedFileURL,
                           needsAttention: attentionSessionIDs.contains($0.sessionID)
                               && !$0.archived)
            }
    }

    func records(forSessionID sessionID: String,
                 inProject root: URL) throws -> [StoredSessionRecord] {
        try indexRecords(in: root)
            .filter { $0.sessionID == sessionID }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    func registerSession(_ id: String,
                         namespace: String,
                         agentID: AgentID,
                         in root: URL,
                         title: String? = nil,
                         gitBranch: String? = nil,
                         historyImportState: HistoryImportState? = nil) throws {
        var records = try indexRecords(in: root)
        let now = clock.now()
        if let index = records.firstIndex(where: {
            $0.sessionID == id && $0.namespace == namespace
        }) {
            if let title, !title.isEmpty {
                records[index].title = SessionTitle.from(firstUserText: title)
            }
            records[index].gitBranch = gitBranch ?? records[index].gitBranch
            if let historyImportState {
                records[index].historyImportState = historyImportState
            }
        } else {
            records.append(.init(sessionID: id,
                                 namespace: namespace,
                                 agentID: agentID,
                                 title: SessionTitle.from(firstUserText: title),
                                 createdAt: now,
                                 lastActivity: now,
                                 userTurnCount: 0,
                                 gitBranch: gitBranch,
                                 isOverview: false,
                                 overviewURL: nil,
                                 archived: false,
                                 supersededAt: nil,
                                 historyImportState: historyImportState ?? .notNeeded))
        }
        try persist(records, in: root)
    }

    func importCatalog(_ sessions: [ImportedSession],
                       namespace: String,
                       agentID: AgentID,
                       into root: URL,
                       changedFileRoot: URL? = nil) throws {
        var records = try indexRecords(in: root)
        let now = clock.now()
        for session in sessions {
            let key = SessionTranscriptKey(projectRoot: root,
                                           namespace: namespace,
                                           sessionID: session.id)
            let transcript = try recordImported(session.events,
                                                for: key,
                                                changedFileRoot: changedFileRoot)
            let existingIndex = records.firstIndex(where: {
                $0.sessionID == session.id && $0.namespace == namespace
            })
            let existing = existingIndex.map { records[$0] }
            let record = importedRecord(for: session,
                                        namespace: namespace,
                                        agentID: agentID,
                                        transcript: transcript,
                                        existing: existing,
                                        now: now)
            if let existingIndex {
                records[existingIndex] = record
            } else {
                records.append(record)
            }
            try evict(key)
        }
        try persist(records, in: root)
    }

    func markImportFailed(_ id: String,
                          namespace: String,
                          agentID: AgentID,
                          in root: URL) throws {
        try registerSession(id,
                            namespace: namespace,
                            agentID: agentID,
                            in: root,
                            historyImportState: .importFailed)
    }

    func markOverview(_ id: String, isOverview: Bool, url: URL?, in root: URL) throws {
        var records = try indexRecords(in: root)
        guard let target = records.firstIndex(where: { $0.sessionID == id }) else {
            return
        }
        let targetAgent = records[target].agentID
        let targetTitle = records[target].title
        for index in records.indices {
            if records[index].agentID == targetAgent, isOverview {
                records[index].isOverview = index == target
                if index != target, records[index].title == targetTitle {
                    records[index].archived = true
                }
            }
        }
        records[target].isOverview = isOverview
        records[target].overviewURL = isOverview ? url : nil
        try persist(records, in: root)
    }

    func markArchived(_ id: String, archived: Bool, in root: URL) throws {
        try mutateRecord(id: id, in: root) {
            $0.archived = archived
        }
    }

    func markSuperseded(_ id: String, in root: URL) throws {
        let now = clock.now()
        try mutateRecord(id: id, in: root) {
            $0.supersededAt = now
        }
    }

    func deleteSession(_ id: String,
                       namespace: String,
                       in root: URL) throws {
        var records = try indexRecords(in: root)
        records.removeAll { $0.sessionID == id && $0.namespace == namespace }
        let key = SessionTranscriptKey(projectRoot: root,
                                       namespace: namespace,
                                       sessionID: id)
        try evict(key)
        try store.deleteJournal(for: key)
        try persist(records, in: root)
    }

    func catalogImportState(in root: URL) throws -> CatalogImportState {
        let path = standardizedPath(root)
        if let state = catalogStates[path] { return state }
        let state = try store.loadCatalogImportState(in: root)
        catalogStates[path] = state
        return state
    }

    func setCatalogImportState(_ state: CatalogImportState, in root: URL) throws {
        catalogStates[standardizedPath(root)] = state
        try store.writeCatalogImportState(state, in: root)
    }

    func updateIndex(for key: SessionTranscriptKey,
                     transcript: SessionTranscript,
                     accepted: [TranscriptMutation]) throws {
        var records = try indexRecords(in: key.projectRoot)
        let index: Int
        if let existing = records.firstIndex(where: {
            $0.sessionID == key.sessionID && $0.namespace == key.namespace
        }) {
            index = existing
        } else {
            let createdAt = accepted.first?.recordedAt ?? clock.now()
            records.append(.init(sessionID: key.sessionID,
                                 namespace: key.namespace,
                                 agentID: AgentID(rawValue: key.namespace) ?? .other,
                                 title: SessionTitle.untitled,
                                 createdAt: createdAt,
                                 lastActivity: createdAt,
                                 userTurnCount: 0,
                                 gitBranch: nil,
                                 isOverview: false,
                                 overviewURL: nil,
                                 archived: false,
                                 supersededAt: nil,
                                 historyImportState: .notNeeded))
            index = records.count - 1
        }
        records[index].lastActivity = accepted.map(\.recordedAt).max()
            ?? records[index].lastActivity
        let users = transcript.entries.compactMap { entry -> String? in
            if case .user(_, let text) = entry.block { return text }
            return nil
        }
        records[index].userTurnCount = users.count
        if records[index].title == SessionTitle.untitled, let first = users.first {
            records[index].title = SessionTitle.from(firstUserText: first)
        }
        try persist(records, in: key.projectRoot)
    }

    private func indexRecords(in root: URL) throws -> [StoredSessionRecord] {
        let path = standardizedPath(root)
        if let records = indexes[path] { return records }
        let records = try store.loadIndex(in: root)
        indexes[path] = records
        return records
    }

    private func persist(_ records: [StoredSessionRecord], in root: URL) throws {
        let sorted = records.sorted { $0.lastActivity > $1.lastActivity }
        indexes[standardizedPath(root)] = sorted
        try store.writeIndex(sorted, in: root)
    }

    private func mutateRecord(id: String,
                              in root: URL,
                              mutation: (inout StoredSessionRecord) -> Void) throws {
        var records = try indexRecords(in: root)
        guard let index = records.firstIndex(where: { $0.sessionID == id }) else {
            return
        }
        mutation(&records[index])
        try persist(records, in: root)
    }

    private func importedRecord(for session: ImportedSession,
                                namespace: String,
                                agentID: AgentID,
                                transcript: SessionTranscript,
                                existing: StoredSessionRecord?,
                                now: Date) -> StoredSessionRecord {
        let firstUserText = transcript.entries.lazy.compactMap { entry -> String? in
            if case .user(_, let text) = entry.block { return text }
            return nil
        }.first
        let recordedActivity = transcript.entries.map(\.recordedAt).max()
        let title = session.title ?? firstUserText ?? existing?.title
        return StoredSessionRecord(
            sessionID: session.id,
            namespace: namespace,
            agentID: agentID,
            title: SessionTitle.from(firstUserText: title),
            createdAt: existing?.createdAt ?? session.lastActivity ?? recordedActivity ?? now,
            lastActivity: session.lastActivity ?? recordedActivity ?? existing?.lastActivity ?? now,
            userTurnCount: transcript.entries.reduce(into: 0) { count, entry in
                if case .user = entry.block { count += 1 }
            },
            gitBranch: session.gitBranch ?? existing?.gitBranch,
            isOverview: session.isOverview,
            overviewURL: session.overviewURL,
            archived: session.archived,
            supersededAt: existing?.supersededAt,
            historyImportState: .imported
        )
    }

    private func standardizedPath(_ root: URL) -> String {
        root.standardizedFileURL.path
    }
}
