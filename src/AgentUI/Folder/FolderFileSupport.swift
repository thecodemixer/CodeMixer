import Foundation
import AgentCore

/// Pure file/entry helpers shared by `FolderViewModel` and `FolderTreeViewModel`.
/// Models own scan/watch/preview tasks; this enum never holds state.
enum FolderFileSupport {
    /// Builds a single entry for a project-relative path under `root`.
    static func makeEntry(relativePath: String,
                          root: URL,
                          fileSystem: any FileSystem) throws -> FolderFileEntry {
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let urlPath = url.path
        guard urlPath == rootPath || urlPath.hasPrefix(prefix) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard fileSystem.fileExists(at: url) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let isDir = fileSystem.isDirectory(at: url)
        let modified = (try? fileSystem.modificationDate(at: url)) ?? Date(timeIntervalSince1970: 0)
        let size = isDir ? 0 : ((try? fileSystem.byteCount(at: url)) ?? 0)
        return FolderFileEntry(
            relativePath: relativePath,
            name: url.lastPathComponent,
            fileExtension: isDir ? "" : url.pathExtension.lowercased(),
            byteCount: size,
            modifiedAt: modified,
            isDirectory: isDir
        )
    }

    struct TextPreview: Sendable {
        let text: String
        let isBinary: Bool
        let capped: Bool
        let readOffset: Int
    }

