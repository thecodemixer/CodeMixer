import Foundation

/// Known agent memory files that may live in a project root.
public enum ProjectMemoryFileKind: String, Sendable, CaseIterable {
    case claude = "CLAUDE.md"
    case agents = "AGENTS.md"
}

/// Locates and reads agent memory files from a project root.
public struct ProjectMemoryFile: Sendable {

    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem = SystemFileSystem()) {
        self.fileSystem = fileSystem
    }

    /// Returns the highest-priority memory file present in `projectRoot`.
    public func present(in projectRoot: URL) -> ProjectMemoryFileKind? {
        ProjectMemoryFileKind.allCases.first { kind in
            fileSystem.fileExists(at: url(for: kind, in: projectRoot))
        }
    }

    /// Returns the filename of the present memory file, if any.
    public func presentFilename(in projectRoot: URL) -> String? {
        present(in: projectRoot)?.rawValue
    }

    public func exists(_ kind: ProjectMemoryFileKind, in projectRoot: URL) -> Bool {
        fileSystem.fileExists(at: url(for: kind, in: projectRoot))
    }

    /// Loads the highest-priority present memory file as UTF-8 text.
    public func load(from projectRoot: URL) throws -> (kind: ProjectMemoryFileKind, contents: String)? {
        guard let kind = present(in: projectRoot) else { return nil }
        let fileURL = url(for: kind, in: projectRoot)
        let data = try fileSystem.readData(at: fileURL)
        guard let contents = String(data: data, encoding: .utf8) else {
            throw FileSystemError.ioError(path: fileURL.path, underlying: "invalid UTF-8")
        }
        return (kind, contents)
    }

    private func url(for kind: ProjectMemoryFileKind, in projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(kind.rawValue)
    }
}
