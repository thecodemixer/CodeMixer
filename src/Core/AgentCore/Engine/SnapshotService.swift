import Foundation
import AgentProtocol

/// Builds JSON snapshot payloads for `AgentCommand.requestSnapshot(_:)`.
///
/// Each `SnapshotKind` maps to a small, well-typed Codable struct. Callers
/// (UI + remote server) receive raw `Data` ready to send over the wire.
public actor SnapshotService {

    public enum TranscriptRole: String, Sendable, Codable, Hashable {
        case user
        case assistant
        case action
    }

    public struct ConversationSnapshot: Sendable, Codable {
        public let sessionID: String?
        public let messages: [SnapshotMessage]
    }

    public struct SnapshotMessage: Sendable, Codable {
        public let role: TranscriptRole
        public let text: String
        public let timestamp: Date

        public init(role: TranscriptRole, text: String, timestamp: Date) {
            self.role = role
            self.text = text
            self.timestamp = timestamp
        }
    }

    public struct DiffSnapshot: Sendable, Codable {
        public let changedFiles: [ChangedFile]

        public init(changedFiles: [ChangedFile]) {
            self.changedFiles = changedFiles
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let paths = try container.decode([String].self, forKey: .changedFiles)
            changedFiles = paths.map { ChangedFile(relativePath: $0) }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(changedFiles.map(\.relativePath), forKey: .changedFiles)
        }

        private enum CodingKeys: String, CodingKey {
            case changedFiles
        }
    }

    public struct SessionsSnapshot: Sendable, Codable {
        public let recents: [SessionStore.ProjectRecord]
    }

    public struct PrefsSnapshot: Sendable, Codable {
        public let appearance: AppearancePrefs
        public let autoApprovalRules: [AutoApprovalRule]
    }

    private let prefs: PrefsStore
    private let sessions: SessionStore
    private let encoder: JSONEncoder

    public init(prefs: PrefsStore,
                sessions: SessionStore) {
        self.prefs = prefs
        self.sessions = sessions
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        self.encoder = e
    }

    public func snapshot(_ kind: SnapshotKind,
                         conversation: [(role: TranscriptRole, text: String, timestamp: Date)] = [],
                         sessionID: String? = nil,
                         changedFiles: [ChangedFile] = [],
                         workspace: URL? = nil) async -> Data {
        switch kind {
        case .conversation:
            let snap = ConversationSnapshot(
                sessionID: sessionID,
                messages: conversation.map { SnapshotMessage(role: $0.role,
                                                             text: $0.text,
                                                             timestamp: $0.timestamp) }
            )
            return (try? encoder.encode(snap)) ?? Data()
        case .diff:
            return (try? encoder.encode(DiffSnapshot(changedFiles: changedFiles))) ?? Data()
        case .sessions:
            let recents = await sessions.recents()
            return (try? encoder.encode(SessionsSnapshot(recents: recents))) ?? Data()
        case .prefs:
            let state = await prefs.state()
            let snap = PrefsSnapshot(appearance: state.appearance,
                                     autoApprovalRules: state.autoApprovalRules)
            return (try? encoder.encode(snap)) ?? Data()
        }
    }
}
