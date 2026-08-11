import AppKit
import Foundation
import Testing
@testable import AgentUI
@testable import AgentCore
@testable import AgentTestSupport

@Suite("Folder tree builder — hierarchy and prune")
struct FolderTreeBuilderTests {
    @Test("Builds directories-first children and promotes orphans")
    func buildsHierarchy() {
        let entries = [
            entry("src", directory: true),
            entry("src/a.swift"),
            entry("src/nested", directory: true),
            entry("src/nested/b.swift"),
            entry("orphan/c.txt"), // parent directory missing → promote to root
            entry("z.md"),
        ]
        let roots = FolderTreeBuilder.build(entries: entries)
        #expect(roots.map(\.entry.relativePath) == ["src", "orphan/c.txt", "z.md"])
        #expect(roots[0].children.map(\.entry.relativePath) == ["src/nested", "src/a.swift"])
        #expect(roots[0].children[0].children.map(\.entry.relativePath) == ["src/nested/b.swift"])
    }

    @Test("Parent path is pure string work, independent of the working directory")
    func parentPathIgnoresWorkingDirectory() {
        #expect(FolderFileSupport.parentRelativePath(of: "src/nested/b.swift") == "src/nested")
        #expect(FolderFileSupport.parentRelativePath(of: "src/a.swift") == "src")
        #expect(FolderFileSupport.parentRelativePath(of: "top.md") == "")
        #expect(FolderFileSupport.parentRelativePath(of: "src/") == "")
        #expect(FolderFileSupport.parentRelativePath(of: "") == "")
    }

    @Test("Prune keeps matching files and their ancestor directories")
    func pruneKeepsAncestors() {
        let roots = FolderTreeBuilder.build(entries: [
            entry("src", directory: true),
            entry("src/a.swift"),
            entry("src/b.txt"),
            entry("docs", directory: true),
            entry("docs/guide.md"),
        ])
        let pruned = FolderTreeBuilder.pruned(roots) { $0.fileExtension == "md" }
        #expect(pruned.map(\.entry.relativePath) == ["docs"])
        #expect(pruned[0].children.map(\.entry.relativePath) == ["docs/guide.md"])
    }

    private func entry(_ path: String, directory: Bool = false) -> FolderFileEntry {
        FolderFileEntry(
            relativePath: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            fileExtension: directory ? "" : URL(fileURLWithPath: path).pathExtension.lowercased(),
            byteCount: directory ? 0 : 1,
            modifiedAt: Date(timeIntervalSince1970: 0),
            isDirectory: directory
        )
    }
}

@Suite("Folder file icons — extension and name map")
struct FolderFileIconTests {
    @Test("Maps representative extensions and exact names")
    func representativeMappings() {
        #expect(FolderFileIcon.systemImage(for: entry("src", directory: true)) == "folder")
        #expect(FolderFileIcon.systemImage(for: entry("Main.swift")) == "swift")
        #expect(FolderFileIcon.systemImage(for: entry("app.js")) == "j.square")
        #expect(FolderFileIcon.systemImage(for: entry("app.ts")) == "t.square")
        #expect(FolderFileIcon.systemImage(for: entry("main.py")) == "p.square")
        #expect(FolderFileIcon.systemImage(for: entry("main.go")) == "g.square")
        #expect(FolderFileIcon.systemImage(for: entry("lib.rs")) == "r.square")
        #expect(FolderFileIcon.systemImage(for: entry("App.java")) == "cup.and.saucer")
        #expect(FolderFileIcon.systemImage(for: entry("Main.kt")) == "k.square")
        #expect(FolderFileIcon.systemImage(for: entry("util.c")) == "c.square")
        #expect(FolderFileIcon.systemImage(for: entry("util.cpp")) == "plus.forwardslash.minus")
        #expect(FolderFileIcon.systemImage(for: entry("Foo.m")) == "m.square")
        #expect(FolderFileIcon.systemImage(for: entry("script.rb")) == "diamond")
        #expect(FolderFileIcon.systemImage(for: entry("run.sh")) == "terminal")
        #expect(FolderFileIcon.systemImage(for: entry("query.sql")) == "cylinder")
        #expect(FolderFileIcon.systemImage(for: entry("index.html")) == "globe")
        #expect(FolderFileIcon.systemImage(for: entry("styles.css")) == "paintbrush")
        #expect(FolderFileIcon.systemImage(for: entry("data.json")) == "curlybraces")
        #expect(FolderFileIcon.systemImage(for: entry("config.yml")) == "list.bullet.rectangle")
        #expect(FolderFileIcon.systemImage(for: entry("README.md")) == "doc.richtext")
        #expect(FolderFileIcon.systemImage(for: entry("app.log")) == "doc.text")
        #expect(FolderFileIcon.systemImage(for: entry("shot.png")) == "photo")
        #expect(FolderFileIcon.systemImage(for: entry("archive.zip")) == "doc.zipper")
        #expect(FolderFileIcon.systemImage(for: entry("Dockerfile")) == "shippingbox")
        #expect(FolderFileIcon.systemImage(for: entry("Makefile")) == "hammer")
        #expect(FolderFileIcon.systemImage(for: entry("Package.swift")) == "swift")
        #expect(FolderFileIcon.systemImage(for: entry(".gitignore")) == "eye.slash")
        #expect(FolderFileIcon.systemImage(for: entry("unknown.xyz")) == "doc")
        #expect(!FolderFileIcon.systemImage(for: entry("noext")).isEmpty)
    }

