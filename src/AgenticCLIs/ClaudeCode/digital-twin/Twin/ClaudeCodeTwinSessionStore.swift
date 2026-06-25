import Foundation

/// Transcript file layout and append helpers for the digital twin.
public struct ClaudeCodeTwinSessionStore: Sendable {
    public let sessionID: String
    public let workspace: URL
    public let claudeDirectory: URL

    public init(sessionID: String, workspace: URL, claudeDirectory: URL) {
        self.sessionID = sessionID
        self.workspace = workspace
        self.claudeDirectory = claudeDirectory
    }

    public var transcriptURL: URL {
        ClaudeProjectPaths.transcriptURL(sessionID: sessionID,
                                         workspace: workspace,
                                         claudeDirectory: claudeDirectory)
    }

    public func ensureDirectory() throws {
        let dir = transcriptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func append(_ line: ClaudeCodeTwinTranscript.TranscriptLine) throws {
        try ensureDirectory()
        if !FileManager.default.fileExists(atPath: transcriptURL.path) {
            FileManager.default.createFile(atPath: transcriptURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: transcriptURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line.encoded())
    }

    public func appendLines(_ lines: [ClaudeCodeTwinTranscript.TranscriptLine]) throws {
        for line in lines { try append(line) }
    }
}
