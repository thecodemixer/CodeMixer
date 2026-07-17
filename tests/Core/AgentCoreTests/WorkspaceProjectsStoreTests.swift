import Testing
import Foundation
@testable import AgentCore
import AgentTestSupport

/// Tests for `WorkspaceProjectsStore` — root seeding, createProject edge cases,
/// add-existing idempotence, root-protected removal, round-trip persistence,
/// and schema-version tolerance.
@Suite("WorkspaceProjectsStore — projects model + persistence")
struct WorkspaceProjectsStoreTests {

    private let workspace = URL(fileURLWithPath: "/Users/me/ws")

    @Test("projects(for:) seeds the workspace root as the default project")
    func seedsRoot() async {
        let store = makeStore()
        let projects = await store.projects(for: workspace, rootMode: .claudeCode)
        #expect(projects.count == 1)
        #expect(projects.first?.path == workspace.path)
        #expect(projects.first?.displayName == "ws")
    }

    @Test("createProject creates a subfolder and registers it without seeding the workspace root")
    func createProjectRegisters() async throws {
        let store = makeStore()
        let ref = try await store.createProject(name: "api", agentMode: .claudeCode, in: workspace)
        #expect(ref.path == workspace.appendingPathComponent("api").path)
        #expect(ref.displayName == "api")

        let projects = await store.projects(for: workspace)
        #expect(projects.map(\.path) == [ref.path])
    }

