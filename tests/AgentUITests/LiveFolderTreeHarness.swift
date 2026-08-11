import Foundation
import os
import Testing
@testable import AgentUI
@testable import AgentCore
@testable import AgentTestSupport
import AgentProtocol

/// Opt-in harness that drives the production `folderTree` path against the real
/// filesystem: real `SystemFileSystem` reads, a real `FSEventsWatcher` stream,
/// and real `.codemixer/project.json` writes.
///
/// The unit suites cover this surface with `InMemoryFileSystem`, which cannot
/// prove the two things that only exist at runtime: that FSEvents actually
/// delivers into `FolderTreeViewModel.refresh()`, and that a folder-tree
/// project survives a real round-trip through disk.
///
/// Enable with:
///
/// ```bash
/// CODEMIXER_LIVE_FOLDER_TREE=1 scripts/swift-test.swift --allow-live \
///   --filter LiveFolderTreeIntegrationTests
/// ```
///
/// Everything is created under the process temp dir and removed afterwards, so
/// the harness never touches a real workspace or the user's Application Support.
struct LiveFolderTreeHarness {
    static let enableVariable = "CODEMIXER_LIVE_FOLDER_TREE"

    static func isEnabled(environment: any AgentEnvironment = SystemEnvironment()) -> Bool {
        environment.processEnvironment()[enableVariable] == "1"
    }

    struct Fixture {
        let root: URL
        let home: URL
        let fileSystem: any FileSystem

        func url(_ relativePath: String) -> URL {
            root.appendingPathComponent(relativePath)
        }
    }

    /// Materialises a realistic project tree on disk, including two directories
    /// the scanner must skip (`.git`, `node_modules`).
    static func makeFixture(named name: String) throws -> Fixture {
        let fileSystem = SystemFileSystem()
        let home = TestPaths.underTemporary("codemixer-live-folder-tree/\(name)")
        let root = home.appendingPathComponent("project", isDirectory: true)
        if fileSystem.fileExists(at: home) {
            try? fileSystem.remove(at: home)
        }
        for directory in ["src/Folder", "src/Core", "docs", "assets", ".git", "node_modules/pkg"] {
            try fileSystem.createDirectory(
                at: root.appendingPathComponent(directory),
                withIntermediates: true
            )
        }

        try write("# Live Fixture\n\nBody text for the live harness.\n", to: root.appendingPathComponent("README.md"), fileSystem)
        try write("# Guide\n\nSecond markdown document.\n", to: root.appendingPathComponent("docs/guide.md"), fileSystem)
        try write("plain notes\n", to: root.appendingPathComponent("docs/notes.txt"), fileSystem)
        try write("struct FolderTreeView {}\n", to: root.appendingPathComponent("src/Folder/FolderTreeView.swift"), fileSystem)
        try write("print(\"main\")\n", to: root.appendingPathComponent("src/Core/main.swift"), fileSystem)
        try write("ignored\n", to: root.appendingPathComponent(".git/config"), fileSystem)
        try write("module.exports = {}\n", to: root.appendingPathComponent("node_modules/pkg/index.js"), fileSystem)

        // A PNG header plus a NUL byte — what `isLikelyBinary` keys on.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x01, 0x02])
        try fileSystem.writeAtomically(png, to: root.appendingPathComponent("assets/logo.png"))

        return Fixture(root: root, home: home, fileSystem: fileSystem)
    }

    static func tearDown(_ fixture: Fixture) {
        try? fixture.fileSystem.remove(at: fixture.home)
        // Drop the shared container too, but only once the last fixture is gone.
        let container = fixture.home.deletingLastPathComponent()
        if let remaining = try? fixture.fileSystem.contentsOfDirectory(at: container),
           remaining.isEmpty {
            try? fixture.fileSystem.remove(at: container)
        }
    }

    /// Writes through a separate process on purpose.
    ///
    /// `FSEventsStream` creates its stream with `kFSEventStreamCreateFlagIgnoreSelf`,
    /// so changes made by the watching process are deliberately invisible — that
    /// is what stops a self-triggered refresh loop. A faithful live test has to
    /// mutate the tree the way a real edit arrives: from an agent, an editor, or
    /// a shell.
    static func externallyWrite(_ text: String, to url: URL) async throws {
        try await shell("printf %s \(quoted(text)) > \(quoted(url.path))")
    }

    static func externallyRemove(at url: URL) async throws {
        try await shell("rm -f \(quoted(url.path))")
    }

