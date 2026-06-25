import Foundation

/// Claude Code filesystem conventions shared by the adapter and digital twin.
///
/// Lives under `Common/` so adapter and twin share one source of truth for
/// transcript paths without either depending on the other's implementation.
public enum ClaudeProjectPaths {
    /// Map a workspace path to the directory name Claude Code uses under
    /// `~/.claude/projects/`.
    ///
    /// Claude's convention (verified against a live install): replace every
    /// character that is not an ASCII letter or digit with `-`, **preserving
    /// case** and **keeping the leading dash** that comes from the absolute
    /// path's leading `/`. A previous implementation lowercased, only mapped
    /// `/` and `.`, and trimmed the leading dash — which produced a slug that
    /// did not exist on disk, so the transcript tailer read an empty directory
    /// and no assistant text ever surfaced.
    public static func projectSlug(for workspace: URL) -> String {
        String(workspace.path.map { ch in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        })
    }

    public static func projectDirectory(for workspace: URL, claudeDirectory: URL) -> URL {
        claudeDirectory
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectSlug(for: workspace), isDirectory: true)
    }

    static func workspaceVariants(for workspace: URL) -> [URL] {
        let candidates = [
            workspace,
            workspace.resolvingSymlinksInPath(),
            privateVarAlias(for: workspace),
            logicalVarAlias(for: workspace),
        ].compactMap { $0 }

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.path).inserted }
    }

    public static func transcriptURL(sessionID: String,
                                     workspace: URL,
                                     claudeDirectory: URL) -> URL {
        projectDirectory(for: workspace, claudeDirectory: claudeDirectory)
            .appendingPathComponent("\(sessionID).jsonl")
    }

    public static func subagentsDirectory(sessionID: String,
                                          workspace: URL,
                                          claudeDirectory: URL) -> URL {
        projectDirectory(for: workspace, claudeDirectory: claudeDirectory)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
    }

    private static func privateVarAlias(for workspace: URL) -> URL? {
        let path = workspace.path
        guard path.hasPrefix("/var/") else { return nil }
        return URL(fileURLWithPath: "/private" + path, isDirectory: true)
    }

    private static func logicalVarAlias(for workspace: URL) -> URL? {
        let path = workspace.path
        guard path.hasPrefix("/private/var/") else { return nil }
        return URL(fileURLWithPath: String(path.dropFirst("/private".count)), isDirectory: true)
    }
}
