import Foundation
import Testing
import AgentCore
import AgentTestSupport
@testable import AgentUI

@Suite("New Project name collision against workspace siblings")
struct ProjectFolderNameTests {
    @Test("An unused name is free")
    func unusedNameIsFree() {
        let fs = InMemoryFileSystem()
        let workspace = URL(fileURLWithPath: "/workspace", isDirectory: true)
        try? fs.createDirectory(at: workspace, withIntermediates: true)
        #expect(ProjectFolderName.collisionMessage(
            name: "api",
            in: workspace,
            fileSystem: fs
        ) == nil)
    }

    @Test("An existing sibling folder produces guidance to rename")
    func existingSiblingCollides() throws {
        let fs = InMemoryFileSystem()
        let workspace = URL(fileURLWithPath: "/workspace", isDirectory: true)
        try fs.createDirectory(at: workspace, withIntermediates: true)
        try fs.createDirectory(
            at: workspace.appendingPathComponent("api", isDirectory: true),
            withIntermediates: true
        )
        #expect(ProjectFolderName.collisionMessage(
            name: "api",
            in: workspace,
            fileSystem: fs
        ) == ProjectFolderName.collisionGuidance)
        #expect(ProjectFolderName.collisionMessage(
            name: "  api  ",
            in: workspace,
            fileSystem: fs
        ) == ProjectFolderName.collisionGuidance)
    }

    @Test("An empty name is left to the empty-field validator")
    func emptyNameIsIgnored() {
        let fs = InMemoryFileSystem()
        let workspace = URL(fileURLWithPath: "/workspace", isDirectory: true)
        #expect(ProjectFolderName.collisionMessage(
            name: "   ",
            in: workspace,
            fileSystem: fs
        ) == nil)
    }

    @Test("StoreError.projectFolderExists uses the same guidance copy")
    func storeErrorMatchesGuidance() {
        let error = WorkspaceProjectsStore.StoreError.projectFolderExists(path: "/workspace/api")
        #expect(error.errorDescription == ProjectFolderName.collisionGuidance)
    }
}
