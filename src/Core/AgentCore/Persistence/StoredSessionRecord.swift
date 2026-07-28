/// Defines the private persistence records for project-local transcript
/// journals and their rebuildable session index.
import Foundation

struct StoredSessionRecord: Sendable, Codable, Equatable {
    let sessionID: String
    let namespace: String
    let agentID: AgentID
    var title: String
    var createdAt: Date
    var lastActivity: Date
    var userTurnCount: Int
    var gitBranch: String?
    var isOverview: Bool
    var overviewURL: URL?
    var archived: Bool
    var supersededAt: Date?
    var historyImportState: HistoryImportState

    func summary(in projectRoot: URL, needsAttention: Bool = false) -> SessionSummary {
        SessionSummary(id: sessionID,
                       agentID: agentID,
                       workspace: projectRoot,
                       title: title,
                       lastActivity: lastActivity,
                       messageCount: userTurnCount,
                       gitBranch: gitBranch,
                       needsAttention: needsAttention,
                       isOverview: isOverview,
                       overviewURL: overviewURL,
                       archived: archived,
                       supersededAt: supersededAt,
                       historyImportState: historyImportState)
    }
}

enum CatalogImportState: Sendable, Codable, Equatable {
    case notNeeded
    case pending
    case completed(at: Date)
    case partial(at: Date)
}

struct StoredSessionIndex: Sendable, Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var catalogImportState: CatalogImportState
    var sessions: [StoredSessionRecord]

    init(catalogImportState: CatalogImportState = .notNeeded,
         sessions: [StoredSessionRecord] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.catalogImportState = catalogImportState
        self.sessions = sessions
    }
}

enum StoredTranscriptRecord: Sendable, Codable, Equatable {
    case header(StoredTranscriptHeader)
    case mutation(TranscriptMutation)
}

struct StoredTranscriptHeader: Sendable, Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let sessionID: String

    init(sessionID: String) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID
    }
}

struct TranscriptWriteLock: Sendable, Equatable {
    let url: URL
}
