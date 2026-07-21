import Foundation
import Testing
import AgentTestSupport
@testable import AgentCore

@Suite("GitDiffEngine — porcelain changed-file parsing")
struct ChangedFilesParsingTests {

    @Test("Parses modified, added, and untracked paths")
    func parsesCommonStatusLines() {
        let engine = GitDiffEngine(workspace: TestPaths.temporaryRoot)
        let output = """
         M Sources/App.swift
        A  Sources/NewFile.swift
        ?? Scratch.txt
        """

        #expect(engine.parsePorcelain(output) == [
            "Sources/App.swift",
            "Sources/NewFile.swift",
            "Scratch.txt",
        ])
    }

    @Test("Rename status returns the destination path")
    func renameStatusReturnsDestinationPath() {
        let engine = GitDiffEngine(workspace: TestPaths.temporaryRoot)
        let output = "R  OldName.swift -> NewName.swift\n"

        #expect(engine.parsePorcelain(output) == ["NewName.swift"])
    }

    @Test("Copy status returns the copied destination path")
    func copyStatusReturnsDestinationPath() {
        let engine = GitDiffEngine(workspace: TestPaths.temporaryRoot)
        let output = "C  Source.swift -> Copied.swift\n"

        #expect(engine.parsePorcelain(output) == ["Copied.swift"])
    }

    @Test("Quoted paths with spaces are normalized")
    func quotedPathWithSpacesIsNormalized() {
        let engine = GitDiffEngine(workspace: TestPaths.temporaryRoot)
        let output = #" M "Sources/My File.swift""# + "\n"

        #expect(engine.parsePorcelain(output) == ["Sources/My File.swift"])
    }

    @Test("Blank and malformed lines are ignored")
    func blankAndMalformedLinesAreIgnored() {
        let engine = GitDiffEngine(workspace: TestPaths.temporaryRoot)
        let output = """

        M
        ?? Valid.swift

        """

        #expect(engine.parsePorcelain(output) == ["Valid.swift"])
    }
}
