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
        let keys = files.keys.filter { $0.hasPrefix(prefix) && !$0.dropFirst(prefix.count).contains("/") }
        return keys.map { URL(fileURLWithPath: $0) }
    }

    public func modificationDate(at url: URL) throws -> Date {
        lock.lock(); defer { lock.unlock() }
        guard let date = mtimes[url.path] else { throw FileSystemError.notFound(path: url.path) }
        return date
    }
}
