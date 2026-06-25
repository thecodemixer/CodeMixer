import Foundation

/// Errors raised by the `FileSystem` seam.
///
/// Each case carries enough context to be logged once and acted on
/// programmatically — no need for the caller to parse strings.
public enum FileSystemError: Error, Sendable, Equatable {
    case notFound(path: String)
    case permissionDenied(path: String)
    case ioError(path: String, underlying: String)
    case notRegularFile(path: String)
}

/// Narrow surface for the filesystem operations the engine actually needs.
///
/// Production: `SystemFileSystem`. Tests: `InMemoryFileSystem` (in
/// `AgentTestSupport`). Domain code does not import `FileManager` directly.
public protocol FileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func createDirectory(at url: URL, withIntermediates: Bool) throws
    func readData(at url: URL) throws -> Data
    func readData(at url: URL, fromOffset offset: Int) throws -> Data
    func byteCount(at url: URL) throws -> Int
    func writeAtomically(_ data: Data, to url: URL) throws
    func remove(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func modificationDate(at url: URL) throws -> Date
}

/// Production implementation wrapping `FileManager`.
public struct SystemFileSystem: FileSystem {
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    public func createDirectory(at url: URL, withIntermediates: Bool) throws {
        do {
            try FileManager.default.createDirectory(at: url,
                                                    withIntermediateDirectories: withIntermediates)
        } catch {
            throw FileSystemError.ioError(path: url.path,
                                          underlying: error.localizedDescription)
        }
    }

    public func readData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            throw FileSystemError.notFound(path: url.path)
        } catch let error as NSError where error.code == NSFileReadNoPermissionError {
            throw FileSystemError.permissionDenied(path: url.path)
        } catch {
            throw FileSystemError.ioError(path: url.path,
                                          underlying: error.localizedDescription)
        }
    }

    public func readData(at url: URL, fromOffset offset: Int) throws -> Data {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return try handle.readToEnd() ?? Data()
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            throw FileSystemError.notFound(path: url.path)
        } catch let error as NSError where error.code == NSFileReadNoPermissionError {
            throw FileSystemError.permissionDenied(path: url.path)
        } catch {
            throw FileSystemError.ioError(path: url.path,
                                          underlying: error.localizedDescription)
        }
    }

    public func byteCount(at url: URL) throws -> Int {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attrs[.size] as? NSNumber else {
                throw FileSystemError.notRegularFile(path: url.path)
            }
            return size.intValue
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            throw FileSystemError.notFound(path: url.path)
        } catch {
            throw FileSystemError.ioError(path: url.path,
                                          underlying: error.localizedDescription)
        }
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw FileSystemError.ioError(path: url.path,
                                          underlying: error.localizedDescription)
        }
    }

    public func remove(at url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.code == NSFileNoSuchFileError {
            throw FileSystemError.notFound(path: url.path)
        } catch {
            throw FileSystemError.ioError(path: url.path,
                                          underlying: error.localizedDescription)
        }
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: url,
                                                               includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles])
        } catch {
            throw FileSystemError.ioError(path: url.path,
                                          underlying: error.localizedDescription)
        }
    }

    public func modificationDate(at url: URL) throws -> Date {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let date = attrs[.modificationDate] as? Date else {
                throw FileSystemError.notRegularFile(path: url.path)
            }
            return date
        } catch let error as NSError where error.code == NSFileReadNoSuchFileError {
            throw FileSystemError.notFound(path: url.path)
        } catch {
            throw FileSystemError.ioError(path: url.path,
                                          underlying: error.localizedDescription)
        }
    }
}