    private static func shell(_ command: String) async throws {
        _ = try await ProcessRunner().run(
            executable: SystemPaths.zsh,
            arguments: ["-c", command]
        )
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func write(_ text: String, to url: URL, _ fileSystem: any FileSystem) throws {
        try fileSystem.writeAtomically(Data(text.utf8), to: url)
    }
}

/// Polls a main-actor condition. FSEvents latency plus the model's scan debounce
/// means the answer is never immediate.
@MainActor
func liveFolderTreePoll(timeout: Duration = .seconds(20),
                        interval: Duration = .milliseconds(50),
                        _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: interval)
    }
    return condition()
}

private final class LiveFolderTreePort: AgentEngineCommandPort, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<[AgentCommand]>(initialState: [])
    var commands: [AgentCommand] { state.withLock { $0 } }
    func send(_ command: AgentCommand) async throws {
        state.withLock { $0.append(command) }
    }
}

@Suite("Folder tree — live filesystem end-to-end", .serialized)
@MainActor
struct LiveFolderTreeIntegrationTests {

    @Test("Real disk scan builds the hierarchy and skips tooling directories")
    func realScanBuildsHierarchy() async throws {
        guard LiveFolderTreeHarness.isEnabled() else { return }
        let fixture = try LiveFolderTreeHarness.makeFixture(named: "scan")
        defer { LiveFolderTreeHarness.tearDown(fixture) }

        let model = FolderTreeViewModel(root: fixture.root)
        model.start()
        defer { model.stop() }

        #expect(await liveFolderTreePoll { !model.isLoading && !model.entries.isEmpty })

        let rootNames = model.treeRoots.map(\.entry.name)
        #expect(rootNames == ["assets", "docs", "src", "README.md"])
        #expect(!model.entries.contains { $0.relativePath.hasPrefix(".git") })
        #expect(!model.entries.contains { $0.relativePath.hasPrefix("node_modules") })

        let src = model.treeRoots.first { $0.entry.name == "src" }
        #expect(src?.children.map(\.entry.name) == ["Core", "Folder"])
        let folder = src?.children.first { $0.entry.name == "Folder" }
        #expect(folder?.children.map(\.entry.relativePath) == ["src/Folder/FolderTreeView.swift"])
        #expect(model.lastRefreshedAt != nil)
        #expect(!model.truncated)
    }

    @Test("FSEvents delivers a new file into the tree without a manual refresh")
    func fsEventsDeliverCreatedFile() async throws {
        guard LiveFolderTreeHarness.isEnabled() else { return }
        let fixture = try LiveFolderTreeHarness.makeFixture(named: "fsevents-create")
        defer { LiveFolderTreeHarness.tearDown(fixture) }

        let model = FolderTreeViewModel(root: fixture.root)
        model.start()
        defer { model.stop() }
        #expect(await liveFolderTreePoll { !model.isLoading && !model.entries.isEmpty })
        #expect(!model.entries.contains { $0.relativePath == "src/Core/added.swift" })

        try await LiveFolderTreeHarness.externallyWrite(
            "let added = true\n",
            to: fixture.url("src/Core/added.swift")
        )

        let arrived = await liveFolderTreePoll {
            model.entries.contains { $0.relativePath == "src/Core/added.swift" }
        }
        #expect(arrived, "FSEvents did not deliver the created file into the model")

        let core = model.treeRoots
            .first { $0.entry.name == "src" }?
            .children.first { $0.entry.name == "Core" }
        #expect(core?.children.map(\.entry.name).contains("added.swift") == true)
    }

    @Test("FSEvents prunes a deleted selection and drops its preview")
    func fsEventsPruneDeletedSelection() async throws {
        guard LiveFolderTreeHarness.isEnabled() else { return }
        let fixture = try LiveFolderTreeHarness.makeFixture(named: "fsevents-delete")
        defer { LiveFolderTreeHarness.tearDown(fixture) }

        let model = FolderTreeViewModel(root: fixture.root)
        model.start()
        defer { model.stop() }
        #expect(await liveFolderTreePoll { !model.isLoading && !model.entries.isEmpty })

        model.select("docs/notes.txt")
        #expect(await liveFolderTreePoll { model.previewMode == .text })
        #expect(model.previewText.contains("plain notes"))

        try await LiveFolderTreeHarness.externallyRemove(at: fixture.url("docs/notes.txt"))

        let pruned = await liveFolderTreePoll {
            model.selectedRelativePath == nil
                && !model.entries.contains { $0.relativePath == "docs/notes.txt" }
        }
        #expect(pruned, "watcher refresh did not prune the deleted selection")
        #expect(model.previewText.isEmpty)
    }