    @Test("createProject rejects empty, dot, dot-dot, and separator names")
    func createProjectInvalidNames() async {
        let store = makeStore()
        for bad in ["", "   ", ".", "..", "a/b", "a\\b"] {
            await #expect(throws: WorkspaceProjectsStore.StoreError.self) {
                try await store.createProject(name: bad, agentMode: .claudeCode, in: workspace)
            }
        }
    }

    @Test("createProject is a no-op returning the existing ref when already registered")
    func createProjectIdempotentWhenRegistered() async throws {
        let store = makeStore()
        let first = try await store.createProject(name: "api", agentMode: .claudeCode, in: workspace)
        let second = try await store.createProject(name: "api", agentMode: .claudeCode, in: workspace)
        #expect(first == second)
        let projects = await store.projects(for: workspace, rootMode: .claudeCode)
        #expect(projects.filter { $0.path == first.path }.count == 1)
    }

    @Test("createProject throws projectFolderExists when the folder exists but is unregistered")
    func createProjectFolderExistsUnregistered() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let folder = workspace.appendingPathComponent("api", isDirectory: true)
        try fs.createDirectory(at: folder, withIntermediates: true)

        await #expect(throws: WorkspaceProjectsStore.StoreError.projectFolderExists(path: folder.path)) {
            try await store.createProject(name: "api", agentMode: .claudeCode, in: workspace)
        }
    }

    @Test("addExistingProject registers an external path and is idempotent")
    func addExistingIdempotent() async throws {
        let store = makeStore()
        let external = URL(fileURLWithPath: "/elsewhere/lib")
        let a = try await store.addExistingProject(url: external, agentMode: .codex, in: workspace)
        let b = try await store.addExistingProject(url: external, agentMode: .codex, in: workspace)
        #expect(a == b)
        #expect(a.displayName == "lib")
        let projects = await store.projects(for: workspace, rootMode: .claudeCode)
        #expect(projects.filter { $0.path == external.path }.count == 1)
    }

    @Test("project(path:) finds project refs across loaded workspaces")
    func projectLookupByPath() async throws {
        let store = makeStore()
        let ref = try await store.createProject(name: "api", agentMode: .codex, in: workspace)

        let found = await store.project(path: ref.path)

        #expect(found == ref)
    }

    @Test("removeProject removes a non-root project but never the seeded root")
    func removeProtectsRoot() async throws {
        let store = makeStore()
        let ref = try await store.createProject(name: "api", agentMode: .claudeCode, in: workspace)

        try await store.removeProject(path: ref.path, in: workspace)
        var projects = await store.projects(for: workspace, rootMode: .claudeCode)
        #expect(!projects.contains { $0.path == ref.path })

        // Removing the root is refused.
        try await store.removeProject(path: workspace.path, in: workspace)
        projects = await store.projects(for: workspace, rootMode: .claudeCode)
        #expect(projects.contains { $0.path == workspace.path })
    }

    @Test("renameProject changes the display label but keeps the path identity")
    func renameKeepsPath() async throws {
        let store = makeStore()
        let ref = try await store.createProject(name: "api", agentMode: .claudeCode, in: workspace)
        let renamed = try await store.renameProject(path: ref.path, to: "Backend", in: workspace)
        #expect(renamed.path == ref.path)
        #expect(renamed.displayName == "Backend")

        let projects = await store.projects(for: workspace, rootMode: .claudeCode)
        #expect(projects.first(where: { $0.path == ref.path })?.displayName == "Backend")
    }

    @Test("renameProject rejects an empty name")
    func renameRejectsEmpty() async throws {
        let store = makeStore()
        let ref = try await store.createProject(name: "api", agentMode: .claudeCode, in: workspace)
        await #expect(throws: WorkspaceProjectsStore.StoreError.self) {
            try await store.renameProject(path: ref.path, to: "   ", in: workspace)
        }
    }

    @Test("removeProject returns the removed ref + index; restoreProject puts it back in place")
    func removeThenRestore() async throws {
        let store = makeStore()
        let a = try await store.createProject(name: "a", agentMode: .claudeCode, in: workspace)
        let b = try await store.createProject(name: "b", agentMode: .codex, in: workspace)
        // Order is [a, b]; remove `a` at index 0.
        let removed = try await store.removeProject(path: a.path, in: workspace)
        #expect(removed?.ref == a)
        #expect(removed?.index == 0)

        var projects = await store.projects(for: workspace)
        #expect(projects.map(\.path) == [b.path])

        try await store.restoreProject(removed!, in: workspace)
        projects = await store.projects(for: workspace)
        #expect(projects.map(\.path) == [a.path, b.path])
    }

    @Test("removeProject on the root returns nil and keeps the root")
    func removeRootReturnsNil() async throws {
        let store = makeStore()
        _ = await store.projects(for: workspace, rootMode: .claudeCode)
        let removed = try await store.removeProject(path: workspace.path, in: workspace)
        #expect(removed == nil)
        let projects = await store.projects(for: workspace, rootMode: .claudeCode)
        #expect(projects.contains { $0.path == workspace.path })
    }

    @Test("Round-trip: a fresh store over the same filesystem recovers projects")
    func roundTrip() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        try await store.createProject(name: "api", agentMode: .claudeCode, in: workspace)

        let fresh = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await fresh.load()
        let projects = await fresh.projects(for: workspace)
        #expect(projects.map(\.displayName) == ["api"])
    }

    @Test("createProject writes agent mode into the project folder")
    func writesProjectLocalState() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(name: "api", agentMode: .codex, in: workspace)
        let localURL = ProjectPaths.projectStateURL(in: URL(fileURLWithPath: ref.path))
        #expect(fs.fileExists(at: localURL))
        let loaded = ProjectLocalStateStore.load(from: URL(fileURLWithPath: ref.path), fileSystem: fs)
        #expect(loaded?.agentMode == .codex)
        #expect(loaded?.displayName == "api")
    }

    @Test("resolveAgentMode prefers project-local state over the workspace index")
    func resolvePrefersLocalFile() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(name: "api", agentMode: .claudeCode, in: workspace)
        let projectRoot = URL(fileURLWithPath: ref.path)
        try ProjectLocalStateStore.save(
            ProjectLocalState(displayName: "api", agentMode: .codex),
            to: projectRoot,
            fileSystem: fs
        )
        let mode = await store.resolveAgentMode(for: projectRoot)
        #expect(mode == .codex)
    }

    @Test("projects(for:) seeds from project-local state when rootMode is omitted")
    func seedsFromLocalState() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        try ProjectLocalStateStore.save(
            ProjectLocalState(displayName: "ws", agentMode: .codex),
            to: workspace,
            fileSystem: fs
        )
        let projects = await store.projects(for: workspace)
        #expect(projects.count == 1)
        #expect(projects.first?.agentMode == .codex)
    }

    @Test("createProject writes workspace.json catalog in the workspace folder")
    func writesWorkspaceLocalCatalog() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(name: "api", agentMode: .codex, in: workspace)
        let local = WorkspaceLocalStateStore.load(from: workspace, fileSystem: fs)
        #expect(local?.projects.map(\.path) == [ref.path])
        #expect(fs.fileExists(at: ProjectPaths.workspaceStateURL(in: workspace)))
    }

    @Test("projects(for:) seeds from workspace.json when the app-support index is empty")
    func seedsFromWorkspaceLocalCatalog() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let api = workspace.appendingPathComponent("api")
        try fs.createDirectory(at: workspace, withIntermediates: true)
        try fs.createDirectory(at: api, withIntermediates: true)
        let catalog = [
            WorkspaceProjectsStore.ProjectRef(path: workspace.path, displayName: "ws", agentMode: .claudeCode),
            WorkspaceProjectsStore.ProjectRef(path: api.path, displayName: "api", agentMode: .codex),
        ]
        try WorkspaceLocalStateStore.save(projects: catalog, to: workspace, fileSystem: fs)

        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        let projects = await store.projects(for: workspace)
        #expect(projects.map(\.path) == [workspace.path, api.path])
        #expect(projects.last?.agentMode == .codex)
    }

    @Test("markActiveWorkspace / clearActiveWorkspace round-trip through workspaces.json")
    func activeWorkspaceRoundTrip() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        try fs.createDirectory(at: workspace, withIntermediates: true)
        _ = await store.projects(for: workspace, rootMode: .claudeCode)
        try await store.markActiveWorkspace(workspace)
        #expect(await store.activeWorkspaceURL()?.path == workspace.path)

        let fresh = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await fresh.load()
        #expect(await fresh.activeWorkspaceURL()?.path == workspace.path)

        try await fresh.clearActiveWorkspace()
        #expect(await fresh.activeWorkspaceURL() == nil)

        let again = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await again.load()
        #expect(await again.activeWorkspaceURL() == nil)
    }

    @Test("load() ignores a newer on-disk schema rather than corrupting it")
    func toleratesNewerSchema() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let url = env.appSupportDirectory.appendingPathComponent("workspaces.json")
        let futureJSON = """
        {"schemaVersion": 999, "workspaces": [{"workspacePath": "\(workspace.path)", "projects": []}]}
        """
        try fs.writeAtomically(Data(futureJSON.utf8), to: url)

        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        // Newer schema ignored → the workspace re-seeds its root on demand.
        let projects = await store.projects(for: workspace, rootMode: .claudeCode)
        #expect(projects.count == 1)
        #expect(projects.first?.path == workspace.path)
    }

    @Test("load() accepts schema v2 files without activeWorkspacePath")
    func loadsSchemaV2WithoutActive() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let url = env.appSupportDirectory.appendingPathComponent("workspaces.json")
        let v2 = """
        {"schemaVersion":2,"workspaces":[{"workspacePath":"\(workspace.path)","projects":[{"path":"\(workspace.path)","displayName":"ws","agentMode":{"claudeCode":{}}}]}]}
        """
        try fs.writeAtomically(Data(v2.utf8), to: url)
        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        #expect(await store.activeWorkspaceURL() == nil)
        let projects = await store.projects(for: workspace)
        #expect(projects.first?.displayName == "ws")
    }

    // MARK: - Helpers

    private func makeStore(fs: InMemoryFileSystem = InMemoryFileSystem()) -> WorkspaceProjectsStore {
        WorkspaceProjectsStore(environment: FakeEnvironment(), fileSystem: fs)
    }
}
