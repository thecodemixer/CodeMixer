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

    private let workspace = TestPaths.workspace("ws")

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
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let external = URL(fileURLWithPath: "/elsewhere/lib")
        try fs.createDirectory(at: external, withIntermediates: true)
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

    @Test("renameProject keeps a custom agent's display name in sync with the project name")
    func renameUpdatesCustomAgentDisplayName() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let custom = CustomAgentRef(
            id: "custom-acp",
            displayName: "api",
            transport: .agentClientProtocol,
            executablePath: "/opt/custom-acp",
            arguments: ["acp"]
        )
        let ref = try await store.createProject(name: "api", projectType: .custom(custom), in: workspace)
        let renamed = try await store.renameProject(path: ref.path, to: "MongoMixer", in: workspace)
        guard case .custom(let updated) = renamed.projectType else {
            Issue.record("expected custom project type after rename")
            return
        }
        #expect(renamed.displayName == "MongoMixer")
        #expect(updated.displayName == "MongoMixer")
        #expect(updated.executablePath == "/opt/custom-acp")
        #expect(updated.id == "custom-acp")

        let local = ProjectLocalStateStore.load(
            from: URL(fileURLWithPath: renamed.path),
            fileSystem: fs
        )
        guard case .custom(let persisted) = local?.projectType else {
            Issue.record("expected custom project type in project.json")
            return
        }
        #expect(persisted.displayName == "MongoMixer")
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

    @Test("createProject with preferFreshAgentProcess persists dedicated identity")
    func writesPreferFreshIdentity() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(
            name: "fresh",
            projectType: .claudeCode,
            preferFreshAgentProcess: true,
            in: workspace
        )
        #expect(ref.preferFreshAgentProcess)
        if case .dedicated = ref.agentInstanceIdentity {
            // ok
        } else {
            Issue.record("expected dedicated identity")
        }
        let loaded = ProjectLocalStateStore.load(from: URL(fileURLWithPath: ref.path), fileSystem: fs)
        #expect(loaded?.preferFreshAgentProcess == true)
        #expect(loaded?.agentInstanceIdentity == ref.agentInstanceIdentity)
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
        let rootRef = WorkspaceProjectsStore.ProjectRef(path: workspace.path, displayName: "ws", projectType: .claudeCode)
        let apiRef = WorkspaceProjectsStore.ProjectRef(path: api.path, displayName: "api", projectType: .codex)
        try ProjectLocalStateStore.save(ref: rootRef, fileSystem: fs)
        try ProjectLocalStateStore.save(ref: apiRef, fileSystem: fs)
        try WorkspaceLocalStateStore.save(projects: [rootRef, apiRef], to: workspace, fileSystem: fs)

        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        let projects = await store.projects(for: workspace)
        #expect(projects.map(\.path) == [workspace.path, api.path])
        #expect(projects.last?.projectType == .codex)
    }

    @Test("projects(for:) drops catalog rows without project.json and prunes workspace.json")
    func dropsStaleCatalogRows() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let api = workspace.appendingPathComponent("api")
        let ghost = workspace.appendingPathComponent("ghost")
        try fs.createDirectory(at: workspace, withIntermediates: true)
        try fs.createDirectory(at: api, withIntermediates: true)
        try fs.createDirectory(at: ghost, withIntermediates: true)
        let apiRef = WorkspaceProjectsStore.ProjectRef(path: api.path, displayName: "api", projectType: .codex)
        let ghostRef = WorkspaceProjectsStore.ProjectRef(path: ghost.path, displayName: "ghost", projectType: .claudeCode)
        try ProjectLocalStateStore.save(ref: apiRef, fileSystem: fs)
        try WorkspaceLocalStateStore.save(projects: [apiRef, ghostRef], to: workspace, fileSystem: fs)

        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        let projects = await store.projects(for: workspace)

        #expect(projects.map(\.path) == [api.path])
        let local = WorkspaceLocalStateStore.load(from: workspace, fileSystem: fs)
        #expect(local?.projects.map(\.path) == [api.path])
    }

    @Test("markActiveWorkspace does not wipe an on-disk workspace.json catalog")
    func markActiveDoesNotWipeWorkspaceLocalCatalog() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let api = workspace.appendingPathComponent("api")
        try fs.createDirectory(at: workspace, withIntermediates: true)
        try fs.createDirectory(at: api, withIntermediates: true)
        let catalog = [
            WorkspaceProjectsStore.ProjectRef(path: api.path, displayName: "api", projectType: .claudeCode),
        ]
        try ProjectLocalStateStore.save(ref: catalog[0], fileSystem: fs)
        try WorkspaceLocalStateStore.save(projects: catalog, to: workspace, fileSystem: fs)

        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        try await store.markActiveWorkspace(workspace)

        let local = WorkspaceLocalStateStore.load(from: workspace, fileSystem: fs)
        #expect(local?.projects.map(\.path) == [api.path])
        #expect(await store.activeWorkspaceURL()?.path == workspace.path)
        #expect(await store.resolveProjectType(for: workspace) == nil)
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

    @Test("loading schema-v2 workspace.json ignores legacy adapterModelCaches")
    func ignoresV2AdapterModelCaches() throws {
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
        #expect(loaded?.schemaVersion == WorkspaceLocalState.currentSchemaVersion)
        #expect(loaded?.projects.count == 1)

        let adapterURL = ProjectPaths.workspaceAdapterStateURL(in: workspace, agentID: .claudeCode)
        #expect(!fs.fileExists(at: adapterURL))
        let cached = WorkspaceAdapterLocalStateStore.cachedModels(
            for: .claudeCode,
            in: workspace,
            fileSystem: fs
        )
        #expect(cached == nil)

        // Re-load normalizes the schema and drops unknown legacy fields.
        let rewritten = try fs.readData(at: ProjectPaths.workspaceStateURL(in: workspace))
        let json = try JSONSerialization.jsonObject(with: rewritten) as? [String: Any]
        #expect(json?["adapterModelCaches"] == nil)
        #expect(json?["schemaVersion"] as? Int == WorkspaceLocalState.currentSchemaVersion)
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
        let rootRef = WorkspaceProjectsStore.ProjectRef(
            path: workspace.path,
            displayName: "ws",
            projectType: .claudeCode
        )
        try ProjectLocalStateStore.save(ref: rootRef, fileSystem: fs)
        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        #expect(await store.activeWorkspaceURL() == nil)
        let projects = await store.projects(for: workspace)
        #expect(projects.first?.displayName == "ws")
    }

    @Test("Folder project types round-trip through local project state")
    func folderProjectRoundTrip() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(name: "docs", projectType: .folder(.docs), in: workspace)
        #expect(ref.projectType == .folder(.docs))
        let local = ProjectLocalStateStore.load(from: URL(fileURLWithPath: ref.path), fileSystem: fs)
        #expect(local?.projectType == .folder(.docs))

        let fresh = makeStore(fs: fs)
        await fresh.load()
        let projects = await fresh.projects(for: workspace)
        #expect(projects.contains { $0.path == ref.path && $0.projectType == .folder(.docs) })
    }

    @Test("Folder tree project types round-trip through local project state")
    func folderTreeProjectRoundTrip() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(name: "tree", projectType: .folder(.folderTree), in: workspace)
        #expect(ref.projectType == .folder(.folderTree))
        let local = ProjectLocalStateStore.load(from: URL(fileURLWithPath: ref.path), fileSystem: fs)
        #expect(local?.projectType == .folder(.folderTree))
        #expect(local?.schemaVersion == ProjectLocalState.currentSchemaVersion)

        let fresh = makeStore(fs: fs)
        await fresh.load()
        let projects = await fresh.projects(for: workspace)
        #expect(projects.contains { $0.path == ref.path && $0.projectType == .folder(.folderTree) })
    }

    @Test("Web pages project persists pages and session store id")
    func webPagesProjectRoundTrip() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let storeID = UUID()
        let config = WebPagesProjectConfig(
            pages: [
                WebPageEntry(displayName: "App", urlString: "https://app.example.com"),
                WebPageEntry(displayName: "Docs", urlString: "docs.example.com"),
            ],
            sessionStoreIdentifier: storeID
        )
        let ref = try await store.createProject(
            name: "webapps",
            projectType: .webPages,
            webPages: config,
            in: workspace
        )
        #expect(ref.projectType == .webPages)
        let local = ProjectLocalStateStore.load(from: URL(fileURLWithPath: ref.path), fileSystem: fs)
        #expect(local?.projectType == .webPages)
        #expect(local?.webPages?.sessionStoreIdentifier == storeID)
        #expect(local?.webPages?.pages.count == 2)
        #expect(local?.webPages?.pages[1].urlString.hasPrefix("https://") == true)
        #expect(local?.folderView == nil)
        #expect(local?.workingDirectoryPath == nil)

        let updated = try ProjectLocalStateStore.updateWebPages(
            [WebPageEntry(displayName: "Only", urlString: "https://only.example.com")],
            in: URL(fileURLWithPath: ref.path),
            fileSystem: fs
        )
        #expect(updated?.pages.count == 1)
        #expect(updated?.sessionStoreIdentifier == storeID)

        let fresh = makeStore(fs: fs)
        await fresh.load()
        let projects = await fresh.projects(for: workspace)
        #expect(projects.contains { $0.path == ref.path && $0.projectType == .webPages })
        let reloaded = ProjectLocalStateStore.load(from: URL(fileURLWithPath: ref.path), fileSystem: fs)
        #expect(reloaded?.webPages?.sessionStoreIdentifier == storeID)
    }

    @Test("Web pages project without a configuration is rejected before the folder exists")
    func webPagesProjectRequiresConfiguration() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        await #expect(throws: WorkspaceProjectsStore.StoreError.missingWebPagesConfiguration(name: "webapps")) {
            try await store.createProject(name: "webapps", projectType: .webPages, in: workspace)
        }
        #expect(!fs.isDirectory(at: workspace.appendingPathComponent("webapps", isDirectory: true)))
        #expect(await store.projects(for: workspace).isEmpty)
    }

    @Test("v6 project.json without webPages still loads under the current schema")
    func legacyProjectJSONWithoutWebPagesLoads() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(
            name: "legacy tree",
            projectType: .folder(.folderTree),
            folderView: FolderViewState(pinnedRelativePaths: ["notes.md"]),
            in: workspace
        )
        // Rewrite the file as a pre-web-pages v6 document.
        let root = URL(fileURLWithPath: ref.path)
        let url = ProjectPaths.projectStateURL(in: root)
        var raw = try #require(
            try JSONSerialization.jsonObject(with: fs.readData(at: url)) as? [String: Any]
        )
        raw["schemaVersion"] = 6
        raw.removeValue(forKey: "webPages")
        try fs.writeAtomically(try JSONSerialization.data(withJSONObject: raw), to: url)

        let loaded = ProjectLocalStateStore.load(from: root, fileSystem: fs)
        #expect(loaded?.displayName == "legacy tree")
        #expect(loaded?.projectType == .folder(.folderTree))
        #expect(loaded?.webPages == nil)
        #expect(loaded?.folderView?.pinnedRelativePaths == ["notes.md"])

        // Rewriting a legacy file upgrades it to the web-pages-aware schema.
        try ProjectLocalStateStore.save(try #require(loaded), to: root, fileSystem: fs)
        let upgraded = ProjectLocalStateStore.load(from: root, fileSystem: fs)
        #expect(upgraded?.schemaVersion == ProjectLocalState.currentSchemaVersion)
        #expect(upgraded?.webPages == nil)
    }

    @Test("Dual folder tree persists secondary root and drops it for other kinds")
    func dualFolderTreeSecondaryRootRoundTrip() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let compare = workspace.appendingPathComponent("compare-root", isDirectory: true)
        try fs.createDirectory(at: compare, withIntermediates: true)
        let folderView = FolderViewState(
            pinnedRelativePaths: ["should-be-dropped.md"],
            secondaryRootPath: compare.path
        )
        let ref = try await store.createProject(
            name: "dual",
            projectType: .folder(.dualFolderTree),
            folderView: folderView,
            in: workspace
        )
        let root = URL(fileURLWithPath: ref.path)
        let local = ProjectLocalStateStore.load(from: root, fileSystem: fs)
        #expect(local?.projectType == .folder(.dualFolderTree))
        #expect(local?.folderView?.secondaryRootPath == compare.standardizedFileURL.path)
        #expect(local?.folderView?.pinnedRelativePaths.isEmpty == true)

        // Non-dual kinds must not keep a secondary root.
        let files = try await store.createProject(name: "files-only", projectType: .folder(.files), in: workspace)
        try ProjectLocalStateStore.save(
            ProjectLocalState(
                displayName: files.displayName,
                projectType: .folder(.files),
                folderView: FolderViewState(pinnedRelativePaths: [], secondaryRootPath: compare.path)
            ),
            to: URL(fileURLWithPath: files.path),
            fileSystem: fs
        )
        let filesLocal = ProjectLocalStateStore.load(
            from: URL(fileURLWithPath: files.path),
            fileSystem: fs
        )
        #expect(filesLocal?.folderView?.secondaryRootPath == nil)

        // Reject same-as-primary and relative paths.
        #expect(throws: ProjectLocalStateStore.StoreSecondaryRootError.sameAsPrimary(path: root.path)) {
            try ProjectLocalStateStore.validateSecondaryRoot(root, primaryRoot: root, fileSystem: fs)
        }
        #expect(ProjectLocalState.normalizedSecondaryRootPath("relative/path") == nil)
        #expect(ProjectLocalState.normalizedSecondaryRootPath("/tmp/compare") == "/tmp/compare")
    }

    @Test("Rename and reconcile keep the dual compare root")
    func dualFolderTreeSecondaryRootSurvivesRename() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let compare = workspace.appendingPathComponent("compare-rename", isDirectory: true)
        try fs.createDirectory(at: compare, withIntermediates: true)
        let ref = try await store.createProject(
            name: "dual-rename",
            projectType: .folder(.dualFolderTree),
            folderView: FolderViewState(pinnedRelativePaths: [], secondaryRootPath: compare.path),
            in: workspace
        )
        // Renaming moves the folder, so the compare root has to survive the move.
        let renamed = try await store.renameProject(path: ref.path, to: "dual-renamed", in: workspace)
        let renamedRoot = URL(fileURLWithPath: renamed.path)
        let afterRename = ProjectLocalStateStore.load(from: renamedRoot, fileSystem: fs)
        #expect(afterRename?.displayName == "dual-renamed")
        #expect(afterRename?.folderView?.secondaryRootPath == compare.standardizedFileURL.path)

        // A reload rebuilds the catalog from disk; the compare root must survive.
        let reloaded = makeStore(fs: fs)
        await reloaded.load()
        let projects = await reloaded.projects(for: workspace)
        #expect(projects.contains { $0.path == renamed.path })
        let afterReload = ProjectLocalStateStore.load(from: renamedRoot, fileSystem: fs)
        #expect(afterReload?.folderView?.secondaryRootPath == compare.standardizedFileURL.path)

        // A compare folder that later disappears must not break metadata writes.
        try fs.remove(at: compare)
        let offlineRef = try await store.renameProject(
            path: renamed.path,
            to: "dual-offline",
            in: workspace
        )
        let offline = ProjectLocalStateStore.load(
            from: URL(fileURLWithPath: offlineRef.path),
            fileSystem: fs
        )
        #expect(offline?.displayName == "dual-offline")
        #expect(offline?.folderView?.secondaryRootPath == compare.standardizedFileURL.path)
    }

    @Test("Creating a dual project rejects a missing or colliding compare root")
    func dualFolderTreeRejectsInvalidSecondaryRoot() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)

        await #expect(throws: ProjectLocalStateStore.StoreSecondaryRootError.missing) {
            try await store.createProject(
                name: "dual-missing-view",
                projectType: .folder(.dualFolderTree),
                in: workspace
            )
        }
        // The rejected project must not be half-created.
        #expect(!fs.isDirectory(at: workspace.appendingPathComponent("dual-missing-view")))
        #expect(await store.projects(for: workspace).isEmpty)

        let absent = workspace.appendingPathComponent("not-there", isDirectory: true)
        await #expect(throws: FileSystemError.notFound(path: absent.standardizedFileURL.path)) {
            try await store.createProject(
                name: "dual-absent-compare",
                projectType: .folder(.dualFolderTree),
                folderView: FolderViewState(pinnedRelativePaths: [],
                                            secondaryRootPath: absent.path),
                in: workspace
            )
        }

        #expect(throws: ProjectLocalStateStore.StoreSecondaryRootError.missing) {
            try ProjectLocalStateStore.validatedDualFolderView(
                FolderViewState(pinnedRelativePaths: [], secondaryRootPath: "relative/compare"),
                primaryRoot: workspace,
                fileSystem: fs
            )
        }

        let collision = workspace.appendingPathComponent("dual-collision", isDirectory: true)
        await #expect(throws: ProjectLocalStateStore.StoreSecondaryRootError
            .sameAsPrimary(path: collision.standardizedFileURL.path)) {
            try await store.createProject(
                name: "dual-collision",
                projectType: .folder(.dualFolderTree),
                folderView: FolderViewState(pinnedRelativePaths: [],
                                            secondaryRootPath: collision.path),
                in: workspace
            )
        }
        #expect(!fs.isDirectory(at: collision))
    }

    @Test("Project local state ignores a newer schema rather than decoding it")
    func projectLocalStateRefusesNewerSchema() throws {
        let fs = InMemoryFileSystem()
        let root = workspace.appendingPathComponent("future-project")
        try fs.createDirectory(at: root, withIntermediates: true)
        let url = ProjectPaths.projectStateURL(in: root)
        let future = """
        {"schemaVersion":999,"displayName":"future","agentMode":{"folder":{"folderTree":{}}}}
        """
        try fs.writeAtomically(Data(future.utf8), to: url)
        #expect(ProjectLocalStateStore.load(from: root, fileSystem: fs) == nil)
    }

    @Test("Pinned folder paths persist and reject absolute paths")
    func folderPinsPersistAndRejectAbsolute() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(name: "files", projectType: .folder(.files), in: workspace)
        let root = URL(fileURLWithPath: ref.path)
        try fs.writeAtomically(Data("hello".utf8), to: root.appendingPathComponent("readme.md"))
        try fs.writeAtomically(Data("x".utf8), to: root.appendingPathComponent("notes.txt"))

        let updated = try ProjectLocalStateStore.updatePinnedRelativePaths(
            ["readme.md", "/etc/passwd", "notes.txt", "readme.md"],
            in: root,
            fileSystem: fs
        )
        #expect(updated?.pinnedRelativePaths == ["readme.md", "notes.txt"])

        // Metadata rewrite preserves pins.
        try ProjectLocalStateStore.save(ref: ref, fileSystem: fs)
        let reloaded = ProjectLocalStateStore.load(from: root, fileSystem: fs)
        #expect(reloaded?.folderView?.pinnedRelativePaths == ["readme.md", "notes.txt"])

        // Switching to logs clears pins.
        let logsRef = WorkspaceProjectsStore.ProjectRef(
            path: ref.path,
            displayName: ref.displayName,
            projectType: .folder(.logs)
        )
        try ProjectLocalStateStore.save(ref: logsRef, fileSystem: fs)
        let cleared = ProjectLocalStateStore.load(from: root, fileSystem: fs)
        #expect(cleared?.folderView == nil)
    }

    @Test("Folder scanner skips hidden directories and reports truncation")
    func folderScannerSkipsAndCaps() throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("scan-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.writeAtomically(Data("a".utf8), to: root.appendingPathComponent("a.txt"))
        try fs.createDirectory(at: root.appendingPathComponent(".git"), withIntermediates: true)
        try fs.writeAtomically(Data("secret".utf8), to: root.appendingPathComponent(".git/config"))
        try fs.createDirectory(at: root.appendingPathComponent(".codemixer"), withIntermediates: true)
        try fs.writeAtomically(Data("{}".utf8), to: root.appendingPathComponent(".codemixer/project.json"))

        let result = try FolderScanner.scanDetailed(root: root, fileSystem: fs, maxEntries: 1)
        #expect(result.entries.count == 1)
        #expect(result.truncated)
        #expect(!result.entries.contains { $0.relativePath.contains(".git") })
        #expect(!result.entries.contains { $0.relativePath.contains(".codemixer") })
    }

    // MARK: - Working directory override

    @Test("createProject persists an absolute working-directory override")
    func createProjectPersistsWorkingDirectory() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let source = TestPaths.workspace("source-code")
        try fs.createDirectory(at: source, withIntermediates: true)
        let ref = try await store.createProject(
            name: "api",
            projectType: .claudeCode,
            workingDirectory: source,
            in: workspace
        )
        #expect(ref.workingDirectoryPath == source.path)
        #expect(ref.workingDirectoryURL.path == source.path)
        let loaded = ProjectLocalStateStore.load(from: URL(fileURLWithPath: ref.path), fileSystem: fs)
        #expect(loaded?.workingDirectoryPath == source.path)
        let catalog = await store.projects(for: workspace)
        #expect(catalog.first?.workingDirectoryPath == source.path)
    }

    @Test("working directory equal to the project folder stores nil")
    func workingDirectoryEqualToProjectNormalizesNil() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let ref = try await store.createProject(name: "api", projectType: .claudeCode, in: workspace)
        let projectRoot = URL(fileURLWithPath: ref.path)
        let updated = try await store.setWorkingDirectory(
            path: ref.path,
            to: projectRoot,
            in: workspace
        )
        #expect(updated.workingDirectoryPath == nil)
        #expect(updated.workingDirectoryURL.path == ref.path)
    }

    @Test("folder projects reject a working-directory override")
    func folderProjectsClearWorkingDirectory() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let source = TestPaths.workspace("source-code")
        try fs.createDirectory(at: source, withIntermediates: true)
        let ref = try await store.createProject(
            name: "docs",
            projectType: .folder(.files),
            workingDirectory: source,
            in: workspace
        )
        #expect(ref.workingDirectoryPath == nil)
    }

    @Test("renameProject preserves workingDirectoryPath")
    func renamePreservesWorkingDirectory() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let source = TestPaths.workspace("source-code")
        try fs.createDirectory(at: source, withIntermediates: true)
        let ref = try await store.createProject(
            name: "api",
            projectType: .claudeCode,
            workingDirectory: source,
            in: workspace
        )
        let renamed = try await store.renameProject(path: ref.path, to: "Backend", in: workspace)
        #expect(renamed.workingDirectoryPath == source.path)
    }

    @Test("setWorkingDirectory writes index and project.json")
    func setWorkingDirectoryPersists() async throws {
        let fs = InMemoryFileSystem()
        let store = makeStore(fs: fs)
        let source = TestPaths.workspace("source-code")
        try fs.createDirectory(at: source, withIntermediates: true)
        let ref = try await store.createProject(name: "api", projectType: .claudeCode, in: workspace)
        let updated = try await store.setWorkingDirectory(
            path: ref.path,
            to: source,
            in: workspace
        )
        #expect(updated.workingDirectoryPath == source.path)
        let loaded = ProjectLocalStateStore.load(from: URL(fileURLWithPath: ref.path), fileSystem: fs)
        #expect(loaded?.workingDirectoryPath == source.path)
        let catalog = WorkspaceLocalStateStore.load(from: workspace, fileSystem: fs)
        #expect(catalog?.projects.first?.workingDirectoryPath == source.path)
    }

    @Test("old project.json without workingDirectoryPath still loads")
    func oldProjectJSONWithoutWorkingDirectoryLoads() throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("legacy-project")
        try fs.createDirectory(at: ProjectPaths.directoryURL(in: root), withIntermediates: true)
        let json = """
        {"schemaVersion":5,"displayName":"legacy","agentMode":{"claudeCode":{}},"preferFreshAgentProcess":false}
        """
        try fs.writeAtomically(Data(json.utf8), to: ProjectPaths.projectStateURL(in: root))
        let loaded = ProjectLocalStateStore.load(from: root, fileSystem: fs)
        #expect(loaded?.displayName == "legacy")
        #expect(loaded?.workingDirectoryPath == nil)
        #expect(loaded?.projectType == .claudeCode)
    }

    // MARK: - Helpers

    private func makeStore(fs: InMemoryFileSystem = InMemoryFileSystem()) -> WorkspaceProjectsStore {
        WorkspaceProjectsStore(environment: FakeEnvironment(), fileSystem: fs)
    }
}
