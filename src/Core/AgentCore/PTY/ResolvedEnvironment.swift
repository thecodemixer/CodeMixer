import Foundation

/// Result of resolving the user's interactive shell environment.
///
/// A GUI process inherits a minimal environment from `launchd` that lacks
/// `PATH` additions from `.zshrc`/`.zprofile`, `nvm`, `mise`, `asdf`, etc. We
/// run the user's shell once interactively to capture the *real* env they'd
/// see in Terminal.app, then pass that to spawned agent binaries.
public struct ResolvedEnvironment: Sendable, Equatable {
    public let variables: [String: String]
    public let path: String
    public let shell: URL

    public init(variables: [String: String], shell: URL) {
        self.variables = variables
        self.path = variables["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        self.shell = shell
    }

    /// Look up a single variable; returns `nil` if unset.
    public func variable(_ name: String) -> String? {
        variables[name]
    }

    /// Convenience: variables with a few agent-friendly defaults overlaid.
    public func withOverrides(_ overrides: [String: String]) -> [String: String] {
        var merged = variables
        for (k, v) in overrides { merged[k] = v }
        return merged
    }

    /// Environment passed to a PTY-spawned agent child.
    ///
    /// Merges adapter overrides onto the resolved shell env, then strips keys
    /// that would route Claude Code onto the SDK / Agent Credits path instead
    /// of the interactive subscription path (architecture §3.1).
    public func ptySpawnEnvironment(adapterOverrides: [String: String] = [:]) -> [String: String] {
        var merged = withOverrides(adapterOverrides)
        for key in Self.billingPoisonKeys {
            merged.removeValue(forKey: key)
        }
        return merged
    }

    private static let billingPoisonKeys = [
        "CLAUDE_CODE_ENTRYPOINT",
        "ANTHROPIC_API_KEY",
    ]
}