    /// Guards the one failure mode a unit test can catch before visual QA: a
    /// symbol name that does not exist renders as a blank/missing glyph.
    @Test("Every mapped symbol resolves in the system SF Symbols catalog")
    func everyMappedSymbolResolves() {
        let samples = [
            "dir", "Main.swift", "app.js", "app.jsx", "app.ts", "app.tsx", "main.py",
            "main.go", "lib.rs", "App.java", "Main.kt", "build.kts", "util.c", "util.h",
            "util.cpp", "util.cc", "util.cxx", "util.hpp", "Foo.m", "Foo.mm", "script.rb",
            "run.sh", "run.bash", "run.zsh", "run.fish", "query.sql", "index.html",
            "index.htm", "styles.css", "styles.scss", "styles.sass", "styles.less",
            "data.json", "config.yml", "config.yaml", "config.toml", "config.xml",
            "Info.plist", "README.md", "notes.markdown", "paper.pdf", "app.log",
            "notes.txt", "shot.png", "shot.jpg", "shot.jpeg", "anim.gif", "shot.webp",
            "shot.tiff", "shot.bmp", "shot.heic", "logo.svg", "archive.zip", "archive.tar",
            "archive.gz", "archive.tgz", "archive.bz2", "archive.xz", "archive.7z",
            "archive.rar", "Dockerfile", "Makefile", "GNUmakefile", "Package.swift",
            "README", "LICENSE", ".gitignore", ".dockerignore", ".gitattributes",
            ".gitmodules", ".envrc", "unknown.xyz", "noext",
        ]
        for sample in samples {
            let isDirectory = sample == "dir"
            let symbol = FolderFileIcon.systemImage(for: entry(sample, directory: isDirectory))
            #expect(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                "SF Symbol \(symbol) (for \(sample)) does not resolve"
            )
        }
    }

    @Test("Folder tree chrome symbols resolve")
    func chromeSymbolsResolve() {
        let chrome = [
            FolderProjectKind.folderTree.systemImage,
            "doc.text.magnifyingglass",
            "arrow.up.left.and.arrow.down.right",
            "arrow.down.right.and.arrow.up.left",
            "line.3.horizontal.decrease.circle",
            "arrow.clockwise",
            "magnifyingglass",
            "xmark",
            "lock",
            "doc.zipper",
            "exclamationmark.triangle",
            "folder",
        ]
        for symbol in chrome {
            #expect(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                "SF Symbol \(symbol) does not resolve"
            )
        }
    }

    private func entry(_ path: String, directory: Bool = false) -> FolderFileEntry {
        FolderFileEntry(
            relativePath: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            fileExtension: directory ? "" : URL(fileURLWithPath: path).pathExtension.lowercased(),
            byteCount: 1,
            modifiedAt: Date(timeIntervalSince1970: 0),
            isDirectory: directory
        )
    }
}

@Suite("Folder tree view model — expansion, filter, preview")
@MainActor
struct FolderTreeViewModelTests {
    @Test("Filter expands ancestors without mutating stored expansion")
    func filterAutoExpandsWithoutMutatingStoredSet() throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("tree-filter-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.createDirectory(at: root.appendingPathComponent("src"), withIntermediates: true)
        try fs.writeAtomically(Data("x".utf8), to: root.appendingPathComponent("src/deep.swift"))

        let model = FolderTreeViewModel(root: root, fileSystem: fs)
        model.entries = try FolderScanner.scan(root: root, fileSystem: fs)
        model.rebuildTree()
        #expect(model.expandedPaths.isEmpty)
        model.searchText = "deep"
        #expect(model.effectiveExpandedPaths.contains("src"))
        #expect(model.expandedPaths.isEmpty)
        #expect(model.visibleTreeRoots.first?.entry.relativePath == "src")
    }

