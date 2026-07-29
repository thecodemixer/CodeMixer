import Foundation
import AgentCore
import AgentProtocol

extension EngineViewModel {
    public func applyAdapterCapabilities(for projectType: ProjectType, projectURL: URL? = nil) {
        let url = projectURL ?? workspace
        let expectedPath = url.map {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path
        }
        adapterCapabilitiesGeneration += 1
        let generation = adapterCapabilitiesGeneration
        Task { [weak self] in
            guard let self else { return }
            guard let adapter = await ProjectAgentRouter.resolveAdapter(projectType: projectType) else {
                await MainActor.run {
                    guard self.shouldApplyAdapterCapabilities(
                        generation: generation,
                        expectedPath: expectedPath
                    ) else { return }
                    self.availableModels = []
                    self.availableAgentModes = []
                    self.selectedAgentModeID = ""
                    self.supportsResumableSessions = false
                    self.slashCommands = []
                }
                return
            }
            let models: [AgentModelOption]
            do {
                models = try await self.loadModels(for: adapter)
            } catch {
                await MainActor.run {
                    guard self.shouldApplyAdapterCapabilities(
                        generation: generation,
                        expectedPath: expectedPath
                    ) else { return }
                    self.diagnostics.append(self.diagnostic(
                        level: .error,
                        message: error.localizedDescription
                    ))
                    self.availableModels = []
                }
                return
            }
            let agentModes = adapter.availableAgentModes()
            let resumable = adapter.capabilities.contains(.resumableSessions)
            let builtIn = adapter.slashCommandCatalog
            let projectCommands: [SlashCommand]
            if let url {
                projectCommands = await adapter.enumerateProjectCommands(workspace: url)
            } else {
                projectCommands = []
            }
            await MainActor.run {
                guard self.shouldApplyAdapterCapabilities(
                    generation: generation,
                    expectedPath: expectedPath
                ) else { return }
                self.availableModels = models
                self.availableAgentModes = agentModes
                if agentModes.contains(where: { $0.id == self.selectedAgentModeID }) {
                    // Keep the user's selection when the adapter still offers it.
                } else {
                    self.selectedAgentModeID = agentModes.first?.id ?? ""
                }
                self.supportsResumableSessions = resumable
                self.slashCommands = builtIn + projectCommands
            }
        }
    }

    /// Loads model catalogs for every shipping adapter used by projects in this
    /// workspace. Catalogs are read from per-adapter workspace files when
    /// fresh enough; otherwise adapters are probed and the result is persisted.
    ///
    /// Failures are recorded per adapter in `modelCatalogLoadFailures` instead
    /// of aborting the workspace open — sibling projects whose adapters
    /// succeeded stay usable.
    public func warmWorkspaceModelCatalogs() async {
        guard workspaceRoot != nil, workspaceProjects != nil else {
            workspaceModelCatalogRows = []
            modelCatalogLoadFailures = [:]
            return
        }
        var failures: [AgentID: String] = [:]
        let agentIDs = Self.modelCatalogAgentIDs(in: projects)
        for agentID in agentIDs {
            do {
                try await ensureModelsLoaded(for: agentID)
            } catch {
                failures[agentID] = Self.modelCatalogFailureMessage(for: error)
            }
        }
        modelCatalogLoadFailures = failures
        await reloadWorkspaceModelCatalogStatus()
    }

    /// Projects whose required shipping model catalogs are ready.
    public var loadedProjects: [WorkspaceProjectsStore.ProjectRef] {
        projects.filter { isProjectModelCatalogReady($0) }
    }

    /// Projects blocked because a required adapter's model catalog failed.
    public var unloadedProjects: [WorkspaceProjectsStore.ProjectRef] {
        projects.filter { !isProjectModelCatalogReady($0) }
    }

    /// Whether this project can be opened given current catalog failures.
    ///
    /// Pinned single-agent projects require that agent's catalog. Mixed
    /// projects require the catalog for their *default* agent (the adapter
    /// `ProjectAgentRouter` would spawn on New Chat) — sibling shipping
    /// adapters that failed stay unavailable until refreshed but do not park
    /// the whole mixed project under Not loaded. Custom / folder projects
    /// never require a shipping catalog.
    public func isProjectModelCatalogReady(_ project: WorkspaceProjectsStore.ProjectRef) -> Bool {
        modelCatalogFailureMessage(for: project) == nil
    }

