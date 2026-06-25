import Foundation

/// View of process environment + standard directories.
///
/// Domain code does not call `ProcessInfo.processInfo` or `getenv` directly;
/// it asks for these capabilities through this seam so tests can substitute
/// pinned values.
public protocol AgentEnvironment: Sendable {
    /// The current process's environment as a plain dictionary.
    func processEnvironment() -> [String: String]

    /// `$HOME` of the current user, fully resolved.
    var homeDirectory: URL { get }

    /// Codemixer's Application Support directory.
    var appSupportDirectory: URL { get }

    /// `~/Library/Caches/Codemixer/`
    var cachesDirectory: URL { get }

    /// `~/.claude/`
    var claudeDirectory: URL { get }

    /// User-visible computer name (for Bonjour TXT records, audit logs).
    var deviceName: String { get }
}

/// Production implementation reading the real process & filesystem.
public struct SystemEnvironment: AgentEnvironment {
    public init() {}

    public func processEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment
    }

    public var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    public var appSupportDirectory: URL {
        homeDirectory
            .appendingPathComponent(AppIdentity.appSupportRelativePath, isDirectory: true)
    }

    public var cachesDirectory: URL {
        homeDirectory
            .appendingPathComponent(AppIdentity.cachesRelativePath, isDirectory: true)
    }

    public var claudeDirectory: URL {
        homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    public var deviceName: String {
        Host.current().localizedName ?? AppIdentity.fallbackDeviceName
    }
}
