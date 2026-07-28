import Foundation

/// On-disk layout for Codemixer state inside a project or workspace folder.
///
/// Per **project** (agent cwd / `ProjectRef.path`). For a nested project that
/// is typically `<workspace>/<projectName>/`; it is the workspace folder
/// itself only when that folder was opened as the seeded root project:
/// - `<project>/.codemixer/project.json` — type + display name
/// - `<project>/.codemixer/history/` — adapter-namespaced transcript journals,
///   the derived session index, and a local `.gitignore`
///
/// Per **workspace** (window shell / `workspaceRoot`):
/// - `<workspace>/.codemixer/workspace.json` — catalog of member projects
/// - `<workspace>/.codemixer/workspace-<AgentID.rawValue>.json` — per-adapter
///   workspace state (model catalogs today)
///
/// These travel with the folder (clone, zip, move) rather than living only in
/// app-support `workspaces.json`.
public enum ProjectPaths {
    public static let directoryName = ".codemixer"
    public static let projectFileName = "project.json"
    public static let workspaceFileName = "workspace.json"
    public static let historyDirectoryName = "history"
    public static let historyIndexFileName = "index.json"

    public static func directoryURL(in root: URL) -> URL {
        root.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func projectStateURL(in projectRoot: URL) -> URL {
        directoryURL(in: projectRoot).appendingPathComponent(projectFileName)
    }

    public static func workspaceStateURL(in workspaceRoot: URL) -> URL {
        directoryURL(in: workspaceRoot).appendingPathComponent(workspaceFileName)
    }

    public static func historyDirectoryURL(in projectRoot: URL) -> URL {
        directoryURL(in: projectRoot)
            .appendingPathComponent(historyDirectoryName, isDirectory: true)
    }

    public static func historyIndexURL(in projectRoot: URL) -> URL {
        historyDirectoryURL(in: projectRoot)
            .appendingPathComponent(historyIndexFileName)
    }

    public static func historyIgnoreURL(in projectRoot: URL) -> URL {
        historyDirectoryURL(in: projectRoot)
            .appendingPathComponent(".gitignore")
    }

    static func transcriptDirectoryURL(for key: SessionTranscriptKey) -> URL {
        historyDirectoryURL(in: key.projectRoot)
            .appendingPathComponent(key.namespaceDirectoryName, isDirectory: true)
    }

    static func transcriptURL(for key: SessionTranscriptKey) -> URL {
        transcriptDirectoryURL(for: key)
            .appendingPathComponent(key.journalFileName)
    }

    static func transcriptLockURL(for key: SessionTranscriptKey) -> URL {
        transcriptURL(for: key).appendingPathExtension("lock")
    }

    public static func workspaceAdapterStateFileName(for agentID: AgentID) -> String {
        "workspace-\(agentID.rawValue).json"
    }

    public static func workspaceAdapterStateURL(in workspaceRoot: URL, agentID: AgentID) -> URL {
        directoryURL(in: workspaceRoot)
            .appendingPathComponent(workspaceAdapterStateFileName(for: agentID))
    }
}