    /// User-facing reason a project is under Not loaded, or `nil` when ready.
    public func modelCatalogFailureMessage(
        for project: WorkspaceProjectsStore.ProjectRef
    ) -> String? {
        let ids = Self.modelCatalogAgentIDs(for: project.projectType)
        guard !ids.isEmpty else { return nil }
        switch project.projectType {
        case .mixed(let defaultAgent):
            if let openID = defaultAgent {
                return modelCatalogLoadFailures[openID]
            }
            // No default — openable only while at least one shipping catalog works.
            let failures = ids.compactMap { modelCatalogLoadFailures[$0] }
            guard failures.count == ids.count else { return nil }
            return failures.first
        default:
            for agentID in ids {
                if let message = modelCatalogLoadFailures[agentID] {
                    return message
                }
            }
            return nil
        }
    }

    /// Records a diagnostic and returns `true` when `projectPath` cannot be
    /// opened because a required model catalog failed.
    @discardableResult
    public func rejectIfModelCatalogUnavailable(forProjectPath projectPath: String) -> Bool {
        guard let project = projectRef(at: projectPath),
              let message = modelCatalogFailureMessage(for: project) else {
            return false
        }
        diagnostics.append(diagnostic(level: .error, message: message))
        return true
    }

    /// Soft-ensures catalogs for `projectType`: records per-adapter failures,
    /// clears successes, and returns whether the project is openable.
    @discardableResult
    public func ensureModelsRecordingFailures(for projectType: ProjectType) async -> Bool {
        let ids = Self.modelCatalogAgentIDs(for: projectType)
        guard !ids.isEmpty else {
            await reloadWorkspaceModelCatalogStatus()
            return true
        }
        for agentID in ids {
            do {
                try await ensureModelsLoaded(for: agentID)
                modelCatalogLoadFailures.removeValue(forKey: agentID)
            } catch {
                modelCatalogLoadFailures[agentID] = Self.modelCatalogFailureMessage(for: error)
            }
        }
        await reloadWorkspaceModelCatalogStatus()
        // Synthetic ref — only projectType matters for readiness.
        let probe = WorkspaceProjectsStore.ProjectRef(
            path: "/__catalog-probe__",
            displayName: "probe",
            projectType: projectType
        )
        return isProjectModelCatalogReady(probe)
    }

    static func modelCatalogFailureMessage(for error: any Error) -> String {
        if let agentError = error as? AgentError {
            return agentError.userMessage
        }
        return error.localizedDescription
    }

    /// Ensures every shipping adapter required by `projectType` has a
    /// non-empty model catalog. Mixed projects require all shipping adapters.
    public func ensureModelsLoaded(for projectType: ProjectType) async throws {
        for agentID in Self.modelCatalogAgentIDs(for: projectType) {
            try await ensureModelsLoaded(for: agentID)
        }
    }

    /// Ensures `agentID` has a non-empty in-memory catalog, warming from the
    /// per-adapter workspace file or a live probe as needed.
    public func ensureModelsLoaded(for agentID: AgentID) async throws {
        guard AgentID.shipping.contains(agentID) else { return }
        guard let adapter = await AdapterRegistry.shared.adapter(for: agentID) else {
            throw ModelCatalogLoadError.adapterUnavailable(agentID)
        }
        let models = try await loadModels(for: adapter)
        guard !models.isEmpty else {
            throw ModelCatalogLoadError.emptyCatalog(adapter.displayName)
        }
    }

