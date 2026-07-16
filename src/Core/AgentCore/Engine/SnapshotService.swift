import Foundation
import AgentProtocol

/// Builds JSON snapshot payloads for `AgentCommand.requestSnapshot(_:)`.
///
/// Each `SnapshotKind` maps to a small, well-typed Codable struct. Callers
/// (UI + remote server) receive raw `Data` ready to send over the wire.
public actor SnapshotService {

    public struct ConversationSnapshot: Sendable, Codable {
        public let sessionID: String?
        public let messages: [SnapshotMessage]
    }

    public struct SnapshotMessage: Sendable, Codable {
        public let role: String
        public let text: String
        public let timestamp: Date
    }

    public struct DiffSnapshot: Sendable, Codable {
        public let changedFiles: [String]
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
                         conversation: [(role: String, text: String, timestamp: Date)] = [],
                         sessionID: String? = nil,
                         changedFiles: [String] = [],
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
