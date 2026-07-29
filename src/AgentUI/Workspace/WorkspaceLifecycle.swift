import Foundation
import AgentCore

/// Shared create / open / project-add paths for a workspace folder.
///
/// Bootstrap and `EngineViewModel` navigator mutations route through this type
/// so model-catalog warm always happens on one path. Per-adapter failures are
/// recorded so ready projects stay usable while broken ones land under Not loaded.
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
    /// shell already lists projects, activates the first ready concrete agent
    /// project (else first folder project) so the workbench is not an empty
    /// "No workspace open" shell. Adapters that fail catalog warm leave their
    /// projects under Not loaded; siblings stay usable. With no projects yet
    /// catalog warm is a no-op; the first project add goes through
    /// `ensureModels(for:)` and probes then.
    public func openEmptyWorkspace(_ url: URL) async {
        await model.adoptEmptyWorkspace(url)
        try? await model.workspaceProjects?.markActiveWorkspace(url)
        model.activateDefaultProjectIfNeeded()
    }

    /// Open / restore a workspace that has (or is seeding) projects.
    ///
    /// Sets `workspaceRoot`, reloads the project list, then warms model
    /// catalogs for every shipping adapter used by those projects. Catalog
    /// failures are recorded per adapter — the workspace UI still opens so
    /// ready projects remain usable.
    public func loadModelCatalogs(at url: URL,
                                  rootProjectType: ProjectType? = nil) async {
        model.workspaceRoot = url
        await model.reloadProjects(rootProjectType: rootProjectType)
        await model.warmWorkspaceModelCatalogs()
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
