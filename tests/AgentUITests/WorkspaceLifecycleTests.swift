import Foundation
import Testing
@testable import AgentUI
@testable import AgentCore
@testable import AgentTestSupport
import AgentProtocol

@Suite("WorkspaceLifecycle — create/open model catalog paths")
@MainActor
struct WorkspaceLifecycleTests {

    @Test("openEmptyWorkspace marks active, sets root, and warms with no projects")
    func openEmptyWorkspaceWarmsWithoutProjects() async throws {
        let (vm, bus, store, fileSystem, _) = makeHarness()
        let folder = TestPaths.workspace("ws-empty")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)

        await WorkspaceLifecycle(model: vm).openEmptyWorkspace(folder)

        #expect(vm.workspaceRoot?.path == folder.path)
        #expect(vm.projects.isEmpty)
        #expect(vm.workspace == nil)
        #expect(vm.workspaceModelCatalogRows.isEmpty)
        #expect(await store.activeWorkspaceURL()?.path == folder.path)

        await bus.shutdown()
    }

    @Test("openEmptyWorkspace loads child projects from workspace.json without seeding the root")
    func openEmptyWorkspaceLoadsChildProjectsWithoutRootType() async throws {
        let (vm, bus, store, fileSystem, _) = makeHarness()
        let folder = TestPaths.workspace("ws-mongomixer-shape")
        let child = folder.appendingPathComponent("claude", isDirectory: true)
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        try fileSystem.createDirectory(at: child, withIntermediates: true)

        let childRef = WorkspaceProjectsStore.ProjectRef(
            path: child.path,
            displayName: "claude",
            projectType: .claudeCode
        )
        try ProjectLocalStateStore.save(ref: childRef, fileSystem: fileSystem)
        try WorkspaceLocalStateStore.save(projects: [childRef], to: folder, fileSystem: fileSystem)

        #expect(await store.resolveProjectType(for: folder) == nil)

        await AdapterRegistry.shared.register(MockAdapter(
            id: .claudeCode,
            displayName: "Claude Code",
            models: [AgentModelOption(id: "sonnet", label: "Sonnet")]
        ))

        await WorkspaceLifecycle(model: vm).openEmptyWorkspace(folder)

        #expect(vm.workspaceRoot?.path == folder.path)
        #expect(vm.projects.map(\.path) == [child.path])
        #expect(vm.projects.first?.projectType == .claudeCode)
        #expect(!(vm.projects.contains { $0.path == folder.path }))
        #expect(await store.activeWorkspaceURL()?.path == folder.path)
        #expect(await store.resolveProjectType(for: folder) == nil)
        // Shell with a single agent project auto-starts a new chat there.
        #expect(vm.workspace?.path == child.path)
        #expect(vm.sessionActivation == .awaitingAdapter(sessionID: ""))

        await bus.shutdown()
    }

    @Test("openEmptyWorkspace keeps ready projects when one adapter catalog fails")
    func openEmptyWorkspaceSoftFailsBrokenAdapter() async throws {
        let (vm, bus, store, fileSystem, _) = makeHarness()
        let folder = TestPaths.workspace("ws-partial-catalog")
        let claude = folder.appendingPathComponent("claude", isDirectory: true)
        let cursor = folder.appendingPathComponent("cursor", isDirectory: true)
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        try fileSystem.createDirectory(at: claude, withIntermediates: true)
        try fileSystem.createDirectory(at: cursor, withIntermediates: true)

        let claudeRef = WorkspaceProjectsStore.ProjectRef(
            path: claude.path,
            displayName: "claude",
            projectType: .claudeCode
        )
        let cursorRef = WorkspaceProjectsStore.ProjectRef(
            path: cursor.path,
            displayName: "cursor",
            projectType: .cursorCLI
        )
        try ProjectLocalStateStore.save(ref: claudeRef, fileSystem: fileSystem)
        try ProjectLocalStateStore.save(ref: cursorRef, fileSystem: fileSystem)
        try WorkspaceLocalStateStore.save(
            projects: [claudeRef, cursorRef],
            to: folder,
            fileSystem: fileSystem
        )

        await AdapterRegistry.shared.register(MockAdapter(
            id: .claudeCode,
            displayName: "Claude Code",
            models: [AgentModelOption(id: "sonnet", label: "Sonnet")]
        ))
        await AdapterRegistry.shared.register(MockAdapter(
            id: .cursorCLI,
            displayName: "Cursor",
            models: [],
            refreshKind: .automatic,
            refreshResult: []
        ))

        await WorkspaceLifecycle(model: vm).openEmptyWorkspace(folder)

        #expect(vm.workspaceRoot?.path == folder.path)
        #expect(vm.loadedProjects.map(\.path) == [claude.path])
        #expect(vm.unloadedProjects.map(\.path) == [cursor.path])
        #expect(vm.modelCatalogLoadFailures[.cursorCLI] != nil)
        #expect(vm.modelCatalogFailureMessage(for: cursorRef)?.contains("Cursor") == true)
        // Ready sibling activates; broken Cursor stays Not loaded.
        #expect(vm.workspace?.path == claude.path)
        #expect(await store.activeWorkspaceURL()?.path == folder.path)

        await bus.shutdown()
    }

    @Test("loadModelCatalogs records failure without throwing when catalog is empty")
    func loadModelCatalogsSoftFailsEmptyCatalog() async throws {
        let (vm, bus, store, fileSystem, _) = makeHarness()
        let folder = TestPaths.workspace("ws-cursor-empty")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        _ = try await store.createProject(name: "cur", projectType: .cursorCLI, in: folder)

        await AdapterRegistry.shared.register(MockAdapter(
            id: .cursorCLI,
            displayName: "Cursor",
            models: [],
            refreshKind: .automatic,
            refreshResult: []
        ))

        await WorkspaceLifecycle(model: vm).loadModelCatalogs(
            at: folder,
            rootProjectType: .cursorCLI
        )

        #expect(vm.workspaceRoot?.path == folder.path)
        #expect(vm.modelCatalogLoadFailures[.cursorCLI] != nil)
        #expect(vm.unloadedProjects.count == 1)
        #expect(vm.loadedProjects.isEmpty)
        #expect(vm.workspaceModelCatalogRows.first?.loadError != nil)

        await bus.shutdown()
    }

    @Test("mixed project stays loaded when only a non-default shipping adapter fails")
    func mixedStaysLoadedWhenNonDefaultAdapterFails() async throws {
        let (vm, bus, store, fileSystem, _) = makeHarness()
        let folder = TestPaths.workspace("ws-mixed-partial")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        _ = try await store.createProject(
            name: "mix",
            projectType: .mixed(defaultAgent: .claudeCode),
            in: folder
        )

        await AdapterRegistry.shared.register(MockAdapter(
            id: .claudeCode,
            displayName: "Claude Code",
            models: [AgentModelOption(id: "sonnet", label: "Sonnet")]
        ))
        await AdapterRegistry.shared.register(MockAdapter(
            id: .codex,
            displayName: "Codex",
            models: [AgentModelOption(id: "gpt", label: "GPT")]
        ))
        await AdapterRegistry.shared.register(MockAdapter(
            id: .cursorCLI,
            displayName: "Cursor",
            models: [],
            refreshKind: .automatic,
            refreshResult: []
        ))

        await WorkspaceLifecycle(model: vm).loadModelCatalogs(
            at: folder,
            rootProjectType: .mixed(defaultAgent: .claudeCode)
        )

        #expect(vm.modelCatalogLoadFailures[.cursorCLI] != nil)
        #expect(vm.modelCatalogLoadFailures[.claudeCode] == nil)
        #expect(vm.loadedProjects.count == 1)
        #expect(vm.unloadedProjects.isEmpty)

        await bus.shutdown()
    }

    @Test("mixed project is Not loaded when its default agent catalog fails")
    func mixedUnloadedWhenDefaultAdapterFails() async throws {
        let (vm, bus, store, fileSystem, _) = makeHarness()
        let folder = TestPaths.workspace("ws-mixed-default-fail")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        _ = try await store.createProject(
            name: "mix",
            projectType: .mixed(defaultAgent: .cursorCLI),
            in: folder
        )

        await AdapterRegistry.shared.register(MockAdapter(
            id: .claudeCode,
            displayName: "Claude Code",
            models: [AgentModelOption(id: "sonnet", label: "Sonnet")]
        ))
        await AdapterRegistry.shared.register(MockAdapter(
            id: .codex,
            displayName: "Codex",
            models: [AgentModelOption(id: "gpt", label: "GPT")]
        ))
        await AdapterRegistry.shared.register(MockAdapter(
            id: .cursorCLI,
            displayName: "Cursor",
            models: [],
            refreshKind: .automatic,
            refreshResult: []
        ))

        await WorkspaceLifecycle(model: vm).loadModelCatalogs(
            at: folder,
            rootProjectType: .mixed(defaultAgent: .cursorCLI)
        )

        #expect(vm.modelCatalogLoadFailures[.cursorCLI] != nil)
        #expect(vm.unloadedProjects.count == 1)
        #expect(vm.loadedProjects.isEmpty)

        await bus.shutdown()
    }

    @Test("loadModelCatalogs warms only adapters present in the workspace")
    func loadModelCatalogsWarmsWorkspaceAdapters() async throws {
        let (vm, bus, store, fileSystem, _) = makeHarness()
        let folder = TestPaths.workspace("ws-claude")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        _ = try await store.createProject(name: "api", projectType: .claudeCode, in: folder)

        await AdapterRegistry.shared.register(MockAdapter(
            id: .claudeCode,
            displayName: "Claude Code",
            models: [AgentModelOption(id: "sonnet", label: "Sonnet")]
        ))
        await AdapterRegistry.shared.register(MockAdapter(
            id: .cursorCLI,
            displayName: "Cursor",
            models: [AgentModelOption(id: "auto", label: "Auto")]
        ))

        await WorkspaceLifecycle(model: vm).loadModelCatalogs(at: folder, rootProjectType: .claudeCode)

        #expect(vm.workspaceRoot?.path == folder.path)
        #expect(vm.workspaceModelCatalogRows.map(\.agentID) == [.claudeCode])
        #expect(vm.workspaceModelCatalogRows.first?.modelCount == 1)
        #expect(vm.modelCatalogLoadFailures.isEmpty)

        await bus.shutdown()
    }

    @Test("ensureModels for a new project type loads that adapter catalog")
    func ensureModelsForNewProjectType() async throws {
        let (vm, bus, store, fileSystem, _) = makeHarness()
        let folder = TestPaths.workspace("ws-add")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        await WorkspaceLifecycle(model: vm).openEmptyWorkspace(folder)

        await AdapterRegistry.shared.register(MockAdapter(
            id: .cursorCLI,
            displayName: "Cursor",
            models: [AgentModelOption(id: "auto", label: "Auto")]
        ))

        _ = try await store.createProject(name: "cur", projectType: .cursorCLI, in: folder)
        await vm.reloadProjects()
        try await WorkspaceLifecycle(model: vm).ensureModels(for: .cursorCLI)

        #expect(vm.workspaceModelCatalogRows.map(\.agentID) == [.cursorCLI])
        #expect(vm.workspaceModelCatalogRows.first?.modelCount == 1)

        await bus.shutdown()
    }

    @Test("ensureModels for mixed requires every shipping adapter catalog")
    func ensureModelsForMixedRequiresAllShipping() async throws {
        let (vm, bus, _, _, _) = makeHarness()
        vm.workspaceRoot = TestPaths.workspace("ws")

        // Replace whatever prior suites left in the shared registry with a
        // incomplete set (empty Codex catalog) so ensure must fail.
        await AdapterRegistry.shared.register(MockAdapter(
            id: .claudeCode,
            displayName: "Claude Code",
            models: [AgentModelOption(id: "sonnet", label: "Sonnet")]
        ))
        await AdapterRegistry.shared.register(MockAdapter(
            id: .codex,
            displayName: "Codex",
            models: []
        ))
        await AdapterRegistry.shared.register(MockAdapter(
            id: .cursorCLI,
            displayName: "Cursor",
            models: [AgentModelOption(id: "auto", label: "Auto")]
        ))

        do {
            try await WorkspaceLifecycle(model: vm).ensureModels(for: .mixed(defaultAgent: .claudeCode))
            Issue.record("Expected mixed ensure to fail when Codex catalog is empty")
        } catch let error as EngineViewModel.ModelCatalogLoadError {
            if case .emptyCatalog = error {} else {
                Issue.record("Expected emptyCatalog, got \(error)")
            }
        }

        await AdapterRegistry.shared.register(MockAdapter(
            id: .codex,
            displayName: "Codex",
            models: [AgentModelOption(id: "gpt", label: "GPT")]
        ))
        try await WorkspaceLifecycle(model: vm).ensureModels(for: .mixed(defaultAgent: .claudeCode))
        await bus.shutdown()
    }

    @Test("Claude-style manual catalog loads from workspace cache without probing")
    func manualCatalogPrefersWorkspaceCache() async throws {
        let (vm, bus, store, fileSystem, _) = makeHarness()
        let folder = TestPaths.workspace("ws-claude-cache")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        _ = try await store.createProject(name: "api", projectType: .claudeCode, in: folder)

        let cached = [AgentModelOption(id: "sonnet", label: "Sonnet")]
        try await store.saveModels(
            cached,
            for: .claudeCode,
            refreshedAt: Date(timeIntervalSince1970: 1_700_000_000),
            in: folder
        )

        let adapter = MockAdapter(
            id: .claudeCode,
            displayName: "Claude Code",
            models: [],
            refreshKind: .manual(detail: "print mode"),
            refreshResult: [AgentModelOption(id: "opus", label: "Opus")]
        )
        await AdapterRegistry.shared.register(adapter)

        await WorkspaceLifecycle(model: vm).loadModelCatalogs(at: folder, rootProjectType: .claudeCode)

        #expect(adapter.refreshCallCount == 0)
        #expect(adapter.availableModels().map(\.id) == ["sonnet"])
        #expect(vm.workspaceModelCatalogRows.first?.modelCount == 1)

        await bus.shutdown()
    }

    @Test("automatic catalog with fresh disk cache skips probe")
    func automaticFreshDiskCacheSkipsProbe() async throws {
        let (vm, bus, store, fileSystem, clock) = makeHarness()
        let folder = TestPaths.workspace("ws-auto-fresh")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        _ = try await store.createProject(name: "api", projectType: .cursorCLI, in: folder)

        try await store.saveModels(
            [AgentModelOption(id: "cached", label: "Cached")],
            for: .cursorCLI,
            refreshedAt: clock.now(),
            in: folder
        )

        let adapter = MockAdapter(
            id: .cursorCLI,
            displayName: "Cursor",
            models: [],
            refreshKind: .automatic,
            refreshResult: [AgentModelOption(id: "probed", label: "Probed")]
        )
        await AdapterRegistry.shared.register(adapter)

        await WorkspaceLifecycle(model: vm).loadModelCatalogs(at: folder, rootProjectType: .cursorCLI)

        #expect(adapter.refreshCallCount == 0)
        #expect(adapter.availableModels().map(\.id) == ["cached"])
        await bus.shutdown()
    }

    @Test("automatic catalog with stale disk cache re-probes")
    func automaticStaleDiskCacheReprobes() async throws {
        let (vm, bus, store, fileSystem, clock) = makeHarness()
        let folder = TestPaths.workspace("ws-auto-stale")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        _ = try await store.createProject(name: "api", projectType: .cursorCLI, in: folder)

        try await store.saveModels(
            [AgentModelOption(id: "cached", label: "Cached")],
            for: .cursorCLI,
            refreshedAt: clock.now(),
            in: folder
        )
        clock.advance(by: .seconds(Int64(ModelCatalogTiming.automaticCatalogMaxAge) + 1))

        let adapter = MockAdapter(
            id: .cursorCLI,
            displayName: "Cursor",
            models: [],
            refreshKind: .automatic,
            refreshResult: [AgentModelOption(id: "probed", label: "Probed")]
        )
        await AdapterRegistry.shared.register(adapter)

        await WorkspaceLifecycle(model: vm).loadModelCatalogs(at: folder, rootProjectType: .cursorCLI)

        #expect(adapter.refreshCallCount == 1)
        #expect(adapter.availableModels().map(\.id) == ["probed"])
        let cached = await store.cachedModels(for: .cursorCLI, in: folder)
        #expect(cached?.models.map(\.id) == ["probed"])
        await bus.shutdown()
    }

    @Test("automatic catalog with nil refreshedAt re-probes")
    func automaticNilRefreshedAtReprobes() async throws {
        let (vm, bus, store, fileSystem, _) = makeHarness()
        let folder = TestPaths.workspace("ws-auto-nil")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        _ = try await store.createProject(name: "api", projectType: .codex, in: folder)

        try WorkspaceAdapterLocalStateStore.save(
            WorkspaceAdapterLocalState(
                models: [AgentModelOption(id: "old", label: "Old")],
                refreshedAt: nil
            ),
            for: .codex,
            in: folder,
            fileSystem: fileSystem
        )

        let adapter = MockAdapter(
            id: .codex,
            displayName: "Codex",
            models: [],
            refreshKind: .automatic,
            refreshResult: [AgentModelOption(id: "new", label: "New")]
        )
        await AdapterRegistry.shared.register(adapter)

        await WorkspaceLifecycle(model: vm).loadModelCatalogs(at: folder, rootProjectType: .codex)

        #expect(adapter.refreshCallCount == 1)
        #expect(adapter.availableModels().map(\.id) == ["new"])
        await bus.shutdown()
    }

    @Test("empty automatic probe retains prior disk cache")
    func emptyAutomaticProbeRetainsCache() async throws {
        let (vm, bus, store, fileSystem, clock) = makeHarness()
        let folder = TestPaths.workspace("ws-auto-retain")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        _ = try await store.createProject(name: "api", projectType: .cursorCLI, in: folder)

        try await store.saveModels(
            [AgentModelOption(id: "cached", label: "Cached")],
            for: .cursorCLI,
            refreshedAt: clock.now(),
            in: folder
        )
        clock.advance(by: .seconds(Int64(ModelCatalogTiming.automaticCatalogMaxAge) + 1))

        let adapter = MockAdapter(
            id: .cursorCLI,
            displayName: "Cursor",
            models: [],
            refreshKind: .automatic,
            refreshResult: []
        )
        await AdapterRegistry.shared.register(adapter)

        await WorkspaceLifecycle(model: vm).loadModelCatalogs(at: folder, rootProjectType: .cursorCLI)

        #expect(adapter.refreshCallCount == 1)
        #expect(adapter.availableModels().map(\.id) == ["cached"])
        let cached = await store.cachedModels(for: .cursorCLI, in: folder)
        #expect(cached?.models.map(\.id) == ["cached"])
        #expect(vm.diagnostics.contains { entry in
            entry.level == .warning
                && entry.message.contains("Cursor model refresh failed")
                && entry.message.contains("using cached models")
        })
        await bus.shutdown()
    }

    @Test("throwing automatic probe retains prior disk cache and warns")
    func throwingAutomaticProbeRetainsCache() async throws {
        let (vm, bus, store, fileSystem, clock) = makeHarness()
        let folder = TestPaths.workspace("ws-auto-throw")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        _ = try await store.createProject(name: "api", projectType: .cursorCLI, in: folder)

        try await store.saveModels(
            [AgentModelOption(id: "cached", label: "Cached")],
            for: .cursorCLI,
            refreshedAt: clock.now(),
            in: folder
        )
        clock.advance(by: .seconds(Int64(ModelCatalogTiming.automaticCatalogMaxAge) + 1))

        struct ProbeBoom: Error, LocalizedError {
            var errorDescription: String? { "probe boom" }
        }
        let adapter = MockAdapter(
            id: .cursorCLI,
            displayName: "Cursor",
            models: [],
            refreshKind: .automatic,
            refreshError: ProbeBoom()
        )
        await AdapterRegistry.shared.register(adapter)

        await WorkspaceLifecycle(model: vm).loadModelCatalogs(at: folder, rootProjectType: .cursorCLI)

        #expect(adapter.refreshCallCount == 1)
        #expect(adapter.availableModels().map(\.id) == ["cached"])
        let cached = await store.cachedModels(for: .cursorCLI, in: folder)
        #expect(cached?.models.map(\.id) == ["cached"])
        #expect(vm.diagnostics.contains { entry in
            entry.level == .warning
                && entry.message.contains("probe boom")
                && entry.message.contains("using cached models")
        })
        await bus.shutdown()
    }

    @Test("ensureModels for folder project types is a no-op")
    func ensureModelsForFolderIsNoOp() async throws {
        let (vm, bus, store, fileSystem, _) = makeHarness()
        let folder = TestPaths.workspace("ws-folder-models")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        await WorkspaceLifecycle(model: vm).openEmptyWorkspace(folder)
        _ = try await store.createProject(name: "docs", projectType: .folder(.docs), in: folder)
        await vm.reloadProjects()
        try await WorkspaceLifecycle(model: vm).ensureModels(for: .folder(.docs))
        #expect(vm.workspaceModelCatalogRows.isEmpty)
        await bus.shutdown()
    }
}

@MainActor
private func makeHarness() -> (
    EngineViewModel,
    MulticastEventBus,
    WorkspaceProjectsStore,
    InMemoryFileSystem,
    FakeClock
) {
    let bus = MulticastEventBus()
    let fileSystem = InMemoryFileSystem()
    let environment = FakeEnvironment(home: TestPaths.fakeHome)
    let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
    let clock = FakeClock()
    let vm = EngineViewModel(
        engine: LifecycleNoThrowPort(),
        bus: bus,
        clock: clock,
        random: FakeRandomSource()
    )
    vm.workspaceProjects = store
    return (vm, bus, store, fileSystem, clock)
}

private final class LifecycleNoThrowPort: AgentEngineCommandPort, @unchecked Sendable {
    func send(_ command: AgentCommand) async throws {}
}
