import Foundation
import Testing
@testable import AgentCore

@Suite("GitDiffEngine — unified-diff parsing")
struct GitDiffEngineParsingTests {

    @Test("Single hunk with mixed additions, deletions, and context")
    func parsesMixedHunk() {
        let engine = GitDiffEngine(workspace: URL(fileURLWithPath: "/tmp"))
        let raw = [
            "diff --git a/foo.swift b/foo.swift",
            "index 1111..2222 100644",
            "--- a/foo.swift",
            "+++ b/foo.swift",
            "@@ -10,4 +10,5 @@",
            " line ten",
            "-old eleven",
            "+new eleven",
            "+brand new twelve",
            " line twelve",
        ].joined(separator: "\n")
        let diff = engine.parseUnifiedDiff(raw, relativePath: "foo.swift")
        #expect(diff.hunks.count == 1)
        let hunk = diff.hunks[0]
        #expect(hunk.lines.count == 5)
        let kinds = hunk.lines.map(\.kind)
        #expect(kinds == [.context, .deletion, .addition, .addition, .context])
        #expect(diff.additions == 2)
        #expect(diff.deletions == 1)
    }

    @Test("Two hunks are split at @@ boundaries")
    func parsesTwoHunks() {
        let engine = GitDiffEngine(workspace: URL(fileURLWithPath: "/tmp"))
        let raw = """
        @@ -1,1 +1,1 @@
        -a
        +A
        @@ -10,1 +10,1 @@
        -b
        +B
        """
        let diff = engine.parseUnifiedDiff(raw, relativePath: "x")
        #expect(diff.hunks.count == 2)
    }

    @Test("Hunk ids are stable across parses")
    func hunkIDsAreStable() {
        let engine = GitDiffEngine(workspace: URL(fileURLWithPath: "/tmp"))
        let raw = """
        @@ -1,1 +1,1 @@
        -a
        +A
        """
        let first = engine.parseUnifiedDiff(raw, relativePath: "x")
        let second = engine.parseUnifiedDiff(raw, relativePath: "x")
        #expect(first.hunks.first?.id == second.hunks.first?.id)
    }

    @Test("No-hunk diff returns empty hunks and zero counters")
    func noHunksYieldsEmptyDiff() {
        let engine = GitDiffEngine(workspace: URL(fileURLWithPath: "/tmp"))
        let raw = """
        diff --git a/foo.swift b/foo.swift
        index 1111..2222 100644
        --- a/foo.swift
        +++ b/foo.swift
        """
        let diff = engine.parseUnifiedDiff(raw, relativePath: "foo.swift")
        #expect(diff.hunks.isEmpty)
        #expect(diff.additions == 0)
        #expect(diff.deletions == 0)
    }

    @Test("Parses hunk headers that omit an explicit length")
    func parsesSingleLineHeaderRanges() {
        let engine = GitDiffEngine(workspace: URL(fileURLWithPath: "/tmp"))
        let raw = """
        @@ -7 +7 @@
        -before
        +after
        """
        let diff = engine.parseUnifiedDiff(raw, relativePath: "x")
        #expect(diff.hunks.count == 1)
        let hunk = diff.hunks[0]
        #expect(hunk.oldRange == 7...7)
        #expect(hunk.newRange == 7...7)
        #expect(hunk.lines.count == 2)
        #expect(hunk.lines[0].oldLineNumber == 7)
        #expect(hunk.lines[1].newLineNumber == 7)
    }

    @Test("Ignores no-newline sentinel marker in unified diff body")
    func ignoresNoNewlineSentinel() {
        let engine = GitDiffEngine(workspace: URL(fileURLWithPath: "/tmp"))
        let raw = """
        @@ -1,2 +1,2 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """
        let diff = engine.parseUnifiedDiff(raw, relativePath: "x")
        #expect(diff.hunks.count == 1)
        let lines = diff.hunks[0].lines
        #expect(lines.count == 2)
        #expect(lines.map(\.kind) == [.deletion, .addition])
        #expect(lines[0].text == "old")
        #expect(lines[1].text == "new")
    }

    @Test("Handles new-file style ranges with zero old-length")
    func parsesZeroLengthOldRange() {
        let engine = GitDiffEngine(workspace: URL(fileURLWithPath: "/tmp"))
        let raw = """
        @@ -0,0 +1,3 @@
        +a
        +b
        +c
        """
        let diff = engine.parseUnifiedDiff(raw, relativePath: "x")
        #expect(diff.hunks.count == 1)
        let hunk = diff.hunks[0]
        #expect(hunk.oldRange == 0...0)
        #expect(hunk.newRange == 1...3)
        #expect(diff.additions == 3)
        #expect(diff.deletions == 0)
        #expect(hunk.lines.map(\.newLineNumber) == [1, 2, 3])
    }
}
