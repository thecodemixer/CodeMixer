import Foundation
import AgentCore

/// In-memory FS for tests. Stores blobs keyed by path; directories are
/// implicit (any path that's a prefix of an existing file or marked via
/// `createDirectory`).
///
/// `@unchecked Sendable`: all mutable state is protected by `NSLock`.
public final class InMemoryFileSystem: FileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var directories: Set<String> = []
    private var mtimes: [String: Date] = [:]

    public init() {}

    public func fileExists(at url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return files[url.path] != nil || directories.contains(url.path)
    }

    public func isDirectory(at url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return directories.contains(url.path)
    }

    public func createDirectory(at url: URL, withIntermediates: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        directories.insert(url.path)
    }

    public func readData(at url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[url.path] else { throw FileSystemError.notFound(path: url.path) }
        return data
    }

    public func readData(at url: URL, fromOffset offset: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[url.path] else { throw FileSystemError.notFound(path: url.path) }
        guard offset < data.count else { return Data() }
        return data.subdata(in: max(0, offset)..<data.count)
    }

    public func byteCount(at url: URL) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[url.path] else { throw FileSystemError.notFound(path: url.path) }
        return data.count
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        files[url.path] = data
        mtimes[url.path] = Date()
    }

    public func move(from source: URL, to destination: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let sourcePath = source.path
        let destinationPath = destination.path
        guard sourcePath != destinationPath else { return }
        guard files[sourcePath] != nil
            || directories.contains(sourcePath)
            || containsDescendant(of: sourcePath) else {
            throw FileSystemError.notFound(path: sourcePath)
        }
        guard files[destinationPath] == nil
            && !directories.contains(destinationPath)
            && !containsDescendant(of: destinationPath) else {
            throw FileSystemError.ioError(path: destinationPath, underlying: "destination exists")
        }

        moveKeys(in: &files, from: sourcePath, to: destinationPath)
        moveKeys(in: &mtimes, from: sourcePath, to: destinationPath)
        directories = Set(directories.map { movedPath($0, from: sourcePath, to: destinationPath) })
    }

    public func remove(at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        let removedFile = files.removeValue(forKey: url.path) != nil
        let removedDir = directories.remove(url.path) != nil
        guard removedFile || removedDir else {
            throw FileSystemError.notFound(path: url.path)
        }
        mtimes.removeValue(forKey: url.path)
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
        var children: Set<String> = []
        for key in files.keys where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                children.insert(prefix + rest[..<slash])
            } else {
                children.insert(key)
            }
        }
        for dir in directories where dir.hasPrefix(prefix) {
            let rest = dir.dropFirst(prefix.count)
            guard !rest.isEmpty else { continue }
            if let slash = rest.firstIndex(of: "/") {
                children.insert(prefix + rest[..<slash])
            } else {
                children.insert(dir)
            }
        }
        return children.sorted().map { URL(fileURLWithPath: $0) }
    }

    public func modificationDate(at url: URL) throws -> Date {
        lock.lock(); defer { lock.unlock() }
        guard let date = mtimes[url.path] else { throw FileSystemError.notFound(path: url.path) }
        return date
    }

    private func containsDescendant(of path: String) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return files.keys.contains { $0.hasPrefix(prefix) }
            || directories.contains { $0.hasPrefix(prefix) }
    }

    private func movedPath(_ path: String, from source: String, to destination: String) -> String {
        guard path == source || path.hasPrefix(source + "/") else { return path }
        return destination + path.dropFirst(source.count)
    }

    private func moveKeys<Value>(in dictionary: inout [String: Value],
                                 from source: String,
                                 to destination: String) {
        let moved = dictionary.filter { key, _ in key == source || key.hasPrefix(source + "/") }
        for key in moved.keys {
            dictionary.removeValue(forKey: key)
        }
        for (key, value) in moved {
            dictionary[movedPath(key, from: source, to: destination)] = value
        }
    }
}
