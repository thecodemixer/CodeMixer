import Foundation
import os
import Testing
@testable import AgentUI
@testable import AgentCore
@testable import AgentTestSupport
import AgentProtocol

@Suite("EngineViewModel — web pages navigator")
@MainActor
struct EngineViewModelWebPagesTests {
    @Test("createProject for web pages opens the viewer without openProject")
    func createWebPagesProjectDoesNotOpenAgent() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store
        vm.projectLocalFileSystem = fileSystem
        vm.subscribe()
        defer { vm.unsubscribe() }

        let workspace = TestPaths.workspace("ws-webpages")
        await vm.adoptEmptyWorkspace(workspace)
        let error = await vm.createOrAddProject(ProjectDraft(
            name: "apps",
            projectType: .webPages,
            webPages: [
                WebPageEntry(displayName: "App", urlString: "https://app.example.com")
            ]
        ))
        #expect(error == nil)
        try? await Task.sleep(for: .milliseconds(40))

        let project = await store.project(path: workspace.appendingPathComponent("apps").path)
        #expect(project?.projectType == .webPages)
        #expect(vm.showsWebPages)
        #expect(vm.activeWebPageID != nil)
        #expect(vm.workspace?.path == project?.path)
        #expect(!port.commands.contains {
            if case .openProject = $0 { return true }
            return false
        })

        await bus.shutdown()
    }

    @Test("selectProject for web pages never sends openProject")
    func selectWebPagesSkipsAgent() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store
        vm.projectLocalFileSystem = fileSystem

        let workspace = TestPaths.workspace("ws-webpages-select")
        await vm.adoptEmptyWorkspace(workspace)
        let ref = try await store.createProject(
            name: "apps",
            projectType: .webPages,
            webPages: WebPagesProjectConfig(
                pages: [WebPageEntry(displayName: "A", urlString: "https://a.example.com")],
                sessionStoreIdentifier: UUID()
            ),
            in: workspace
        )
        await vm.applyProjectList(await store.projects(for: workspace))
        vm.selectProject(path: ref.path)

        #expect(vm.showsWebPages)
        #expect(vm.webPages(for: ref).count == 1)
        #expect(port.commands.isEmpty)

        await bus.shutdown()
    }

    @Test("add remove and move web pages persist and refresh the sidebar list")
    func mutateWebPages() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store
        vm.projectLocalFileSystem = fileSystem

        let workspace = TestPaths.workspace("ws-webpages-mutate")
        await vm.adoptEmptyWorkspace(workspace)
        let ref = try await store.createProject(
            name: "apps",
            projectType: .webPages,
            webPages: WebPagesProjectConfig(pages: [], sessionStoreIdentifier: UUID()),
            in: workspace
        )
        await vm.applyProjectList(await store.projects(for: workspace))
        vm.openWebPagesProject(ref)

        let first = WebPageEntry(displayName: "One", urlString: "https://one.example.com")
        let second = WebPageEntry(displayName: "Two", urlString: "https://two.example.com")
        vm.addWebPage(first, in: ref.path)
        vm.addWebPage(second, in: ref.path)
        #expect(vm.webPages(for: ref).map(\.displayName) == ["One", "Two"])

        vm.moveWebPage(pageID: second.id, in: ref.path, direction: -1)
        #expect(vm.webPages(for: ref).map(\.displayName) == ["Two", "One"])

        vm.removeWebPage(pageID: first.id, in: ref.path)
        #expect(vm.webPages(for: ref).map(\.displayName) == ["Two"])

        let local = ProjectLocalStateStore.load(
            from: URL(fileURLWithPath: ref.path),
            fileSystem: fileSystem
        )
        #expect(local?.webPages?.pages.map(\.displayName) == ["Two"])

        await bus.shutdown()
    }

    @Test("opening an agent project clears the web pages surface")
    func agentSelectClearsWebPages() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store
        vm.projectLocalFileSystem = fileSystem

        let workspace = TestPaths.workspace("ws-webpages-clear")
        await vm.adoptEmptyWorkspace(workspace)
        let web = try await store.createProject(
            name: "apps",
            projectType: .webPages,
            webPages: WebPagesProjectConfig(pages: [], sessionStoreIdentifier: UUID()),
            in: workspace
        )
        let agent = try await store.createProject(name: "api", projectType: .claudeCode, in: workspace)
        await vm.applyProjectList(await store.projects(for: workspace))
        vm.openWebPagesProject(web)
        #expect(vm.showsWebPages)

        vm.selectProject(path: agent.path)
        #expect(!vm.showsWebPages)
        #expect(vm.detailPane == .conversation)

        await bus.shutdown()
    }

    @Test("renaming a web pages project rekeys the cached page list")
    func renameRekeysWebPages() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store
        vm.projectLocalFileSystem = fileSystem

        let workspace = TestPaths.workspace("ws-webpages-rename")
        await vm.adoptEmptyWorkspace(workspace)
        let ref = try await store.createProject(
            name: "apps",
            projectType: .webPages,
            webPages: WebPagesProjectConfig(
                pages: [WebPageEntry(displayName: "A", urlString: "https://a.example.com")],
                sessionStoreIdentifier: UUID()
            ),
            in: workspace
        )
        await vm.applyProjectList(await store.projects(for: workspace))
        vm.openWebPagesProject(ref)
        #expect(vm.webPagesByProject[ref.path]?.count == 1)

        let renamed = workspace.appendingPathComponent("web-apps", isDirectory: true).path
        vm.applyRenamedProjectPath(from: ref.path, to: renamed)
        #expect(vm.webPagesByProject[ref.path] == nil)
        #expect(vm.webPagesByProject[renamed]?.count == 1)

        await bus.shutdown()
    }

    @Test("removing a web pages project wipes its session data immediately")
    func removeClearsSessionData() async throws {
        let port = RecordingPort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: FakeClock(), random: FakeRandomSource())
        let fileSystem = InMemoryFileSystem()
        let environment = FakeEnvironment(home: TestPaths.fakeHome)
        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        vm.workspaceProjects = store
        vm.projectLocalFileSystem = fileSystem
        let cleared = ClearedStoreIDs()
        vm.webSessionDataCleaner = { cleared.append($0) }

        let workspace = TestPaths.workspace("ws-webpages-remove")
        await vm.adoptEmptyWorkspace(workspace)
        let storeID = UUID()
        let ref = try await store.createProject(
            name: "apps",
            projectType: .webPages,
            webPages: WebPagesProjectConfig(
                pages: [WebPageEntry(displayName: "A", urlString: "https://a.example.com")],
                sessionStoreIdentifier: storeID
            ),
            in: workspace
        )
        await vm.applyProjectList(await store.projects(for: workspace))
        vm.openWebPagesProject(ref)

        let generationBefore = vm.webPageReloadGeneration
        vm.removeProject(path: ref.path)
        try? await Task.sleep(for: .milliseconds(60))

        #expect(cleared.identifiers == [storeID])
        #expect(vm.webPageReloadGeneration > generationBefore)

        await bus.shutdown()
    }

    @Test("modelCatalogAgentIDs is empty for web pages")
    func catalogIDs() {
        #expect(EngineViewModel.modelCatalogAgentIDs(for: .webPages).isEmpty)
    }
}

