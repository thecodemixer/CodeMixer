import Foundation
import Testing
@testable import AgentUI
@testable import AgentCore
@testable import AgentTestSupport

@Suite("Folder markdown HTML renderer — escaping and structure")
struct MarkdownHTMLRendererTests {
    @Test("Escapes HTML special characters in text and code")
    func escapesHTML() {
        let html = MarkdownHTMLRenderer.render("Hello <script>alert(1)</script> & \"quotes\"")
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("&amp;"))
        #expect(!html.contains("<script>"))
    }

    @Test("Renders headings with stable anchors for TOC")
    func headingsAndTOC() {
        let md = """
        # Intro
        ## Details
        """
        let html = MarkdownHTMLRenderer.render(md)
        #expect(html.contains("<h1 id=\"intro\">"))
        #expect(html.contains("<h2 id=\"details\">"))
        let toc = MarkdownHTMLRenderer.tableOfContents(md)
        #expect(toc.map(\.anchor) == ["intro", "details"])
    }

    @Test("Rewrites contained local images and strips escapes")
    func containedLocalImages() {
        let root = URL(fileURLWithPath: "/tmp/folder-project")
        let docs = root.appendingPathComponent("docs")
        let md = "See ![diagram](./assets/chart.png) and ![escape](../../etc/passwd)"
        var requested: [String] = []
        let html = MarkdownHTMLRenderer.render(
            md,
            projectRoot: root,
            documentDirectory: docs,
            imageData: { relative in
                requested.append(relative)
                return Data([0x89, 0x50, 0x4E, 0x47])
            }
        )
        #expect(requested == ["docs/assets/chart.png"])
        #expect(html.contains("<img src="))
        #expect(html.contains("data:image/png;base64,"))
        #expect(!html.contains("file://"))
        #expect(!html.contains("../../etc/passwd"))
        #expect(html.contains("escape") || html.contains("passwd"))
    }

    @Test("Contained relative path rejects traversal outside project root")
    func containedRelativePathRejectsTraversal() {
        let root = URL(fileURLWithPath: "/tmp/folder-project")
        let base = root.appendingPathComponent("docs")
        #expect(
            MarkdownHTMLRenderer.containedRelativePath(
                "assets/a.png",
                projectRoot: root,
                baseDirectory: base
            ) == "docs/assets/a.png"
        )
        #expect(
            MarkdownHTMLRenderer.containedRelativePath(
                "../../etc/passwd",
                projectRoot: root,
                baseDirectory: base
            ) == nil
        )
    }

    @Test("Local markdown navigation policy blocks remote hosts")
    func navigationPolicyHelpers() {
        #expect(LoopbackDashboardURLPolicy.allowsNavigation(to: URL(string: "http://127.0.0.1:9/")))
        #expect(!LoopbackDashboardURLPolicy.allowsNavigation(to: URL(string: "https://example.com")))
    }
}

@Suite("Folder browser model — listing and preview caps")
@MainActor
struct FolderProjectBrowserModelTests {
    @Test("Search filters by name and relative path")
    func searchFilters() throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("browser-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.writeAtomically(Data("a".utf8), to: root.appendingPathComponent("alpha.log"))
        try fs.createDirectory(at: root.appendingPathComponent("nested"), withIntermediates: true)
        try fs.writeAtomically(Data("b".utf8), to: root.appendingPathComponent("nested/beta.txt"))

        let model = FolderProjectBrowserModel(root: root, kind: .files, fileSystem: fs)
        model.entries = try FolderProjectScanner.scan(root: root, fileSystem: fs)
        model.searchText = "beta"
        #expect(model.visibleEntries.map(\.relativePath) == ["nested/beta.txt"])
    }

    @Test("Extension filter chips narrow the listing")
    func extensionFilterNarrowsListing() throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("filter-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.writeAtomically(Data("a".utf8), to: root.appendingPathComponent("a.log"))
        try fs.writeAtomically(Data("b".utf8), to: root.appendingPathComponent("b.txt"))
        try fs.writeAtomically(Data("c".utf8), to: root.appendingPathComponent("c.md"))

        let model = FolderProjectBrowserModel(root: root, kind: .docs, fileSystem: fs)
        model.entries = try FolderProjectScanner.scan(root: root, fileSystem: fs)
        #expect(Set(model.availableExtensions) == Set(["log", "txt", "md"]))
        model.extensionFilter = "md"
        #expect(model.visibleEntries.map(\.relativePath) == ["c.md"])
    }

