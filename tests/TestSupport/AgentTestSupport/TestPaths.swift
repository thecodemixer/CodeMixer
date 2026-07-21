import Foundation

import AgentCore

/// Stable, non-machine-specific paths for tests.
///
/// Prefer `TempDirectoryFixture.make()` when each test needs an isolated directory.
/// Use `TestPaths` when several assertions must share the same opaque path string.
public enum TestPaths {
    public static let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .resolvingSymlinksInPath()

    /// Fake home directory rooted under the process temp dir.
    public static let fakeHome = temporaryRoot.appendingPathComponent("codemixer-fake-home", isDirectory: true)
        .resolvingSymlinksInPath()

    public static func workspace(_ name: String = "ws") -> URL {
        fakeHome.appendingPathComponent(name, isDirectory: true)
            .resolvingSymlinksInPath()
    }

    public static func workspacePath(_ name: String = "ws") -> String {
        workspace(name).path
    }

    public static func underTemporary(_ name: String, isDirectory: Bool = true) -> URL {
        temporaryRoot.appendingPathComponent(name, isDirectory: isDirectory)
            .resolvingSymlinksInPath()
    }

    public static let defaultShell = SystemPaths.zsh
}