    /// Reads a log-style tail from `url` (last `FolderBrowserLimits.logPreviewTailBytes`).
    static func loadLogTail(at url: URL, fileSystem: any FileSystem) throws -> TextPreview {
        let size = try fileSystem.byteCount(at: url)
        let offset = max(0, size - FolderBrowserLimits.logPreviewTailBytes)
        let data = try fileSystem.readData(at: url, fromOffset: offset)
        if FolderScanner.isLikelyBinary(data) {
            return TextPreview(text: "", isBinary: true, capped: false, readOffset: size)
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        return TextPreview(text: text, isBinary: false, capped: offset > 0, readOffset: size)
    }

    struct MarkdownDocument: Sendable {
        let text: String
        let isBinary: Bool
        let oversize: Bool
        let tocItems: [(level: Int, title: String, anchor: String)]
    }

    /// Loads a markdown/docs document up to `FolderBrowserLimits.markdownPreviewMaxBytes`.
    static func loadMarkdownDocument(at url: URL,
                                     fileSystem: any FileSystem,
                                     includeTOC: Bool) throws -> MarkdownDocument {
        let size = try fileSystem.byteCount(at: url)
        if size > FolderBrowserLimits.markdownPreviewMaxBytes {
            return MarkdownDocument(text: "", isBinary: false, oversize: true, tocItems: [])
        }
        let data = try fileSystem.readData(at: url)
        if FolderScanner.isLikelyBinary(data) {
            return MarkdownDocument(text: "", isBinary: true, oversize: false, tocItems: [])
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        let toc = includeTOC ? MarkdownHTMLRenderer.tableOfContents(text) : []
        return MarkdownDocument(text: text, isBinary: false, oversize: false, tocItems: toc)
    }

    struct GenericTextPreview: Sendable {
        let text: String
        let isBinary: Bool
        let oversize: Bool
    }

    /// Generic file preview for folder-tree (and similar) surfaces.
    static func loadTextPreview(at url: URL, fileSystem: any FileSystem) throws -> GenericTextPreview {
        let size = try fileSystem.byteCount(at: url)
        if size > FolderBrowserLimits.filePreviewMaxBytes {
            return GenericTextPreview(text: "", isBinary: false, oversize: true)
        }
        let data = try fileSystem.readData(at: url)
        if FolderScanner.isLikelyBinary(data) {
            return GenericTextPreview(text: "", isBinary: true, oversize: false)
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        return GenericTextPreview(text: text, isBinary: false, oversize: false)
    }

    static func isMarkdownFile(_ entry: FolderFileEntry) -> Bool {
        entry.fileExtension == "md" || entry.fileExtension == "markdown"
    }

    /// Images the preview renders inline rather than treating as opaque binary.
    /// Limited to what AppKit decodes natively; SVG is excluded because it is
    /// markup that `NSImage` will not rasterise — it routes to `.web` instead.
    static let previewableImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp", "ico",
    ]

    /// Markup rendered by a web view rather than shown as source by default.
    static let webRenderableExtensions: Set<String> = ["html", "htm", "xhtml", "svg"]

    /// Audio/video handed to Quick Look. Inline playback is deliberately out of
    /// scope: the preview pane is for reading, and Quick Look already plays
    /// every format the system knows.
    static let mediaExtensions: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mkv", "webm",
        "mp3", "m4a", "wav", "aiff", "aac", "flac",
    ]

    static func isImageFile(_ entry: FolderFileEntry) -> Bool {
        !entry.isDirectory && previewableImageExtensions.contains(entry.fileExtension)
    }

    /// How a file should be presented, decided from its type alone.
    ///
    /// Byte-level facts (binary sniffing, oversize) stay with the loader; this
    /// is the routing decision, kept pure so it can be tested without a preview
    /// surface or a filesystem.
    enum PreviewContentKind: Equatable {
        case image
        case pdf
        case web
        case media
        case markdown
        case source(language: String)
        case text
    }

    static func previewContentKind(for entry: FolderFileEntry) -> PreviewContentKind {
        if isImageFile(entry) { return .image }
        if entry.fileExtension == "pdf" { return .pdf }
        // Checked before `source`: HTML and SVG have a language mapping, but the
        // useful default for markup is the rendered document.
        if webRenderableExtensions.contains(entry.fileExtension) { return .web }
        if mediaExtensions.contains(entry.fileExtension) { return .media }
        if isMarkdownFile(entry) { return .markdown }
        if let language = syntaxLanguage(for: entry) { return .source(language: language) }
        return .text
    }

    /// The preview mode for content the view renders straight from the file URL,
    /// or `nil` when the loader still has to read the bytes. Markup returns `nil`
    /// while the Source toggle is on so it loads as text instead.
    static func urlRenderedMode(for contentKind: PreviewContentKind,
                                showSource: Bool) -> FilePreviewMode? {
        switch contentKind {
        case .image: return .image
        case .pdf: return .pdf
        case .media: return .media
        case .web: return showSource ? nil : .web
        case .markdown, .source, .text: return nil
        }
    }

    /// True when the file renders as a document and has a meaningful source view
    /// behind it — drives the Preview/Source toggle in the panel header.
    static func hasRenderedAndSourceViews(_ entry: FolderFileEntry) -> Bool {
        isMarkdownFile(entry) || webRenderableExtensions.contains(entry.fileExtension)
    }

    /// Language id for the syntax highlighter, or `nil` for prose/plain text.
    /// The id drives comment-prefix selection, so an unknown extension must map
    /// to `nil` rather than a guess — mislabelling turns ordinary lines grey.
    static func syntaxLanguage(for entry: FolderFileEntry) -> String? {
        guard !entry.isDirectory else { return nil }
        if let byName = languageByExactName[entry.name.lowercased()] { return byName }
        return languageByExtension[entry.fileExtension]
    }

    private static let languageByExtension: [String: String] = [
        "swift": "swift",
        "m": "objc", "mm": "objc", "h": "c", "c": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "py": "python", "rb": "ruby", "go": "go", "rs": "rust",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "cs": "csharp",
        "php": "php", "pl": "perl", "lua": "lua", "r": "r", "scala": "scala",
        "sh": "shell", "bash": "shell", "zsh": "shell", "fish": "shell",
        "sql": "sql", "json": "json", "yml": "yaml", "yaml": "yaml",
        "toml": "toml", "ini": "ini", "cfg": "ini", "conf": "ini",
        "xml": "xml", "plist": "xml", "html": "html", "htm": "html",
        "css": "css", "scss": "css", "sass": "css", "less": "css",
        "gradle": "groovy", "groovy": "groovy",
    ]

    private static let languageByExactName: [String: String] = [
        "dockerfile": "shell",
        "makefile": "makefile",
        "gnumakefile": "makefile",
        "package.swift": "swift",
    ]

    /// Parent of a project-relative path, or `""` when the path is already at the
    /// root. Deliberately pure string work: `URL(fileURLWithPath:)` resolves a
    /// relative path against the process working directory, so the answer would
    /// depend on where the app was launched from.
    static func parentRelativePath(of relativePath: String) -> String {
        var path = relativePath
        while path.hasSuffix("/") { path.removeLast() }
        guard let slash = path.lastIndex(of: "/") else { return "" }
        let parent = String(path[path.startIndex..<slash])
        return parent == "." ? "" : parent
    }

    static func oversizeMessage(limit: Int) -> String {
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
        return "File is larger than the preview limit (\(formatted))."
    }
}