    @Test("Selecting a directory clears preview; selecting a file loads text")
    func selectionPreviewGates() async throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("tree-preview-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.createDirectory(at: root.appendingPathComponent("src"), withIntermediates: true)
        try fs.writeAtomically(Data("hello".utf8), to: root.appendingPathComponent("notes.txt"))

        let model = FolderTreeViewModel(root: root, fileSystem: fs)
        model.entries = try FolderScanner.scan(root: root, fileSystem: fs)
        model.rebuildTree()
        model.select("src")
        #expect(model.previewMode == .none)
        #expect(model.previewTitle == "src")
        model.select("notes.txt")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.previewMode == .text)
        #expect(model.previewText.contains("hello"))
    }

    @Test("Markdown preview toggles source without TOC state")
    func markdownPreviewSourceToggle() async throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("tree-md-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.writeAtomically(Data("# Title\n".utf8), to: root.appendingPathComponent("readme.md"))

        let model = FolderTreeViewModel(root: root, fileSystem: fs)
        model.entries = try FolderScanner.scan(root: root, fileSystem: fs)
        model.rebuildTree()
        model.select("readme.md")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.previewMode == .markdown)
        model.setDocsShowSource(true)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.previewMode == .source)
    }

    @Test("Binary, oversize, and unreadable files each get their own preview state")
    func previewErrorStates() async throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("tree-preview-states-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.writeAtomically(Data([0x00, 0x01, 0x02]), to: root.appendingPathComponent("blob.bin"))
        let oversize = Data(repeating: 0x41, count: FolderBrowserLimits.filePreviewMaxBytes + 1)
        try fs.writeAtomically(oversize, to: root.appendingPathComponent("huge.txt"))
        try fs.writeAtomically(Data("gone".utf8), to: root.appendingPathComponent("vanishes.txt"))

        let model = FolderTreeViewModel(root: root, fileSystem: fs)
        model.entries = try FolderScanner.scan(root: root, fileSystem: fs)
        model.rebuildTree()

        model.select("blob.bin")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.previewMode == .binary)
        #expect(model.previewText.isEmpty)

        model.select("huge.txt")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.previewMode == .error)
        #expect(model.previewText.contains("larger than"))

        // Listing still holds the row, but the file is gone from disk.
        try fs.remove(at: root.appendingPathComponent("vanishes.txt"))
        model.select("vanishes.txt")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.previewMode == .error)
    }

    @Test("Oversize markdown reports the markdown limit, not the text limit")
    func oversizeMarkdownUsesMarkdownLimit() async throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("tree-md-oversize-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        let oversize = Data(repeating: 0x41, count: FolderBrowserLimits.markdownPreviewMaxBytes + 1)
        try fs.writeAtomically(oversize, to: root.appendingPathComponent("huge.md"))

        let model = FolderTreeViewModel(root: root, fileSystem: fs)
        model.entries = try FolderScanner.scan(root: root, fileSystem: fs)
        model.rebuildTree()
        model.select("huge.md")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.previewMode == .error)
        #expect(model.previewText.contains("larger than"))
    }

    @Test("Left-arrow parent target walks up one level and stops at the root")
    func parentOfSelectionWalksUp() throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("tree-parent-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.createDirectory(at: root.appendingPathComponent("src"), withIntermediates: true)
        try fs.writeAtomically(Data("x".utf8), to: root.appendingPathComponent("src/a.swift"))
        try fs.writeAtomically(Data("y".utf8), to: root.appendingPathComponent("top.txt"))

        let model = FolderTreeViewModel(root: root, fileSystem: fs)
        model.entries = try FolderScanner.scan(root: root, fileSystem: fs)
        model.rebuildTree()
        model.select("src/a.swift")
        #expect(model.parentOfSelection() == "src")
        model.select("top.txt")
        #expect(model.parentOfSelection() == nil)
        model.select(nil)
        #expect(model.parentOfSelection() == nil)
    }

    @Test("Expand all covers every directory and collapse all clears them")
    func expandAndCollapseAll() throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("tree-expand-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.createDirectory(at: root.appendingPathComponent("src"), withIntermediates: true)
        try fs.createDirectory(at: root.appendingPathComponent("src/deep"), withIntermediates: true)
        try fs.writeAtomically(Data("x".utf8), to: root.appendingPathComponent("src/deep/a.swift"))

        let model = FolderTreeViewModel(root: root, fileSystem: fs)
        model.entries = try FolderScanner.scan(root: root, fileSystem: fs)
        model.rebuildTree()
        model.expandAll()
        #expect(model.expandedPaths == ["src", "src/deep"])
        #expect(model.isExpanded("src/deep"))
        model.collapseAll()
        #expect(model.expandedPaths.isEmpty)
    }

    @Test("Clearing the filter restores the pre-filter expansion set")
    func clearingFilterRestoresExpansion() throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("tree-filter-restore-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.createDirectory(at: root.appendingPathComponent("src"), withIntermediates: true)
        try fs.createDirectory(at: root.appendingPathComponent("docs"), withIntermediates: true)
        try fs.writeAtomically(Data("x".utf8), to: root.appendingPathComponent("src/a.swift"))
        try fs.writeAtomically(Data("y".utf8), to: root.appendingPathComponent("docs/guide.md"))

        let model = FolderTreeViewModel(root: root, fileSystem: fs)
        model.entries = try FolderScanner.scan(root: root, fileSystem: fs)
        model.rebuildTree()
        model.setExpanded("src", expanded: true)

        model.searchText = "guide"
        #expect(model.effectiveExpandedPaths.contains("docs"))
        #expect(model.filterMatchCount == 1)

        model.clearSearchAndFilters()
        #expect(model.effectiveExpandedPaths == ["src"])
        #expect(model.filterMatchCount == model.fileCount)
    }

    @Test("Clicking a folder expands it, and a later click collapses it")
    func clickingFolderTogglesExpansion() throws {
        let clock = FakeClock()
        let model = try makeActivationModel(clock: clock)

        model.activate("src")
        #expect(model.selectedRelativePath == "src")
        #expect(model.isExpanded("src"))

        clock.advance(by: .seconds(2))
        model.activate("src")
        #expect(!model.isExpanded("src"))
    }

    @Test("A double click opens the folder instead of toggling it twice")
    func doubleClickLeavesFolderOpen() throws {
        let clock = FakeClock()
        let model = try makeActivationModel(clock: clock)

        model.activate("src")
        clock.advance(by: .milliseconds(120))
        model.activate("src")
        #expect(model.isExpanded("src"), "the second click of a double click must not collapse the folder")

        // A deliberate click after the double-click window still toggles.
        clock.advance(by: .seconds(1))
        model.activate("src")
        #expect(!model.isExpanded("src"))
    }

    @Test("Activating a file selects it without changing expansion")
    func activatingFileOnlySelects() throws {
        let clock = FakeClock()
        let model = try makeActivationModel(clock: clock)
        model.setExpanded("src", expanded: true)

        model.activate("src/a.swift")
        #expect(model.selectedRelativePath == "src/a.swift")
        #expect(model.expandedPaths == ["src"])
    }

    private func makeActivationModel(clock: FakeClock) throws -> FolderTreeViewModel {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("tree-activate-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.createDirectory(at: root.appendingPathComponent("src"), withIntermediates: true)
        try fs.writeAtomically(Data("x".utf8), to: root.appendingPathComponent("src/a.swift"))

        let model = FolderTreeViewModel(root: root, fileSystem: fs, clock: clock)
        model.entries = try FolderScanner.scan(root: root, fileSystem: fs)
        model.rebuildTree()
        return model
    }

    @Test("Refresh intersects expansion and selection")
    func refreshPrunesExpansionAndSelection() async throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("tree-refresh-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.createDirectory(at: root.appendingPathComponent("keep"), withIntermediates: true)
        try fs.writeAtomically(Data("a".utf8), to: root.appendingPathComponent("keep/a.txt"))
        try fs.writeAtomically(Data("b".utf8), to: root.appendingPathComponent("gone.txt"))

        let model = FolderTreeViewModel(root: root, fileSystem: fs)
        model.start()
        try? await Task.sleep(for: .milliseconds(60))
        model.expandedPaths = ["keep", "missing-dir"]
        model.select("gone.txt")
        try? await Task.sleep(for: .milliseconds(40))

        try fs.remove(at: root.appendingPathComponent("gone.txt"))
        model.refresh()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(model.expandedPaths == ["keep"])
        #expect(model.selectedRelativePath == nil)
        model.stop()
    }

    @Test("Escape clears filters then selection")
    func escapeClearsFiltersThenSelection() throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("tree-escape-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.writeAtomically(Data("x".utf8), to: root.appendingPathComponent("a.txt"))

        let model = FolderTreeViewModel(root: root, fileSystem: fs)
        model.entries = try FolderScanner.scan(root: root, fileSystem: fs)
        model.rebuildTree()
        model.searchText = "a"
        model.extensionFilter = "txt"
        model.showFilters = true
        model.select("a.txt")
        #expect(model.handleEscape())
        #expect(model.searchText.isEmpty)
        #expect(model.extensionFilter == nil)
        #expect(model.selectedRelativePath == "a.txt")
        #expect(model.handleEscape())
        #expect(model.selectedRelativePath == nil)
    }

    @Test("Empty listing is true when the scan found nothing")
    func emptyListingUsesEntries() throws {
        let model = FolderTreeViewModel(root: TestPaths.workspace("tree-empty"), fileSystem: InMemoryFileSystem())
        model.entries = []
        model.isLoading = false
        #expect(model.isEmptyListing)
    }
}
