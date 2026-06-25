import Foundation

/// Failure modes for PTY allocation, spawn, and IO.
public enum PTYError: Error, Sendable, Equatable {
    case openptyFailed(errno: Int32)
    case setWinsizeFailed(errno: Int32)
    case spawnFailed(errno: Int32, executable: String)
    case writeFailed(errno: Int32)
    case alreadyClosed
}
