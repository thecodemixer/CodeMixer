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

@Suite("Folder preview typing — language and image detection")
struct FolderPreviewTypingTests {

    @Test("Maps source extensions to highlighter languages and prose to none")
    func mapsSyntaxLanguages() {
        #expect(FolderFileSupport.syntaxLanguage(for: entry("App.swift")) == "swift")
        #expect(FolderFileSupport.syntaxLanguage(for: entry("main.py")) == "python")
        #expect(FolderFileSupport.syntaxLanguage(for: entry("index.tsx")) == "typescript")
        #expect(FolderFileSupport.syntaxLanguage(for: entry("util.h")) == "c")
        #expect(FolderFileSupport.syntaxLanguage(for: entry("query.sql")) == "sql")
        #expect(FolderFileSupport.syntaxLanguage(for: entry("Dockerfile")) == "shell")
        #expect(FolderFileSupport.syntaxLanguage(for: entry("Makefile")) == "makefile")
        // Prose and unknown types must stay nil so nothing is mislabelled.
        #expect(FolderFileSupport.syntaxLanguage(for: entry("README.md")) == nil)
        #expect(FolderFileSupport.syntaxLanguage(for: entry("notes.txt")) == nil)
        #expect(FolderFileSupport.syntaxLanguage(for: entry("mystery.xyz")) == nil)
        #expect(FolderFileSupport.syntaxLanguage(for: entry("src", directory: true)) == nil)
    }

    @Test("Detects renderable images and excludes markup and directories")
    func detectsImages() {
        for name in ["a.png", "b.jpg", "c.jpeg", "d.gif", "e.heic", "f.tiff", "g.webp"] {
            #expect(FolderFileSupport.isImageFile(entry(name)), "\(name) should preview as an image")
        }
        // SVG is markup NSImage will not rasterise; a folder is never an image.
        #expect(!FolderFileSupport.isImageFile(entry("logo.svg")))
        #expect(!FolderFileSupport.isImageFile(entry("notes.txt")))
        #expect(!FolderFileSupport.isImageFile(entry("assets", directory: true)))
    }

    @Test("Comment prefixes follow the language so directives are not greyed out")
    func commentPrefixesPerLanguage() {
        #expect(CodeSyntaxHighlighter.commentPrefixes(for: "python") == ["#"])
        #expect(CodeSyntaxHighlighter.commentPrefixes(for: "shell") == ["#"])
        #expect(CodeSyntaxHighlighter.commentPrefixes(for: "sql") == ["--"])
        #expect(CodeSyntaxHighlighter.commentPrefixes(for: "swift") == ["//"])
        #expect(CodeSyntaxHighlighter.commentPrefixes(for: "c") == ["//"])
        #expect(CodeSyntaxHighlighter.commentPrefixes(for: nil) == ["//"])
        // The regression this guards: `#Preview` in Swift and `#include` in C are
        // directives, not comments.
        #expect(!CodeSyntaxHighlighter.commentPrefixes(for: "swift").contains("#"))
        #expect(!CodeSyntaxHighlighter.commentPrefixes(for: "c").contains("#"))
    }

    @Test("Highlighting produces attributed runs for code and leaves prose alone")
    func highlightProducesRuns() {
        let swift = CodeSyntaxHighlighter.highlight("let x = 42", language: "swift")
        #expect(String(swift.characters) == "let x = 42")
        #expect(swift.runs.count > 1, "keywords and numbers should be tinted separately")

        let comment = CodeSyntaxHighlighter.highlight("# not a comment in swift", language: "swift")
        #expect(String(comment.characters) == "# not a comment in swift")
    }

    @Test("Every file type routes to exactly one preview presentation")
    func classifiesPreviewContent() {
        #expect(FolderFileSupport.previewContentKind(for: entry("logo.png")) == .image)
        #expect(FolderFileSupport.previewContentKind(for: entry("report.pdf")) == .pdf)
        #expect(FolderFileSupport.previewContentKind(for: entry("page.html")) == .web)
        #expect(FolderFileSupport.previewContentKind(for: entry("icon.svg")) == .web)
        #expect(FolderFileSupport.previewContentKind(for: entry("clip.mp4")) == .media)
        #expect(FolderFileSupport.previewContentKind(for: entry("theme.mp3")) == .media)
        #expect(FolderFileSupport.previewContentKind(for: entry("README.md")) == .markdown)
        #expect(FolderFileSupport.previewContentKind(for: entry("App.swift")) == .source(language: "swift"))
        #expect(FolderFileSupport.previewContentKind(for: entry("notes.txt")) == .text)
        #expect(FolderFileSupport.previewContentKind(for: entry("mystery.xyz")) == .text)
    }

