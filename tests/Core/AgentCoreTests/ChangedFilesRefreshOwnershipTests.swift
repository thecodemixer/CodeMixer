@testable import AgentCore
import AgentTestSupport
import Foundation
import Testing

/// A changed-file refresh outlives the runtime that asked for it: `git status`
/// is a subprocess, and the engine services a project switch while it runs.
/// These tests pin that a result is only applied to the runtime it was computed
/// for. The FS watcher is stopped up front so the only refreshes in play are the
/// ones the test issues.
@Suite("Changed-file refresh ownership", .serialized)
struct ChangedFilesRefreshOwnershipTests {

    @Test("A refresh for the active runtime publishes the workspace's changed files")
    func refreshForActiveRuntimeApplies() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: SystemPaths.git.path))
        let repo = try await makeCleanRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let h = try await EngineHarness.make(workspace: repo)
        await h.engine.stopFSWatcher()
        let active = try #require(await h.engine.activeKey)

        try Data("two\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
        await h.engine.refreshChangedFilesFromGit(for: active)

        #expect(await h.engine.changedFiles.map(\.relativePath) == ["file.txt"])
    }

    @Test("A refresh for a superseded runtime writes nothing into the active project")
    func refreshForSupersededRuntimeIsDropped() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: SystemPaths.git.path))
        let repo = try await makeCleanRepository()
        defer { try? FileManager.default.removeItem(at: repo) }
        let h = try await EngineHarness.make(workspace: repo)
        await h.engine.stopFSWatcher()
        let superseded = AgentRuntimeKey(projectPath: repo.appendingPathComponent("other").path,
                                         agentID: .codex)

        try Data("two\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
        await h.engine.refreshChangedFilesFromGit(for: superseded)

        #expect(await h.engine.changedFiles.isEmpty)
        let touched = await h.collector.snapshot().contains {
            if case .fileTouched = $0 { return true }
            return false
        }
        #expect(!touched)
    }

    private func makeCleanRepository() async throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer-refresh-owner-\(SystemRandomSource().uuid().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let runner = ProcessRunner()
        _ = try await runner.run(executable: SystemPaths.git, arguments: ["init"], cwd: repo)
        try Data("one\n".utf8).write(to: repo.appendingPathComponent("file.txt"))
        _ = try await runner.run(executable: SystemPaths.git, arguments: ["add", "file.txt"], cwd: repo)
        _ = try await runner.run(executable: SystemPaths.git,
                                 arguments: ["-c", "user.email=codemixer-test@example.com",
                                             "-c", "user.name=Codemixer Test",
                                             "commit", "-m", "initial"],
                                 cwd: repo)
        return repo
    }
}
