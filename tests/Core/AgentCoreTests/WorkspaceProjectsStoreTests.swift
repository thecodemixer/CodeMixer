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
        let projects = await store.projects(for: workspace)
        #expect(projects.count == 1)
        #expect(projects.first?.path == workspace.path)
        #expect(projects.first?.displayName == "ws")
    }

    @Test("createProject creates a subfolder and registers it after the root")
    func createProjectRegisters() async throws {
        let store = makeStore()
        let ref = try await store.createProject(name: "api", in: workspace)
        #expect(ref.path == workspace.appendingPathComponent("api").path)
        #expect(ref.displayName == "api")

        let projects = await store.projects(for: workspace)
        #expect(projects.map(\.path) == [workspace.path, ref.path])
    }

    @Test("createProject rejects empty, dot, dot-dot, and separator names")
    func createProjectInvalidNames() async {
        let store = makeStore()
        for bad in ["", "   ", ".", "..", "a/b", "a\\b"] {
            await #expect(throws: WorkspaceProjectsStore.StoreError.self) {
                try await store.createProject(name: bad, in: workspace)
            }
        }
    }

    @Test("createProject is a no-op returning the existing ref when already registered")
    func createProjectIdempotentWhenRegistered() async throws {
        let store = makeStore()
        let first = try await store.createProject(name: "api", in: workspace)
        let second = try await store.createProject(name: "api", in: workspace)
        #expect(first == second)
        let projects = await store.projects(for: workspace)
        #expect(projects.filter { $0.path == first.path }.count == 1)
    }

    @Test("createProject throws projectFolderExists when the folder exists but is unregistered")
    func createProjectFolderExistsUnregistered() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let folder = workspace.appendingPathComponent("api", isDirectory: true)
        try fs.createDirectory(at: folder, withIntermediates: true)

        await #expect(throws: WorkspaceProjectsStore.StoreError.projectFolderExists(path: folder.path)) {
            try await store.createProject(name: "api", in: workspace)
        }
    }

    @Test("addExistingProject registers an external path and is idempotent")
    func addExistingIdempotent() async throws {
        let store = makeStore()
        let external = URL(fileURLWithPath: "/elsewhere/lib")
        let a = try await store.addExistingProject(url: external, in: workspace)
        let b = try await store.addExistingProject(url: external, in: workspace)
        #expect(a == b)
        #expect(a.displayName == "lib")
        let projects = await store.projects(for: workspace)
        #expect(projects.filter { $0.path == external.path }.count == 1)
    }

    @Test("removeProject removes a non-root project but never the seeded root")
    func removeProtectsRoot() async throws {
        let store = makeStore()
        let ref = try await store.createProject(name: "api", in: workspace)

        try await store.removeProject(path: ref.path, in: workspace)
        var projects = await store.projects(for: workspace)
        #expect(!projects.contains { $0.path == ref.path })

        // Removing the root is refused.
        try await store.removeProject(path: workspace.path, in: workspace)
        projects = await store.projects(for: workspace)
        #expect(projects.contains { $0.path == workspace.path })
    }

    @Test("renameProject changes the display label but keeps the path identity")
    func renameKeepsPath() async throws {
        let store = makeStore()
        let ref = try await store.createProject(name: "api", in: workspace)
        let renamed = try await store.renameProject(path: ref.path, to: "Backend", in: workspace)
        #expect(renamed.path == ref.path)
        #expect(renamed.displayName == "Backend")

        let projects = await store.projects(for: workspace)
        #expect(projects.first(where: { $0.path == ref.path })?.displayName == "Backend")
    }

    @Test("renameProject rejects an empty name")
    func renameRejectsEmpty() async throws {
        let store = makeStore()
        let ref = try await store.createProject(name: "api", in: workspace)
        await #expect(throws: WorkspaceProjectsStore.StoreError.self) {
            try await store.renameProject(path: ref.path, to: "   ", in: workspace)
        }
    }

    @Test("removeProject returns the removed ref + index; restoreProject puts it back in place")
    func removeThenRestore() async throws {
        let store = makeStore()
        let a = try await store.createProject(name: "a", in: workspace)
        let b = try await store.createProject(name: "b", in: workspace)
        // Order is [root, a, b]; remove `a` at index 1.
        let removed = try await store.removeProject(path: a.path, in: workspace)
        #expect(removed?.ref == a)
        #expect(removed?.index == 1)

        var projects = await store.projects(for: workspace)
        #expect(projects.map(\.path) == [workspace.path, b.path])

        try await store.restoreProject(removed!, in: workspace)
        projects = await store.projects(for: workspace)
        #expect(projects.map(\.path) == [workspace.path, a.path, b.path])
    }

    @Test("removeProject on the root returns nil and keeps the root")
    func removeRootReturnsNil() async throws {
        let store = makeStore()
        _ = await store.projects(for: workspace)
        let removed = try await store.removeProject(path: workspace.path, in: workspace)
        #expect(removed == nil)
        let projects = await store.projects(for: workspace)
        #expect(projects.contains { $0.path == workspace.path })
    }

    @Test("Round-trip: a fresh store over the same filesystem recovers projects")
    func roundTrip() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        try await store.createProject(name: "api", in: workspace)

        let fresh = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await fresh.load()
        let projects = await fresh.projects(for: workspace)
        #expect(projects.map(\.displayName) == ["ws", "api"])
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
        let projects = await store.projects(for: workspace)
        #expect(projects.count == 1)
        #expect(projects.first?.path == workspace.path)
    }

    // MARK: - Helpers

    private func makeStore(fs: InMemoryFileSystem = InMemoryFileSystem()) -> WorkspaceProjectsStore {
        WorkspaceProjectsStore(environment: FakeEnvironment(), fileSystem: fs)
    }
}