    /// Manual adapters (Claude) use the workspace cache with no TTL. Automatic
    /// adapters reuse a disk cache for at most
    /// `ModelCatalogTiming.automaticCatalogMaxAge`, then re-probe. A flaky
    /// empty/failed probe keeps the previous on-disk catalog when one exists
    /// and records a warning diagnostic. Freshness is decided from the
    /// workspace adapter file — not process-local `availableModels()` — so
    /// background probes (e.g. Cursor binary locate) cannot skip a due daily
    /// refresh.
    func loadModels(for adapter: any AgentAdapter) async throws -> [AgentModelOption] {
        let kind = adapter.modelCatalogRefreshKind()
        guard let workspaceRoot, let store = workspaceProjects else {
            return try await probeAndSeed(adapter)
        }

        let cached = await store.cachedModels(for: adapter.id, in: workspaceRoot)
        if let cached, !cached.models.isEmpty, Self.shouldUseCachedModels(cached, kind: kind, now: clock.now()) {
            adapter.seedModelCatalog(cached.models)
            return cached.models
        }

        do {
            let models = try await probeModelCatalog(adapter)
            guard !models.isEmpty else {
                if let cached, !cached.models.isEmpty {
                    adapter.seedModelCatalog(cached.models)
                    noteRetainedModelCatalog(
                        for: adapter,
                        reason: "empty catalog"
                    )
                    return cached.models
                }
                return models
            }
            try await store.saveModels(
                models,
                for: adapter.id,
                refreshedAt: clock.now(),
                in: workspaceRoot
            )
            adapter.seedModelCatalog(models)
            return models
        } catch {
            if let cached, !cached.models.isEmpty {
                adapter.seedModelCatalog(cached.models)
                noteRetainedModelCatalog(
                    for: adapter,
                    reason: error.localizedDescription
                )
                return cached.models
            }
            throw error
        }
    }

    /// User-triggered model refresh from Workspace settings (manual and automatic).
    public func refreshAdapterModels(for agentID: AgentID) async {
        guard let workspaceRoot, let store = workspaceProjects else {
            diagnostics.append(diagnostic(
                level: .error,
                message: "Open a workspace before refreshing models."
            ))
            return
        }
        guard let adapter = await AdapterRegistry.shared.adapter(for: agentID) else {
            diagnostics.append(diagnostic(
                level: .error,
                message: "Adapter unavailable for model refresh."
            ))
            return
        }
        let previous = await store.cachedModels(for: agentID, in: workspaceRoot)
        modelCatalogRefreshInFlight = agentID
        defer { modelCatalogRefreshInFlight = nil }
        do {
            let models = try await probeModelCatalog(adapter)
            guard !models.isEmpty else {
                if let previous, !previous.models.isEmpty {
                    adapter.seedModelCatalog(previous.models)
                }
                throw ModelCatalogLoadError.emptyCatalog(adapter.displayName)
            }
            try await store.saveModels(
                models,
                for: agentID,
                refreshedAt: clock.now(),
                in: workspaceRoot
            )
            adapter.seedModelCatalog(models)
            modelCatalogLoadFailures.removeValue(forKey: agentID)
            await reloadWorkspaceModelCatalogStatus()
            if let activePath = workspace?.path,
               let activeType = projects.first(where: { $0.path == activePath })?.projectType,
               activeType.primaryAgentID == agentID {
                availableModels = models
            }
        } catch {
            if let previous, !previous.models.isEmpty {
                adapter.seedModelCatalog(previous.models)
            } else {
                modelCatalogLoadFailures[agentID] = Self.modelCatalogFailureMessage(for: error)
            }
            diagnostics.append(diagnostic(
                level: .error,
                message: "Model refresh failed: \(error.localizedDescription)"
            ))
            await reloadWorkspaceModelCatalogStatus()
        }
    }

    public func reloadWorkspaceModelCatalogStatus() async {
        guard let workspaceRoot, let store = workspaceProjects else {
            workspaceModelCatalogRows = []
            return
        }
        var rows: [WorkspaceModelCatalogRow] = []
        for agentID in Self.modelCatalogAgentIDs(in: projects) {
            guard let entry = SupportedBuiltInAgent.entry(for: agentID) else { continue }
            let adapter = await AdapterRegistry.shared.adapter(for: agentID)
            let kind = adapter?.modelCatalogRefreshKind() ?? .automatic
            let cached = await store.cachedModels(for: agentID, in: workspaceRoot)
            let modelCount: Int
            if let cached, !cached.models.isEmpty {
                modelCount = cached.models.count
            } else {
                modelCount = adapter?.availableModels().count ?? 0
            }
            rows.append(WorkspaceModelCatalogRow(
                agentID: entry.id,
                displayName: entry.displayLabel,
                refreshKind: kind,
                modelCount: modelCount,
                refreshedAt: cached?.refreshedAt,
                loadError: modelCatalogLoadFailures[agentID]
            ))
        }
        workspaceModelCatalogRows = rows
    }