    @Test("Previews read real bytes for markdown, source, and binary files")
    func previewsReadRealBytes() async throws {
        guard LiveFolderTreeHarness.isEnabled() else { return }
        let fixture = try LiveFolderTreeHarness.makeFixture(named: "preview")
        defer { LiveFolderTreeHarness.tearDown(fixture) }

        let model = FolderTreeViewModel(root: fixture.root)
        model.start()
        defer { model.stop() }
        #expect(await liveFolderTreePoll { !model.isLoading && !model.entries.isEmpty })

        model.select("README.md")
        #expect(await liveFolderTreePoll { model.previewMode == .markdown })
        #expect(model.previewText.contains("Live Fixture"))
        #expect(model.previewTitle == "README.md")

        model.setDocsShowSource(true)
        #expect(await liveFolderTreePoll { model.previewMode == .source })
        #expect(model.previewText.contains("# Live Fixture"))
        model.setDocsShowSource(false)

        model.select("src/Folder/FolderTreeView.swift")
        #expect(await liveFolderTreePoll { model.previewMode == .text })
        #expect(model.previewText.contains("struct FolderTreeView"))

        model.select("assets/logo.png")
        #expect(await liveFolderTreePoll { model.previewMode == .image })
        #expect(model.previewText.isEmpty)

        model.select("src")
        #expect(await liveFolderTreePoll { model.previewMode == .none })
        #expect(model.previewTitle == "src")
    }

    @Test("Expansion and filtering survive a live watcher refresh")
    func expansionSurvivesLiveRefresh() async throws {
        guard LiveFolderTreeHarness.isEnabled() else { return }
        let fixture = try LiveFolderTreeHarness.makeFixture(named: "expansion")
        defer { LiveFolderTreeHarness.tearDown(fixture) }

        let model = FolderTreeViewModel(root: fixture.root)
        model.start()
        defer { model.stop() }
        #expect(await liveFolderTreePoll { !model.isLoading && !model.entries.isEmpty })

        model.setExpanded("src", expanded: true)
        model.setExpanded("src/Folder", expanded: true)
        model.searchText = "guide"
        #expect(model.filterMatchCount == 1)
        #expect(model.effectiveExpandedPaths.contains("docs"))

        try await LiveFolderTreeHarness.externallyWrite(
            "# Another\n",
            to: fixture.url("docs/another-guide.md")
        )
        #expect(await liveFolderTreePoll {
            model.entries.contains { $0.relativePath == "docs/another-guide.md" }
        })

        #expect(model.searchText == "guide")
        #expect(model.filterMatchCount == 2)
        #expect(model.expandedPaths.contains("src"))
        #expect(model.expandedPaths.contains("src/Folder"))

        model.clearSearchAndFilters()
        #expect(model.effectiveExpandedPaths == ["src", "src/Folder"])
    }

    @Test("A folderTree project round-trips through real on-disk state and routes in the navigator")
    func projectPersistsOnDiskAndRoutes() async throws {
        guard LiveFolderTreeHarness.isEnabled() else { return }
        let fixture = try LiveFolderTreeHarness.makeFixture(named: "persistence")
        defer { LiveFolderTreeHarness.tearDown(fixture) }

        let fileSystem = SystemFileSystem()
        let environment = FakeEnvironment(home: fixture.home)
        let workspace = fixture.home.appendingPathComponent("workspace", isDirectory: true)
        try fileSystem.createDirectory(at: workspace, withIntermediates: true)

        let store = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        // Production always loads before mutating; `load()` is what creates the
        // Application Support directory that `persist()` then writes into.
        await store.load()
        let ref = try await store.createProject(
            name: "tree",
            projectType: .folder(.folderTree),
            in: workspace
        )
        #expect(ref.projectType == .folder(.folderTree))

        let stateURL = ProjectPaths.projectStateURL(in: URL(fileURLWithPath: ref.path))
        #expect(fileSystem.fileExists(at: stateURL))
        let raw = String(decoding: try fileSystem.readData(at: stateURL), as: UTF8.self)
        #expect(raw.contains("folderTree"))

        // A cold store must recover the kind from disk, not from memory.
        let reopened = WorkspaceProjectsStore(environment: environment, fileSystem: fileSystem)
        await reopened.load()
        let projects = await reopened.projects(for: workspace)
        #expect(projects.contains { $0.path == ref.path && $0.projectType == .folder(.folderTree) })

        let port = LiveFolderTreePort()
        let bus = MulticastEventBus()
        let vm = EngineViewModel(engine: port, bus: bus, clock: SystemClock(), random: FakeRandomSource())
        vm.workspaceProjects = reopened
        await vm.adoptEmptyWorkspace(workspace)
        await vm.applyProjectList(projects)
        vm.selectProject(path: ref.path)

        #expect(vm.showsFolderBrowser)
        #expect(vm.activeFolderProjectKind == .folderTree)
        #expect(port.commands.isEmpty, "a folder project must never start an agent")

        await bus.shutdown()
    }
}
