import Foundation
import AgentCore

/// Derives rich `SessionSummary` metadata from Claude's on-disk transcript
/// JSONL files.
///
/// Claude writes one session per `<id>.jsonl` under the project directory; each
/// line is a JSON record. To keep listing cheap even for long transcripts we
/// read a bounded head of each file: the first user message becomes the human
/// title, lines are counted for an approximate `messageCount`, and a `cwd`/
/// `gitBranch` field (when present) is captured. This is Claude-specific and
/// stays behind the adapter seam.
public enum ClaudeSessionLister {

    /// Max bytes read from the head of each transcript when deriving a title.
    /// Titles come from the first user turn, which is always near the top.
    public static let headByteBudget = 64 * 1024

    /// Max bytes read from the tail when deriving `lastActivity`. The newest
    /// transcript record (and its `timestamp`) lives at the end of the file.
    public static let tailByteBudget = 8 * 1024

    public static func summaries(workspace: URL,
                                 claudeDirectory: URL,
                                 fileSystem: any FileSystem) -> [SessionSummary] {
        var seenIDs: Set<String> = []
        return projectDirectories(for: workspace, claudeDirectory: claudeDirectory).flatMap { dir in
            ((try? fileSystem.contentsOfDirectory(at: dir)) ?? []).compactMap { url -> SessionSummary? in
                guard url.pathExtension == "jsonl" else { return nil }
                let id = url.deletingPathExtension().lastPathComponent
                guard seenIDs.insert(id).inserted else { return nil }
                let data = try? fileSystem.readData(at: url)
                let mtime = (try? fileSystem.modificationDate(at: url)) ?? .distantPast
                let meta = metadata(at: url, fileSystem: fileSystem, data: data)
                let activity = data.map { lastActivity(in: $0, fallback: mtime) } ?? mtime
                return SessionSummary(id: id,
                                      agentID: .claudeCode,
                                      workspace: workspace,
                                      title: meta.title ?? id,
                                      lastActivity: activity,
                                      messageCount: meta.messageCount,
                                      gitBranch: meta.gitBranch)
            }
        }.sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: - Head parse

    private static func projectDirectories(for workspace: URL, claudeDirectory: URL) -> [URL] {
        let resolved = workspace.resolvingSymlinksInPath()
        var seen: Set<String> = []
        return [workspace, resolved].compactMap { candidate in
            guard seen.insert(candidate.path).inserted else { return nil }
            return ClaudeProjectPaths.projectDirectory(for: candidate, claudeDirectory: claudeDirectory)
        }
    }

    struct Metadata: Equatable {
        var title: String?
        var messageCount: Int
        var gitBranch: String?
    }

    static func metadata(at url: URL,
                         fileSystem: any FileSystem,
                         data: Data? = nil) -> Metadata {
        let payload = data ?? (try? fileSystem.readData(at: url))
        guard let payload else {
            return Metadata(title: nil, messageCount: 0, gitBranch: nil)
        }
        return parse(headOf: payload)
    }

    /// Last conversational activity from the newest transcript record's
    /// `timestamp` field. Falls back to `fallback` when the file has no
    /// parseable timestamps (resume/read touches mtime but not record times).
    static func lastActivity(in data: Data, fallback: Date) -> Date {
        guard !data.isEmpty else { return fallback }
        let tail = data.suffix(tailByteBudget)
        guard let text = String(data: tail, encoding: .utf8) else { return fallback }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let date = parseTranscriptTimestamp(timestamp) else { continue }
            return date
        }
        return fallback
    }

    private static func parseTranscriptTimestamp(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    /// Parse the bounded head of a transcript. Extracted for testability.
    static func parse(headOf data: Data) -> Metadata {
        let head = data.prefix(headByteBudget)
        guard let text = String(data: head, encoding: .utf8) else {
            return Metadata(title: nil, messageCount: 0, gitBranch: nil)
        }
        // Count complete lines across the WHOLE file for messageCount; use the
        // head only for title/branch extraction.
        let totalLines = data.reduce(into: 0) { count, byte in
            if byte == UInt8(ascii: "\n") { count += 1 }
        }

        var title: String?
        var gitBranch: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            if gitBranch == nil, let branch = object["gitBranch"] as? String, !branch.isEmpty {
                gitBranch = branch
            }
            if title == nil, let extracted = userText(from: object) {
                title = sanitizeTitle(extracted)
            }
            if title != nil && gitBranch != nil { break }
        }
        return Metadata(title: title, messageCount: totalLines, gitBranch: gitBranch)
    }

    /// Extract user-authored text from a transcript record, if this is a user turn.
    private static func userText(from object: [String: Any]) -> String? {
        guard (object["type"] as? String) == "user",
              let message = object["message"] as? [String: Any] else { return nil }

        // content is either a string or an array of typed blocks.
        if let string = message["content"] as? String { return string }
        if let blocks = message["content"] as? [[String: Any]] {
            for block in blocks {
                if (block["type"] as? String) == "text",
                   let text = block["text"] as? String {
                    return text
                }
            }
        }
        return nil
    }

    private static func sanitizeTitle(_ raw: String) -> String {
        let firstLine = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? raw
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let maxLength = 80
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
