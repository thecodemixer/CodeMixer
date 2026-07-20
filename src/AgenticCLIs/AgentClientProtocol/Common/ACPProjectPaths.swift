import Foundation

import AgentCore

/// On-disk layout for Codemixer-owned custom ACP state inside a project folder.
///
/// ```
/// <project>/.codemixer/acp/<customAgentID>/
///   sessions-index.json
///   transcripts/<session-id>.jsonl
/// ```
public enum ACPProjectPaths {
    public static let acpDirectoryName = "acp"
    public static let sessionsIndexFileName = "sessions-index.json"
    public static let transcriptsDirectoryName = "transcripts"

    public static func acpRootURL(in projectRoot: URL) -> URL {
        ProjectPaths.directoryURL(in: projectRoot)
            .appendingPathComponent(acpDirectoryName, isDirectory: true)
    }

    public static func agentDirectory(projectRoot: URL, customAgentID: String) -> URL {
        acpRootURL(in: projectRoot)
            .appendingPathComponent(customAgentID, isDirectory: true)
    }

    public static func sessionsIndexURL(projectRoot: URL, customAgentID: String) -> URL {
        agentDirectory(projectRoot: projectRoot, customAgentID: customAgentID)
            .appendingPathComponent(sessionsIndexFileName)
    }

    public static func transcriptsDirectory(projectRoot: URL, customAgentID: String) -> URL {
        agentDirectory(projectRoot: projectRoot, customAgentID: customAgentID)
            .appendingPathComponent(transcriptsDirectoryName, isDirectory: true)
    }

    public static func transcriptURL(projectRoot: URL,
                                     customAgentID: String,
                                     sessionID: String) -> URL {
        transcriptsDirectory(projectRoot: projectRoot, customAgentID: customAgentID)
            .appendingPathComponent("\(sessionID).jsonl")
    }
}
