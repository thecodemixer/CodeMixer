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

    public struct WorkspaceTreeSnapshot: Sendable, Codable {
        public let root: String
        public let entries: [String]
    }

    public struct PrefsSnapshot: Sendable, Codable {
        public let appearance: AppearancePrefs
        public let autoApprovalRules: [AutoApprovalRule]
    }

    private let prefs: PrefsStore
    private let sessions: SessionStore
    private let fileSystem: any FileSystem
    private let processRunner: ProcessRunner
    private let encoder: JSONEncoder

    public init(prefs: PrefsStore,
                sessions: SessionStore,
                fileSystem: any FileSystem = SystemFileSystem(),
                processRunner: ProcessRunner = ProcessRunner()) {
        self.prefs = prefs
        self.sessions = sessions
        self.fileSystem = fileSystem
        self.processRunner = processRunner
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
        case .workspaceTree:
            let snap = WorkspaceTreeSnapshot(
                root: workspace?.path ?? "",
                entries: await gitTrackedTopLevel(workspace: workspace)
            )
            return (try? encoder.encode(snap)) ?? Data()
        case .prefs:
            let state = await prefs.state()
            let snap = PrefsSnapshot(appearance: state.appearance,
                                     autoApprovalRules: state.autoApprovalRules)
            return (try? encoder.encode(snap)) ?? Data()
        }
    }

    /// Returns the gitignore-filtered list of top-level path components for
    /// the given workspace. Uses `git ls-files` (tracked + untracked-but-not-
    /// ignored) so remote clients get an accurate file tree without needing to
    /// enumerate the whole directory. Falls back to a direct directory listing
    /// when git is unavailable or the directory is not a git repository.
    private func gitTrackedTopLevel(workspace: URL?) async -> [String] {
        guard let workspace else { return [] }

        let git = SystemPaths.git
        if let result = try? await processRunner.run(
            executable: git,
            arguments: ["ls-files", "--cached", "--others", "--exclude-standard"],
            cwd: workspace
        ) {
            let text = String(data: result.stdout, encoding: .utf8) ?? ""
            if !text.isEmpty {
                let topLevel = text
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { String($0.split(separator: "/", maxSplits: 1).first ?? $0) }
                return Array(Set(topLevel)).sorted()
            }
        }

        // Fallback: plain directory listing for non-git workspaces.
        guard let entries = try? fileSystem.contentsOfDirectory(at: workspace) else { return [] }
        return entries.map { $0.lastPathComponent }.sorted()
    }
}
