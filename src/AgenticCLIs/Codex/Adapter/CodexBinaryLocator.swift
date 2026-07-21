import Foundation

import AgentCore

/// Resolves the Codex CLI using operator override, shell PATH, then common
/// user-level package-manager installation directories.
public struct CodexBinaryLocator: Sendable {
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
        if let override = env.variable("CODEX_BIN"), !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(contentsOf: env.path
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0), isDirectory: true)
                .appendingPathComponent("codex") })

        let home = environment.homeDirectory
        candidates.append(contentsOf: [
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent(".npm-global/bin/codex"),
            home.appendingPathComponent(".bun/bin/codex"),
            SystemPaths.binary(in: SystemPaths.homebrewBin, named: "codex"),
            SystemPaths.binary(in: SystemPaths.usrLocalBin, named: "codex"),
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
