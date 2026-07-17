import Foundation
import Testing
@testable import AgentUI

@Suite("WorkspaceFileIndexer")
struct WorkspaceFileIndexerTests {

    @Test("Workspace file index skips Apple photo library packages")
    func workspaceFileIndexSkipsPhotoLibraries() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer-workspace-file-indexer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        try createFile("src/App.swift", in: workspace)
        try createFile("photos-notes/README.md", in: workspace)
        try createFile("Pictures/Photos Library.photoslibrary/database/photos.sqlite", in: workspace)
        try createFile("Pictures/iPhoto Library.photolibrary/Masters/image.jpg", in: workspace)
        try createFile("Pictures/Aperture Library.aplibrary/Masters/image.raw", in: workspace)

        let files = WorkspaceFileIndexer().files(in: workspace, limit: 20)

        #expect(files == [
            "photos-notes/README.md",
            "src/App.swift",
        ])
    }

    private func createFile(_ relativePath: String, in workspace: URL) throws {
        let url = workspace.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
    }
}
