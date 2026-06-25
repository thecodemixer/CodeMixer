import Foundation
import AgentCore

/// Find the `claude` binary in the resolved shell PATH.
public struct ClaudeBinaryLocator: Sendable {

    public enum LocateError: Error, Sendable, Equatable {
        case notFound(checked: [String])
    }

    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem = SystemFileSystem()) {
        self.fileSystem = fileSystem
    }

    public func locate(env: ResolvedEnvironment) throws -> URL {
        // `$CLAUDE_BIN` is the operator escape hatch — point it at any
        // executable, real `claude` or our `fake-claude` digital twin.
        if let override = env.variable("CLAUDE_BIN"),
           fileSystem.fileExists(at: URL(fileURLWithPath: override)) {
            return URL(fileURLWithPath: override)
        }

        // `$CODEMIXER_FAKE_CLAUDE=1` triggers a search for the
        // `fake-claude` binary (built by `swift build`) on `$PATH` and in
        // the SPM `.build/debug` directory of the running process. This
        // lets `swift run codemixer` come up on a machine where the real
        // Claude CLI has never been installed.
        if env.variable("CODEMIXER_FAKE_CLAUDE") == "1" {
            if let twin = findFakeClaude(in: env.path) { return twin }
        }

        let path = env.path
        var checked: [String] = []
        for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
            let candidate = "\(directory)/claude"
            checked.append(candidate)
            if fileSystem.fileExists(at: URL(fileURLWithPath: candidate)) {
                return URL(fileURLWithPath: candidate)
            }
        }

        // Fall back to the digital twin if Claude itself isn't installed.
        // Codemixer is still usable; users see the twin's banner and learn
        // they need to install `claude` for real model output.
        if let twin = findFakeClaude(in: env.path) { return twin }

        throw LocateError.notFound(checked: checked)
    }

    private func findFakeClaude(in path: String) -> URL? {
        let candidates = path.split(separator: ":", omittingEmptySubsequences: true)
            .map { "\($0)/fake-claude" }
            + [".build/debug/fake-claude", ".build/release/fake-claude"]
        for candidate in candidates {
            if fileSystem.fileExists(at: URL(fileURLWithPath: candidate)) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}
