import Foundation

import AgentCore

/// Resolves a custom ACP CLI from an absolute path, basename PATH lookup, or
/// `CODEMIXER_CUSTOM_ACP_BIN` override (tests / fakes).
public struct CustomACPBinaryLocator: Sendable {
    public enum LocateError: Error, Sendable, Equatable {
        case notFound(checked: [String], displayName: String)
    }

    private let environment: any AgentEnvironment
    private let fileSystem: any FileSystem
    private let executablePath: String
    private let displayName: String

    public init(executablePath: String,
                displayName: String,
                environment: any AgentEnvironment = SystemEnvironment(),
                fileSystem: any FileSystem = SystemFileSystem()) {
        self.executablePath = executablePath
        self.displayName = displayName
        self.environment = environment
        self.fileSystem = fileSystem
    }

    public func locate(env: ResolvedEnvironment) throws -> URL {
        var candidates: [URL] = []
        if let override = env.variable("CODEMIXER_CUSTOM_ACP_BIN"), !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }

        let configured = URL(fileURLWithPath: executablePath)
        if configured.path.hasPrefix("/") {
            candidates.append(configured)
        }

        let basename = configured.lastPathComponent
        if !basename.isEmpty {
            candidates.append(contentsOf: env.path
                .split(separator: ":", omittingEmptySubsequences: true)
                .map { URL(fileURLWithPath: String($0), isDirectory: true)
                    .appendingPathComponent(basename) })

            let home = environment.homeDirectory
            candidates.append(contentsOf: [
                home.appendingPathComponent(".local/bin/\(basename)"),
                URL(fileURLWithPath: "/opt/homebrew/bin/\(basename)"),
                URL(fileURLWithPath: "/usr/local/bin/\(basename)"),
            ])
        }

        if !configured.path.hasPrefix("/") {
            candidates.append(configured)
        }

        var checked: [String] = []
        var seen: Set<String> = []
        for candidate in candidates where seen.insert(candidate.path).inserted {
            checked.append(candidate.path)
            if fileSystem.fileExists(at: candidate) {
                return candidate
            }
        }
        throw LocateError.notFound(checked: checked, displayName: displayName)
    }
}
