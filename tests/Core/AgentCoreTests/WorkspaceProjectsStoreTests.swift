import Testing
import Foundation
@testable import AgentCore
import AgentProtocol
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
        let projects = await store.projects(for: workspace, rootProjectType: .claudeCode)
        #expect(projects.count == 1)
        #expect(projects.first?.path == workspace.path)
        #expect(projects.first?.displayName == "ws")
    }

    @Test("createProject creates a subfolder and registers it without seeding the workspace root")
    func createProjectRegisters() async throws {
        let store = makeStore()
        let ref = try await store.createProject(name: "api", projectType: .claudeCode, in: workspace)
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
                try await store.createProject(name: bad, projectType: .claudeCode, in: workspace)
            }
        }
    }

    @Test("createProject is a no-op returning the existing ref when already registered")
    func createProjectIdempotentWhenRegistered() async throws {
        let store = makeStore()
        let first = try await store.createProject(name: "api", projectType: .claudeCode, in: workspace)
        let second = try await store.createProject(name: "api", projectType: .claudeCode, in: workspace)
        #expect(first == second)
        let projects = await store.projects(for: workspace, rootProjectType: .claudeCode)
        #expect(projects.filter { $0.path == first.path }.count == 1)
    }

    @Test("createProject throws projectFolderExists when the folder exists but is unregistered")
    func createProjectFolderExistsUnregistered() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let folder = workspace.appendingPathComponent("api", isDirectory: true)
        try fs.createDirectory(at: folder, withIntermediates: true)

        await #expect(throws: WorkspaceProjectsStore.StoreError.projectFolderExists(path: folder.path)) {
            try await store.createProject(name: "api", projectType: .claudeCode, in: workspace)
        }
    }

    @Test("addExistingProject registers an external path and is idempotent")
    func addExistingIdempotent() async throws {
        let store = makeStore()
        let external = URL(fileURLWithPath: "/elsewhere/lib")
        let a = try await store.addExistingProject(url: external, projectType: .codex, in: workspace)
        let b = try await store.addExistingProject(url: external, projectType: .codex, in: workspace)
        #expect(a == b)
        #expect(a.displayName == "lib")
        let projects = await store.projects(for: workspace, rootProjectType: .claudeCode)
        #expect(projects.filter { $0.path == external.path }.count == 1)
    }

    @Test("project(path:) finds project refs across loaded workspaces")
    func projectLookupByPath() async throws {
        let store = makeStore()
        let ref = try await store.createProject(name: "api", projectType: .codex, in: workspace)

        let found = await store.project(path: ref.path)

        #expect(found == ref)
    }

    @Test("removeProject removes a non-root project but never the seeded root")
    func removeProtectsRoot() async throws {
        let store = makeStore()
        let ref = try await store.createProject(name: "api", projectType: .claudeCode, in: workspace)

        try await store.removeProject(path: ref.path, in: workspace)
        var projects = await store.projects(for: workspace, rootProjectType: .claudeCode)
        #expect(!projects.contains { $0.path == ref.path })

        // Removing the root is refused.
        try await store.removeProject(path: workspace.path, in: workspace)
        projects = await store.projects(for: workspace, rootProjectType: .claudeCode)
        #expect(projects.contains { $0.path == workspace.path })
    }

    @Test("renameProject renames the folder and updates persisted refs")
    func renameRenamesFolder() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(name: "api", projectType: .claudeCode, in: workspace)
        let renamed = try await store.renameProject(path: ref.path, to: "Backend", in: workspace)
        let renamedPath = workspace.appendingPathComponent("Backend").path
        #expect(renamed.path == renamedPath)
        #expect(renamed.displayName == "Backend")
        #expect(!fs.isDirectory(at: URL(fileURLWithPath: ref.path)))
        #expect(fs.isDirectory(at: URL(fileURLWithPath: renamedPath)))

        let projects = await store.projects(for: workspace, rootProjectType: .claudeCode)
        #expect(projects.first(where: { $0.path == renamedPath })?.displayName == "Backend")

        let local = ProjectLocalStateStore.load(from: URL(fileURLWithPath: renamedPath), fileSystem: fs)
        #expect(local?.displayName == "Backend")
        #expect(local?.projectType == .claudeCode)

        let workspaceLocal = WorkspaceLocalStateStore.load(from: workspace, fileSystem: fs)
        #expect(workspaceLocal?.projects.map(\.path) == [renamedPath])
    }

    @Test("renameProject rejects an empty name")
    func renameRejectsEmpty() async throws {
        let store = makeStore()
        let ref = try await store.createProject(name: "api", projectType: .claudeCode, in: workspace)
        await #expect(throws: WorkspaceProjectsStore.StoreError.self) {
            try await store.renameProject(path: ref.path, to: "   ", in: workspace)
        }
    }

    @Test("renameProject rejects an existing destination folder")
    func renameRejectsExistingDestination() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(name: "api", projectType: .claudeCode, in: workspace)
        let existing = workspace.appendingPathComponent("Backend", isDirectory: true)
        try fs.createDirectory(at: existing, withIntermediates: true)

        await #expect(throws: WorkspaceProjectsStore.StoreError.projectFolderExists(path: existing.path)) {
            try await store.renameProject(path: ref.path, to: "Backend", in: workspace)
        }
    }

    @Test("renameProject rejects the workspace root folder")
    func renameRejectsWorkspaceRoot() async {
        let store = makeStore()
        _ = await store.projects(for: workspace, rootProjectType: .claudeCode)

        await #expect(throws: WorkspaceProjectsStore.StoreError.cannotRenameWorkspaceRoot(path: workspace.path)) {
            try await store.renameProject(path: workspace.path, to: "Workspace", in: workspace)
        }
    }

    @Test("removeProject returns the removed ref + index; restoreProject puts it back in place")
    func removeThenRestore() async throws {
        let store = makeStore()
        let a = try await store.createProject(name: "a", projectType: .claudeCode, in: workspace)
        let b = try await store.createProject(name: "b", projectType: .codex, in: workspace)
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
        _ = await store.projects(for: workspace, rootProjectType: .claudeCode)
        let removed = try await store.removeProject(path: workspace.path, in: workspace)
        #expect(removed == nil)
        let projects = await store.projects(for: workspace, rootProjectType: .claudeCode)
        #expect(projects.contains { $0.path == workspace.path })
    }

    @Test("Round-trip: a fresh store over the same filesystem recovers projects")
    func roundTrip() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        try await store.createProject(name: "api", projectType: .claudeCode, in: workspace)

        let fresh = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await fresh.load()
        let projects = await fresh.projects(for: workspace)
        #expect(projects.map(\.displayName) == ["api"])
    }

    @Test("createProject writes project type into the project folder")
    func writesProjectLocalState() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(name: "api", projectType: .codex, in: workspace)
        let localURL = ProjectPaths.projectStateURL(in: URL(fileURLWithPath: ref.path))
        #expect(fs.fileExists(at: localURL))
        let loaded = ProjectLocalStateStore.load(from: URL(fileURLWithPath: ref.path), fileSystem: fs)
        #expect(loaded?.projectType == .codex)
        #expect(loaded?.displayName == "api")
    }

    @Test("resolveProjectType prefers project-local state over the workspace index")
    func resolvePrefersLocalFile() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(name: "api", projectType: .claudeCode, in: workspace)
        let projectRoot = URL(fileURLWithPath: ref.path)
        try ProjectLocalStateStore.save(
            ProjectLocalState(displayName: "api", projectType: .codex),
            to: projectRoot,
            fileSystem: fs
        )
        let mode = await store.resolveProjectType(for: projectRoot)
        #expect(mode == .codex)
    }

    @Test("projects(for:) seeds from project-local state when rootProjectType is omitted")
    func seedsFromLocalState() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        try ProjectLocalStateStore.save(
            ProjectLocalState(displayName: "ws", projectType: .codex),
            to: workspace,
            fileSystem: fs
        )
        let projects = await store.projects(for: workspace)
        #expect(projects.count == 1)
        #expect(projects.first?.projectType == .codex)
    }

    @Test("createProject writes workspace.json catalog in the workspace folder")
    func writesWorkspaceLocalCatalog() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(name: "api", projectType: .codex, in: workspace)
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
            WorkspaceProjectsStore.ProjectRef(path: workspace.path, displayName: "ws", projectType: .claudeCode),
            WorkspaceProjectsStore.ProjectRef(path: api.path, displayName: "api", projectType: .codex),
        ]
        try WorkspaceLocalStateStore.save(projects: catalog, to: workspace, fileSystem: fs)

        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        let projects = await store.projects(for: workspace)
        #expect(projects.map(\.path) == [workspace.path, api.path])
        #expect(projects.last?.projectType == .codex)
    }

    @Test("saveModels writes per-adapter file and preserves project catalog")
    func saveModelsPreservesProjects() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(name: "api", projectType: .claudeCode, in: workspace)
        let models = [
            AgentModelOption(code: "sonnet", name: "Sonnet", thinkingEffort: "medium"),
            AgentModelOption(code: "opus", name: "Opus"),
        ]
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        try await store.saveModels(models, for: .claudeCode, refreshedAt: stamped, in: workspace)

        let cached = await store.cachedModels(for: .claudeCode, in: workspace)
        #expect(cached?.models.map(\.code) == ["sonnet", "opus"])
        #expect(cached?.refreshedAt == stamped)

        let local = WorkspaceLocalStateStore.load(from: workspace, fileSystem: fs)
        #expect(local?.schemaVersion == WorkspaceLocalState.currentSchemaVersion)
        #expect(local?.projects.map(\.path) == [ref.path])
        #expect(fs.fileExists(at: ProjectPaths.workspaceAdapterStateURL(in: workspace, agentID: .claudeCode)))

        // Project-only saves must not wipe the model cache.
        try WorkspaceLocalStateStore.save(projects: local!.projects, to: workspace, fileSystem: fs)
        let stillCached = await store.cachedModels(for: .claudeCode, in: workspace)
        #expect(stillCached?.models.map(\.code) == ["sonnet", "opus"])
    }

    @Test("loading schema-v2 workspace.json migrates adapterModelCaches to per-adapter files")
    func migratesV2AdapterModelCaches() throws {
        let fs = InMemoryFileSystem()
        try fs.createDirectory(at: ProjectPaths.directoryURL(in: workspace), withIntermediates: true)
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        struct LegacyV2: Encodable {
            var schemaVersion = 2
            var projects: [WorkspaceProjectsStore.ProjectRef]
            var adapterModelCaches: [String: WorkspaceAdapterLocalState.CachedAdapterModels]
        }
        let legacy = LegacyV2(
            projects: [
                .init(path: workspace.path, displayName: "ws", projectType: .claudeCode),
            ],
            adapterModelCaches: [
                "claudeCode": .init(
                    models: [AgentModelOption(code: "sonnet", name: "Sonnet")],
                    refreshedAt: stamped
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fs.writeAtomically(
            try encoder.encode(legacy),
            to: ProjectPaths.workspaceStateURL(in: workspace)
        )

        let loaded = WorkspaceLocalStateStore.load(from: workspace, fileSystem: fs)
        #expect(loaded?.schemaVersion == 3)
        #expect(loaded?.projects.count == 1)

        let adapterURL = ProjectPaths.workspaceAdapterStateURL(in: workspace, agentID: .claudeCode)
        #expect(fs.fileExists(at: adapterURL))
        let cached = WorkspaceAdapterLocalStateStore.cachedModels(
            for: .claudeCode,
            in: workspace,
            fileSystem: fs
        )
        #expect(cached?.models.map(\.code) == ["sonnet"])

        // Re-load must not leave adapterModelCaches in workspace.json.
        let rewritten = try fs.readData(at: ProjectPaths.workspaceStateURL(in: workspace))
        let json = try JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        #expect(json?["adapterModelCaches"] == nil)
        #expect(json?["schemaVersion"] as? Int == 3)
    }

    @Test("markActiveWorkspace / clearActiveWorkspace round-trip through workspaces.json")
    func activeWorkspaceRoundTrip() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        try fs.createDirectory(at: workspace, withIntermediates: true)
        _ = await store.projects(for: workspace, rootProjectType: .claudeCode)
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
        let projects = await store.projects(for: workspace, rootProjectType: .claudeCode)
        #expect(projects.count == 1)
        #expect(projects.first?.path == workspace.path)
    }

    @Test("load() accepts schema v2 files without activeWorkspacePath")
    func loadsSchemaV2WithoutActive() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let url = env.appSupportDirectory.appendingPathComponent("workspaces.json")
        let v2 = """
        {"schemaVersion":2,"workspaces":[{"workspacePath":"\(workspace.path)","projects":[{"path":"\(workspace.path)","displayName":"ws","projectType":{"claudeCode":{}}}]}]}
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
