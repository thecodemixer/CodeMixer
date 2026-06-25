import Foundation
import Testing
@testable import AgentCore

@Suite("Git hunk revert — patch construction and reverse apply", .serialized)
struct GitRevertIntegrationTests {

    @Test("buildPatch emits the exact single-hunk unified diff")
    func buildPatchEmitsExpectedUnifiedDiff() throws {
        let hunk = DiffHunk(
            header: "@@ -1,2 +1,2 @@",
            oldRange: 1...2,
            newRange: 1...2,
            lines: [
                DiffLine(text: "old", kind: .deletion, oldLineNumber: 1),
                DiffLine(text: "new", kind: .addition, newLineNumber: 1),
                DiffLine(text: "same", kind: .context, oldLineNumber: 2, newLineNumber: 2),
            ]
        )

        let patch = try #require(String(data: buildPatch(path: "file.txt", hunk: hunk), encoding: .utf8))

        #expect(patch == """
        diff --git a/file.txt b/file.txt
        --- a/file.txt
        +++ b/file.txt
        @@ -1,2 +1,2 @@
        -old
        +new
         same

        """)
    }

    @Test("A patch built from GitDiffEngine can be reverse-applied in a real repository")
    func reverseAppliesInRealGitRepository() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: SystemPaths.git.path))

        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer-git-revert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        let runner = ProcessRunner()
        try await runGit(["init"], cwd: repo, runner: runner)

        let file = repo.appendingPathComponent("file.txt")
        let original = "one\ntwo\nthree\n"
        try Data(original.utf8).write(to: file)
        try await runGit(["add", "file.txt"], cwd: repo, runner: runner)
        try await runGit([
            "-c", "user.email=codemixer-test@example.com",
            "-c", "user.name=Codemixer Test",
            "commit", "-m", "initial"
        ], cwd: repo, runner: runner)

        try Data("one\nTWO\nthree\n".utf8).write(to: file)
        let diff = try await GitDiffEngine(workspace: repo).diff(for: "file.txt", context: 0)
        let hunk = try #require(diff.hunks.first)
        let patch = buildPatch(path: "file.txt", hunk: hunk)

        _ = try await runner.run(executable: SystemPaths.git,
                                 arguments: ["apply", "--reverse", "--unidiff-zero", "-"],
                                 cwd: repo,
                                 stdin: patch)

        let restored = try String(contentsOf: file, encoding: .utf8)
        #expect(restored == original)
    }

    private func runGit(_ arguments: [String], cwd: URL, runner: ProcessRunner) async throws {
        _ = try await runner.run(executable: SystemPaths.git,
                                 arguments: arguments,
                                 cwd: cwd)
    }
}