    private static func shouldUseCachedModels(
        _ cached: WorkspaceAdapterLocalState.CachedAdapterModels,
        kind: ModelCatalogRefreshKind,
        now: Date
    ) -> Bool {
        switch kind {
        case .manual:
            return !cached.models.isEmpty
        case .automatic:
            guard !cached.models.isEmpty, let refreshedAt = cached.refreshedAt else {
                return false
            }
            return now.timeIntervalSince(refreshedAt) < ModelCatalogTiming.automaticCatalogMaxAge
        }
    }

    private func noteRetainedModelCatalog(for adapter: any AgentAdapter, reason: String) {
        diagnostics.append(diagnostic(
            level: .warning,
            message: """
                \(adapter.displayName) model refresh failed (\(reason)); \
                using cached models.
                """
        ))
    }

    private func probeAndSeed(_ adapter: any AgentAdapter) async throws -> [AgentModelOption] {
        let models = try await probeModelCatalog(adapter)
        if !models.isEmpty {
            adapter.seedModelCatalog(models)
        }
        return models.isEmpty ? adapter.availableModels() : models
    }

    /// Live adapter probe with a hard deadline so a hung CLI cannot freeze
    /// create/open / Settings refresh.
    private func probeModelCatalog(_ adapter: any AgentAdapter) async throws -> [AgentModelOption] {
        try await withThrowingTaskGroup(of: [AgentModelOption].self) { group in
            group.addTask {
                try await adapter.refreshModelCatalog()
            }
            group.addTask { [clock] in
                try await clock.sleep(for: ModelCatalogTiming.probeTimeout)
                throw ModelCatalogLoadError.probeTimedOut(adapter.displayName)
            }
            do {
                guard let result = try await group.next() else {
                    throw ModelCatalogLoadError.probeTimedOut(adapter.displayName)
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// Shipping agents whose model catalogs are required for `projectType`.
    /// Mixed projects can switch among all shipping CLIs, so every shipping
    /// adapter is required. Custom projects have no shipping catalog.
    public static func modelCatalogAgentIDs(for projectType: ProjectType) -> [AgentID] {
        switch projectType {
        case .claudeCode, .codex, .cursorCLI:
            if let id = projectType.primaryAgentID { return [id] }
            return []
        case .mixed:
            return SupportedBuiltInAgent.shippingIDs()
        case .custom, .folder:
            return []
        }
    }

    /// Deduped shipping agent IDs required by the current workspace projects.
    public static func modelCatalogAgentIDs(
        in projects: [WorkspaceProjectsStore.ProjectRef]
    ) -> [AgentID] {
        var ordered: [AgentID] = []
        var seen: Set<AgentID> = []
        for project in projects {
            for id in modelCatalogAgentIDs(for: project.projectType) where seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        return ordered
    }

    func applyAdapterCapabilities(forProjectPath path: String) {
        let expectedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        adapterCapabilitiesGeneration += 1
        let generation = adapterCapabilitiesGeneration
        Task { [weak self] in
            guard let self, let store = workspaceProjects else { return }
            let url = URL(fileURLWithPath: path)
            let projectType: ProjectType?
            if let project = await store.project(path: path) {
                projectType = project.projectType
            } else {
                projectType = await store.resolveProjectType(for: url)
            }
            guard let projectType else { return }
            await MainActor.run {
                guard self.shouldApplyAdapterCapabilities(
                    generation: generation,
                    expectedPath: expectedPath
                ) else { return }
                self.applyAdapterCapabilities(for: projectType, projectURL: url)
            }
        }
    }

    func shouldApplyAdapterCapabilities(generation: Int, expectedPath: String?) -> Bool {
        guard generation == adapterCapabilitiesGeneration else { return false }
        guard let expectedPath else { return true }
        guard let current = workspace?.path else { return false }
        return URL(fileURLWithPath: current).standardizedFileURL.path == expectedPath
    }
}
