import Foundation

import AgentCore

/// Resolves the Cursor Agent CLI using operator override, shell PATH, then
/// common user-level installation directories.
public struct CursorBinaryLocator: Sendable {
    public enum LocateError: Error, Sendable, Equatable {
        case notFound(checked: [String])
    }

    private let environment: any AgentEnvironment
    private let fileSystem: any FileSystem

    public init(environment: any AgentEnvironment = SystemEnvironment(),
                fileSystem: any FileSystem = SystemFileSystem()) {
        self.environment = environment
        self.fileSystem = fileSystem
    }

    public func locate(env: ResolvedEnvironment) throws -> URL {
        var candidates: [URL] = []
        for key in ["CURSOR_BIN", "CODEMIXER_LIVE_CURSOR_BIN"] {
            if let override = env.variable(key), !override.isEmpty {
                candidates.append(URL(fileURLWithPath: override))
            }
        }
        candidates.append(contentsOf: env.path
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true)
                .appendingPathComponent("cursor-agent") })

        let home = environment.homeDirectory
        candidates.append(contentsOf: [
            home.appendingPathComponent(".local/bin/cursor-agent"),
            home.appendingPathComponent(".cursor/bin/cursor-agent"),
            URL(fileURLWithPath: "/opt/homebrew/bin/cursor-agent"),
            URL(fileURLWithPath: "/usr/local/bin/cursor-agent"),
        ])

        var checked: [String] = []
        var seen: Set<String> = []
        for candidate in candidates where seen.insert(candidate.path).inserted {
            checked.append(candidate.path)
            if fileSystem.fileExists(at: candidate) {
                return candidate
            }
        }
        throw LocateError.notFound(checked: checked)
    }
}
