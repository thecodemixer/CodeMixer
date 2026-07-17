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

    /// New Workspace / reopen of an empty workspace shell.
    ///
    /// Marks the folder active, resets navigator chrome, reloads projects, and
    /// runs model-catalog warm. With no projects yet this warm is a no-op;
    /// the first project add goes through `ensureModels(for:)` and probes then.
    public func openEmptyWorkspace(_ url: URL) async throws {
        try? await model.workspaceProjects?.markActiveWorkspace(url)
        try await model.adoptEmptyWorkspace(url)
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