    @Test("Escape clears log find, then search and filters, then preview")
    func escapeClearsFindThenSearch() throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("escape-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.writeAtomically(Data("x".utf8), to: root.appendingPathComponent("a.log"))

        let model = FolderProjectBrowserModel(root: root, kind: .logs, fileSystem: fs)
        model.entries = try FolderProjectScanner.scan(root: root, fileSystem: fs)
        model.searchText = "a"
        model.extensionFilter = "log"
        model.showFilters = true
        model.logFindText = "error"
        model.select("a.log")
        #expect(model.handleEscape())
        #expect(model.logFindText.isEmpty)
        #expect(model.searchText == "a")
        #expect(model.selectedRelativePath == "a.log")
        #expect(model.handleEscape())
        #expect(model.searchText.isEmpty)
        #expect(model.extensionFilter == nil)
        #expect(!model.showFilters)
        #expect(model.selectedRelativePath == "a.log")
        #expect(model.handleEscape())
        #expect(model.selectedRelativePath == nil)
        #expect(model.previewMode == .none)
        #expect(!model.handleEscape())
    }

    @Test("Close preview clears selection without touching search")
    func closePreviewKeepsSearch() throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("close-preview-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.writeAtomically(Data("x".utf8), to: root.appendingPathComponent("a.txt"))

        let model = FolderProjectBrowserModel(root: root, kind: .files, fileSystem: fs)
        model.entries = try FolderProjectScanner.scan(root: root, fileSystem: fs)
        model.searchText = "a"
        model.select("a.txt")
        model.closePreview()
        #expect(model.selectedRelativePath == nil)
        #expect(model.searchText == "a")
    }

    @Test("Multi-select keeps the full selection set")
    func multiSelectPreservesPaths() throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("multi-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.writeAtomically(Data("a".utf8), to: root.appendingPathComponent("a.txt"))
        try fs.writeAtomically(Data("b".utf8), to: root.appendingPathComponent("b.txt"))

        let model = FolderProjectBrowserModel(root: root, kind: .files, fileSystem: fs)
        model.entries = try FolderProjectScanner.scan(root: root, fileSystem: fs)
        model.selectMany(["b.txt", "a.txt"])
        #expect(model.selectedPaths == Set(["a.txt", "b.txt"]))
        #expect(model.selectedRelativePath == "a.txt")
    }

    @Test("Docs preview builds a TOC and pause stops follow")
    func docsTOCAndPauseFollow() async throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("docs-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        let md = """
        # Title
        ## Section
        body
        """
        try fs.writeAtomically(Data(md.utf8), to: root.appendingPathComponent("guide.md"))
        try fs.writeAtomically(Data("line\n".utf8), to: root.appendingPathComponent("app.log"))

        let docs = FolderProjectBrowserModel(root: root, kind: .docs, fileSystem: fs)
        docs.entries = try FolderProjectScanner.scan(root: root, fileSystem: fs)
        docs.select("guide.md")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(docs.previewMode == .markdown)
        #expect(docs.tocItems.map(\.anchor) == ["title", "section"])
        docs.scrollToTOC("section")
        #expect(docs.pendingTOCAnchor == "section")

        let logs = FolderProjectBrowserModel(root: root, kind: .logs, fileSystem: fs)
        logs.entries = try FolderProjectScanner.scan(root: root, fileSystem: fs)
        logs.select("app.log")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(logs.followLogs)
        logs.pauseFollowFromUserScroll()
        #expect(!logs.followLogs)
    }

    @Test("Log preview caps at the configured tail size")
    func logPreviewCaps() async throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("log-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        let big = String(repeating: "x", count: FolderBrowserLimits.logPreviewTailBytes + 64)
        try fs.writeAtomically(Data(big.utf8), to: root.appendingPathComponent("app.log"))

        let model = FolderProjectBrowserModel(root: root, kind: .logs, fileSystem: fs)
        model.entries = try FolderProjectScanner.scan(root: root, fileSystem: fs)
        model.select("app.log")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.previewMode == .text)
        #expect(model.previewCapped)
        #expect(model.previewText.count <= FolderBrowserLimits.logPreviewTailBytes + 16)
    }

    @Test("Empty listing reports empty mode when no files exist")
    func emptyListingFlag() throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("empty-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        let model = FolderProjectBrowserModel(root: root, kind: .files, fileSystem: fs)
        model.entries = []
        model.isLoading = false
        #expect(model.isEmptyListing)
        #expect(model.fileCount == 0)
    }
}
