import Foundation
import AgentCore

/// Shared create / open / project-add paths for a workspace folder.
///
/// Bootstrap and `EngineViewModel` navigator mutations route through this type
/// so model-catalog warm always happens on one path before the UI uses a
/// newly introduced adapter.
@MainActor
public final class WorkspaceLifecycle {
    public let model: EngineViewModel

    public init(model: EngineViewModel) {
        self.model = model
    }

    /// New Workspace / Open Workspace when the folder is not itself a typed project.
    ///
    /// Reloads projects from `.codemixer/workspace.json` (or the app-support
    /// index), runs model-catalog warm, then marks the folder active. When the
    /// shell already lists projects, activates the first concrete agent project
    /// (else first folder project) so the workbench is not an empty
    /// "No workspace open" shell. With no projects yet catalog warm is a no-op;
    /// the first project add goes through `ensureModels(for:)` and probes then.
    public func openEmptyWorkspace(_ url: URL) async throws {
        try await model.adoptEmptyWorkspace(url)
        try? await model.workspaceProjects?.markActiveWorkspace(url)
        model.activateDefaultProjectIfNeeded()
    }

    /// Open / restore a workspace that has (or is seeding) projects.
    ///
    /// Sets `workspaceRoot`, reloads the project list, then warms model
    /// catalogs for every shipping adapter used by those projects. Throws if
    /// a required catalog cannot be populated — callers must not expose the
    /// workspace UI until this succeeds.
    public func loadModelCatalogs(at url: URL,
                                  rootProjectType: ProjectType? = nil) async throws {
        model.workspaceRoot = url
        await model.reloadProjects(rootProjectType: rootProjectType)
        try await model.warmWorkspaceModelCatalogs()
    }

    /// After create / add / restore project: ensure that project's adapter(s)
    /// have a non-empty model catalog before the composer uses them.
    public func ensureModels(for projectType: ProjectType) async throws {
        try await model.ensureModelsLoaded(for: projectType)
        await model.reloadWorkspaceModelCatalogStatus()
    }

    /// Clears navigator + conversation chrome after a failed open/create.
    public func abortOpen() {
        model.resetForClosedWorkspace()
    }
}
