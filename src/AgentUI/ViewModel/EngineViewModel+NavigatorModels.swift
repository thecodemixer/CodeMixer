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
    /// Throws if any required catalog cannot be populated.
    public func warmWorkspaceModelCatalogs() async throws {
        guard workspaceRoot != nil, workspaceProjects != nil else {
            workspaceModelCatalogRows = []
            return
        }
        let agentIDs = Self.modelCatalogAgentIDs(in: projects)
        for agentID in agentIDs {
            try await ensureModelsLoaded(for: agentID)
        }
        await reloadWorkspaceModelCatalogStatus()
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
            let models = try await adapter.refreshModelCatalog()
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
            let models = try await adapter.refreshModelCatalog()
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
            await reloadWorkspaceModelCatalogStatus()
            if let activePath = workspace?.path,
               let activeType = projects.first(where: { $0.path == activePath })?.projectType,
               activeType.primaryAgentID == agentID {
                availableModels = models
            }
        } catch {
            if let previous, !previous.models.isEmpty {
                adapter.seedModelCatalog(previous.models)
            }
            diagnostics.append(diagnostic(
                level: .error,
                message: "Model refresh failed: \(error.localizedDescription)"
            ))
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
                refreshedAt: cached?.refreshedAt
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
        let models = try await adapter.refreshModelCatalog()
        if !models.isEmpty {
            adapter.seedModelCatalog(models)
        }
        return models.isEmpty ? adapter.availableModels() : models
    }

    /// Shipping agents whose model catalogs are required for `projectType`.
    /// Mixed projects can switch among all shipping CLIs, so every shipping
    /// adapter is required. Custom projects have no shipping catalog.
    static func modelCatalogAgentIDs(for projectType: ProjectType) -> [AgentID] {
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
    static func modelCatalogAgentIDs(
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
