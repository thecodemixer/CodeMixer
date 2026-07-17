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
        let (vm, bus, store, fileSystem) = makeHarness()
        let folder = URL(fileURLWithPath: "/Users/me/ws-empty")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)

        try await WorkspaceLifecycle(model: vm).openEmptyWorkspace(folder)

        #expect(vm.workspaceRoot?.path == folder.path)
        #expect(vm.projects.isEmpty)
        #expect(vm.workspaceModelCatalogRows.isEmpty)
        #expect(await store.activeWorkspaceURL()?.path == folder.path)

        await bus.shutdown()
    }

    @Test("loadModelCatalogs warms only adapters present in the workspace")
    func loadModelCatalogsWarmsWorkspaceAdapters() async throws {
        let (vm, bus, store, fileSystem) = makeHarness()
        let folder = URL(fileURLWithPath: "/Users/me/ws-claude")
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

        try await WorkspaceLifecycle(model: vm).loadModelCatalogs(at: folder, rootProjectType: .claudeCode)

        #expect(vm.workspaceRoot?.path == folder.path)
        #expect(vm.workspaceModelCatalogRows.map(\.agentID) == [.claudeCode])
        #expect(vm.workspaceModelCatalogRows.first?.modelCount == 1)

        await bus.shutdown()
    }

    @Test("ensureModels for a new project type loads that adapter catalog")
    func ensureModelsForNewProjectType() async throws {
        let (vm, bus, store, fileSystem) = makeHarness()
        let folder = URL(fileURLWithPath: "/Users/me/ws-add")
        try fileSystem.createDirectory(at: folder, withIntermediates: true)
        try await WorkspaceLifecycle(model: vm).openEmptyWorkspace(folder)

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
        let (vm, bus, _, _) = makeHarness()
        vm.workspaceRoot = URL(fileURLWithPath: "/Users/me/ws")

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
        let (vm, bus, store, fileSystem) = makeHarness()
        let folder = URL(fileURLWithPath: "/Users/me/ws-claude-cache")
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

        try await WorkspaceLifecycle(model: vm).loadModelCatalogs(at: folder, rootProjectType: .claudeCode)

        #expect(adapter.refreshCallCount == 0)
        #expect(adapter.availableModels().map(\.id) == ["sonnet"])
        #expect(vm.workspaceModelCatalogRows.first?.modelCount == 1)

        await bus.shutdown()
    }
}

@MainActor
private func makeHarness() -> (EngineViewModel, MulticastEventBus, WorkspaceProjectsStore, InMemoryFileSystem) {
    let bus = MulticastEventBus()
    let fileSystem = InMemoryFileSystem()
    let environment = FakeEnvironment(home: URL(fileURLWithPath: "/Users/me"))
    let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
    let vm = EngineViewModel(
        engine: LifecycleNoThrowPort(),
        bus: bus,
        clock: FakeClock(),
        random: FakeRandomSource()
    )
    vm.workspaceProjects = store
    return (vm, bus, store, fileSystem)
}

private final class LifecycleNoThrowPort: AgentEngineCommandPort, @unchecked Sendable {
    func send(_ command: AgentCommand) async throws {}
}
