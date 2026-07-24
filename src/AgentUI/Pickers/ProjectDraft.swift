import Foundation
import AgentCore

/// Sheet-collected draft for creating or adopting a project (New / Configure /
/// Add Existing / Open Project).
///
/// Distinct from `WorkspaceProjectsStore.ProjectRef`: this is the UI form
/// payload *before* registration; `ProjectRef` is the persisted store record
/// *after* create/add (required `projectType`, stable `path`,
/// `agentInstanceIdentity`). Do not merge them — Open Project often has a
/// folder URL with type still unknown, which a stored ref must never allow.
///
/// Call sites pass one value instead of a growing parallel argument list;
/// successful mutations return a `ProjectRef`.
public struct ProjectDraft: Sendable, Hashable {
    public var name: String
    /// Nil when Open Project has chosen a folder but type is not resolved yet
    /// (configure sheet or project-local state still pending).
    public var projectType: ProjectType?
    public var preferFreshAgentProcess: Bool
    /// When set, register/open this existing folder instead of creating
    /// `<workspace>/<name>/`.
    public var existingFolderURL: URL?

    public init(name: String,
                projectType: ProjectType? = nil,
                preferFreshAgentProcess: Bool = false,
                existingFolderURL: URL? = nil) {
        self.name = name
        self.projectType = projectType
        self.preferFreshAgentProcess = preferFreshAgentProcess
        self.existingFolderURL = existingFolderURL
    }

    /// Open / Add Existing: folder chosen, type may still be unknown.
    public static func existingFolder(_ url: URL,
                                      preferFreshAgentProcess: Bool = false) -> ProjectDraft {
        ProjectDraft(
            name: url.lastPathComponent,
            preferFreshAgentProcess: preferFreshAgentProcess,
            existingFolderURL: url
        )
    }

    public func withProjectType(_ type: ProjectType) -> ProjectDraft {
        var copy = self
        copy.projectType = type
        return copy
    }
}