    @Test("Only files with both a rendered and a source form offer the toggle")
    func rememberedSourceToggleEligibility() {
        #expect(FolderFileSupport.hasRenderedAndSourceViews(entry("README.md")))
        #expect(FolderFileSupport.hasRenderedAndSourceViews(entry("page.html")))
        #expect(FolderFileSupport.hasRenderedAndSourceViews(entry("icon.svg")))
        #expect(!FolderFileSupport.hasRenderedAndSourceViews(entry("App.swift")))
        #expect(!FolderFileSupport.hasRenderedAndSourceViews(entry("logo.png")))
    }

    @Test("URL-rendered types skip the byte read; markup defers to the source toggle")
    func urlRenderedModes() {
        #expect(FolderFileSupport.urlRenderedMode(for: .image, showSource: false) == .image)
        #expect(FolderFileSupport.urlRenderedMode(for: .pdf, showSource: false) == .pdf)
        #expect(FolderFileSupport.urlRenderedMode(for: .media, showSource: false) == .media)
        #expect(FolderFileSupport.urlRenderedMode(for: .web, showSource: false) == .web)
        // Showing markup source needs the bytes, so the loader must not short-circuit.
        #expect(FolderFileSupport.urlRenderedMode(for: .web, showSource: true) == nil)
        #expect(FolderFileSupport.urlRenderedMode(for: .markdown, showSource: false) == nil)
        #expect(FolderFileSupport.urlRenderedMode(for: .text, showSource: false) == nil)
        #expect(FolderFileSupport.urlRenderedMode(for: .source(language: "swift"), showSource: false) == nil)
    }

    @Test("Previewed markup cannot navigate outside the project root")
    func localPreviewNavigationIsContained() {
        let root = URL(fileURLWithPath: "/tmp/codemixer-preview-root")
        let allows = { (url: URL?) in
            LocalFilePreviewNavigationPolicy.allowsNavigation(to: url, projectRoot: root)
        }
        #expect(allows(root.appendingPathComponent("docs/page.html")))
        #expect(allows(root))
        #expect(allows(URL(string: "about:blank")))
        #expect(!allows(nil))
        #expect(!allows(URL(fileURLWithPath: "/tmp/codemixer-preview-root-sibling/leak.html")))
        #expect(!allows(URL(fileURLWithPath: "/etc/passwd")))
        #expect(!allows(root.appendingPathComponent("../outside.html")))
        #expect(!allows(URL(string: "https://example.com")))
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

    @Test("Selecting an image previews it as an image, not as binary")
    func imageSelectionUsesImageMode() async throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("tree-image-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        // Real PNG magic bytes: contains NUL, so the old path classified it binary.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        try fs.writeAtomically(png, to: root.appendingPathComponent("logo.png"))
        try fs.writeAtomically(Data([0x00, 0x01]), to: root.appendingPathComponent("blob.bin"))

        let model = FolderTreeViewModel(root: root, fileSystem: fs)
        model.entries = try FolderScanner.scan(root: root, fileSystem: fs)
        model.rebuildTree()

        model.select("logo.png")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.previewMode == .image)
        #expect(model.previewText.isEmpty)

        model.select("blob.bin")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.previewMode == .binary)
    }

    @Test("Documents and media preview from the URL instead of as binary")
    func documentSelectionUsesRenderedModes() async throws {
        let fs = InMemoryFileSystem()
        let root = TestPaths.workspace("tree-document-root")
        try fs.createDirectory(at: root, withIntermediates: true)
        try fs.writeAtomically(Data("%PDF-1.7\n\u{0}".utf8), to: root.appendingPathComponent("spec.pdf"))
        try fs.writeAtomically(Data("<svg/>".utf8), to: root.appendingPathComponent("icon.svg"))
        try fs.writeAtomically(Data([0x00, 0x01]), to: root.appendingPathComponent("clip.mp4"))

        let model = FolderTreeViewModel(root: root, fileSystem: fs)
        model.entries = try FolderScanner.scan(root: root, fileSystem: fs)
        model.rebuildTree()

        model.select("spec.pdf")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.previewMode == .pdf)
        #expect(model.previewText.isEmpty)

        model.select("clip.mp4")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.previewMode == .media)

        model.select("icon.svg")
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.previewMode == .web)

        // The Source toggle reads the markup back as text.
        model.setDocsShowSource(true)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.previewMode == .source)
        #expect(model.previewText.contains("<svg/>"))
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
