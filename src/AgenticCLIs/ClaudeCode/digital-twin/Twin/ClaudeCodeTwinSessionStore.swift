import Foundation

/// Transcript file layout and append helpers for the digital twin.
public struct ClaudeCodeTwinSessionStore: Sendable {
    public let sessionID: String
    public let workspace: URL
    public let claudeDirectory: URL
    public let runtime: TwinRuntimeSeams

    public init(sessionID: String,
                workspace: URL,
                claudeDirectory: URL,
                runtime: TwinRuntimeSeams = .live) {
        self.sessionID = sessionID
        self.workspace = workspace
        self.claudeDirectory = claudeDirectory
        self.runtime = runtime
    }

    public var transcriptURL: URL {
        ClaudeProjectPaths.transcriptURL(sessionID: sessionID,
                                         workspace: workspace,
                                         claudeDirectory: claudeDirectory)
    }

    public func ensureDirectory() throws {
        try runtime.ensureParentDirectory(for: transcriptURL)
    }

    public func append(_ line: ClaudeCodeTwinTranscript.TranscriptLine) throws {
        try runtime.append(line.encoded(), to: transcriptURL)
    }

    public func appendLines(_ lines: [ClaudeCodeTwinTranscript.TranscriptLine]) throws {
        for line in lines { try append(line) }
    }
}
