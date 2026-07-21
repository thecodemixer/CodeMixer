import Foundation

/// One entry discovered under a folder project root.
public struct FolderFileEntry: Sendable, Hashable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let name: String
    public let fileExtension: String
    public let byteCount: Int
    public let modifiedAt: Date
    public let isDirectory: Bool

    public init(relativePath: String,
                name: String,
                fileExtension: String,
                byteCount: Int,
                modifiedAt: Date,
                isDirectory: Bool) {
        self.relativePath = relativePath
        self.name = name
        self.fileExtension = fileExtension
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.isDirectory = isDirectory
    }

    public var kindLabel: String {
        if isDirectory { return "Folder" }
        if fileExtension.isEmpty { return "File" }
        return fileExtension.uppercased()
    }
}

/// Recursively enumerates files under a folder project, skipping hidden and
/// tooling directories. Caps at `maxEntries` and reports truncation separately.
public enum FolderProjectScanner {
    public static let ignoredDirectoryNames: Set<String> = [
        ".codemixer", ".git", ".build", "DerivedData", "node_modules", ".swiftpm",
    ]

    public struct ScanResult: Sendable {
        public let entries: [FolderFileEntry]
        public let truncated: Bool

        public init(entries: [FolderFileEntry], truncated: Bool) {
            self.entries = entries
            self.truncated = truncated
        }
    }

    public static func scan(root: URL,
                            fileSystem: any FileSystem,
                            maxEntries: Int = FolderBrowserLimits.maxScanEntries) throws -> [FolderFileEntry] {
        try scanDetailed(root: root, fileSystem: fileSystem, maxEntries: maxEntries).entries
    }

    public static func scanDetailed(root: URL,
                                    fileSystem: any FileSystem,
                                    maxEntries: Int = FolderBrowserLimits.maxScanEntries) throws -> ScanResult {
        var entries: [FolderFileEntry] = []
        var truncated = false
        var stack: [URL] = [root.standardizedFileURL]
        let rootPath = root.standardizedFileURL.path

        while let current = stack.popLast() {
            let children: [URL]
            do {
                children = try fileSystem.contentsOfDirectory(at: current)
            } catch {
                continue
            }
            for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                let name = child.lastPathComponent
                if name.hasPrefix(".") || ignoredDirectoryNames.contains(name) {
                    continue
                }
                let isDir = fileSystem.isDirectory(at: child)
                if isDir {
                    stack.append(child)
                }
                let childPath = child.standardizedFileURL.path
                let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
                guard childPath.hasPrefix(prefix) else { continue }
                let relative = String(childPath.dropFirst(prefix.count))
                let modified = (try? fileSystem.modificationDate(at: child)) ?? Date(timeIntervalSince1970: 0)
                let size = isDir ? 0 : ((try? fileSystem.byteCount(at: child)) ?? 0)
                let ext = isDir ? "" : child.pathExtension.lowercased()
                entries.append(FolderFileEntry(
                    relativePath: relative,
                    name: name,
                    fileExtension: ext,
                    byteCount: size,
                    modifiedAt: modified,
                    isDirectory: isDir
                ))
                if entries.count >= maxEntries {
                    truncated = true
                    return ScanResult(entries: entries, truncated: truncated)
                }
            }
        }

        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
        return ScanResult(entries: entries, truncated: truncated)
    }

    public static func isLikelyTextFile(_ entry: FolderFileEntry) -> Bool {
        if entry.isDirectory { return false }
        let textExtensions: Set<String> = [
            "txt", "log", "md", "markdown", "json", "yml", "yaml", "toml", "csv",
            "swift", "ts", "tsx", "js", "jsx", "py", "rb", "go", "rs", "java", "kt",
            "c", "h", "cpp", "hpp", "m", "mm", "cs", "sql", "sh", "zsh", "bash",
            "html", "css", "scss", "xml", "plist", "gradle", "properties", "ini",
            "conf", "cfg", "env", "gitignore", "dockerignore", "dockerfile",
        ]
        if textExtensions.contains(entry.fileExtension) { return true }
        return entry.fileExtension.isEmpty && entry.byteCount < 512_000
    }

    public static func isLikelyBinary(_ data: Data) -> Bool {
        let sample = data.prefix(4_096)
        return sample.contains(0)
    }
}