@Suite("ExternalWebPageURLPolicy")
struct ExternalWebPageURLPolicyTests {
    @Test("allows http and https with hosts")
    func allowsHTTP() {
        #expect(ExternalWebPageURLPolicy.allowsNavigation(to: URL(string: "https://example.com")))
        #expect(ExternalWebPageURLPolicy.allowsNavigation(to: URL(string: "http://127.0.0.1:3000")))
    }

    @Test("allows about blank for in-webview iframes and popup bootstrap")
    func allowsAboutBlank() {
        #expect(ExternalWebPageURLPolicy.allowsNavigation(to: URL(string: "about:blank")))
        #expect(!ExternalWebPageURLPolicy.allowsSameViewPopupLoad(to: URL(string: "about:blank")))
        #expect(!ExternalWebPageURLPolicy.shouldOpenExternally(URL(string: "about:blank")))
    }

    @Test("opens mailto tel and sms externally only")
    func opensMailAndPhoneExternally() {
        #expect(ExternalWebPageURLPolicy.shouldOpenExternally(URL(string: "mailto:hi@example.com")))
        #expect(ExternalWebPageURLPolicy.shouldOpenExternally(URL(string: "tel:+15551212")))
        #expect(ExternalWebPageURLPolicy.shouldOpenExternally(URL(string: "sms:+15551212")))
        #expect(!ExternalWebPageURLPolicy.shouldOpenExternally(URL(string: "https://example.com")))
        #expect(!ExternalWebPageURLPolicy.shouldOpenExternally(URL(string: "javascript:alert(1)")))
    }

    @Test("rejects file javascript data and custom schemes")
    func rejectsUnsafe() {
        #expect(!ExternalWebPageURLPolicy.allowsNavigation(to: URL(string: "file:///tmp/x")))
        #expect(!ExternalWebPageURLPolicy.allowsNavigation(to: URL(string: "javascript:alert(1)")))
        #expect(!ExternalWebPageURLPolicy.allowsNavigation(to: URL(string: "data:text/html,hi")))
        #expect(!ExternalWebPageURLPolicy.allowsNavigation(to: URL(string: "codemixer://open")))
        #expect(!ExternalWebPageURLPolicy.allowsNavigation(to: nil))
        #expect(!ExternalWebPageURLPolicy.shouldOpenExternally(URL(string: "file:///tmp/x")))
        #expect(!ExternalWebPageURLPolicy.shouldOpenExternally(URL(string: "data:text/html,hi")))
    }
}

@MainActor
private final class ClearedStoreIDs {
    private(set) var identifiers: [UUID] = []
    func append(_ id: UUID) { identifiers.append(id) }
}

private final class RecordingPort: AgentEngineCommandPort, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<[AgentCommand]>(initialState: [])
    var commands: [AgentCommand] { state.withLock { $0 } }
    func send(_ command: AgentCommand) async throws {
        state.withLock { $0.append(command) }
    }
}
