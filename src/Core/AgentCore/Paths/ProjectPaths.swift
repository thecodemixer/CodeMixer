import Foundation

/// On-disk layout for Codemixer state inside a project or workspace folder.
///
/// - `<root>/.codemixer/project.json` — per-project type + display name
/// - `<root>/.codemixer/workspace.json` — workspace catalog of member projects
/// - `<root>/.codemixer/workspace-<AgentID.rawValue>.json` — per-adapter
///   workspace state (model catalogs today)
///
/// These travel with the folder (clone, zip, move) rather than living only in
/// app-support `workspaces.json`.
public enum ProjectPaths {
    public static let directoryName = ".codemixer"
    public static let projectFileName = "project.json"
    public static let workspaceFileName = "workspace.json"

    public static func directoryURL(in root: URL) -> URL {
        root.appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func projectStateURL(in projectRoot: URL) -> URL {
        directoryURL(in: projectRoot).appendingPathComponent(projectFileName)
    }

    public static func workspaceStateURL(in workspaceRoot: URL) -> URL {
        directoryURL(in: workspaceRoot).appendingPathComponent(workspaceFileName)
    }

    public static func workspaceAdapterStateFileName(for agentID: AgentID) -> String {
        "workspace-\(agentID.rawValue).json"
    }

    public static func workspaceAdapterStateURL(in workspaceRoot: URL, agentID: AgentID) -> URL {
        directoryURL(in: workspaceRoot)
            .appendingPathComponent(workspaceAdapterStateFileName(for: agentID))
    }
}
