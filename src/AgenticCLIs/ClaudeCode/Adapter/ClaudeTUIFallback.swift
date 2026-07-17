import Foundation
import AgentCore

/// Best-effort screen-scraper used when neither hooks nor JSONL transcripts
/// are available (older Claude releases, headless mode without `npm`-side
/// installs). We scan the headless terminal's framebuffer for the box-drawn
/// banners Claude renders.
///
/// Lossy by design: this is the last-resort path. Once hooks are detected
/// during a session, `ClaudeAdapter` stops feeding us snapshots.
public actor ClaudeTUIFallback {

    static let workspaceTrustToolName = "WorkspaceTrust"

    private let clock: any AgentClock
    private let random: any RandomSource

    public init(clock: any AgentClock = SystemClock(),
                random: any RandomSource = SystemRandomSource()) {
        self.clock = clock
        self.random = random
    }

    /// Scan a snapshot for known patterns and return the events that haven't
    /// been emitted yet.
    public func ingest(snapshot: TerminalSnapshot) -> [AgentEvent] {
        var events: [AgentEvent] = []
        if let event = parseWorkspaceTrustScreen(snapshot) {
            let signature = TerminalLine(text: Self.workspaceTrustToolName, row: -1).signature
            if !seen.contains(signature) {
                seen.insert(signature)
                events.append(event)
            }
        }
        for line in snapshot.lines {
            if let event = parseLine(line) {
                guard !seen.contains(line.signature) else { continue }
                seen.insert(line.signature)
                events.append(event)
            }
        }
        return events
    }

    public func reset() {
        seen.removeAll()
    }

    // MARK: - Internal state (accessible via @testable import)

    /// Number of distinct line signatures already emitted. Exposed so unit
    /// tests can assert dedup behaviour without reaching into `seen` directly.
    var seenCount: Int { seen.count }

    private var seen: Set<Int> = []

    func parseLine(_ line: TerminalLine) -> AgentEvent? {
        let trimmed = line.text.trimmingCharacters(in: .whitespaces)
        if let path = matchEditing(trimmed) {
            return .fileTouched(URL(fileURLWithPath: path), kind: .tuiScraped)
        }
        if let url = matchAuthURL(trimmed) {
            _ = url
            return .error(.authenticationRequired(agentID: .claudeCode))
        }
        if let phrase = matchStatusPhrase(trimmed) {
            return .statusPhraseChanged(source: .tuiScrape, phrase: phrase)
        }
        return nil
    }

    private func matchEditing(_ line: String) -> String? {
        let patterns = ["Editing file: ", "Writing to: ", "Modified "]
        for prefix in patterns where line.contains(prefix) {
            if let range = line.range(of: prefix) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func matchAuthURL(_ line: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"https://claude\.ai/oauth/[^\s]+"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range, in: line) else { return nil }
        return URL(string: String(line[range]))
    }

    private func matchStatusPhrase(_ line: String) -> String? {
        let phrases = ["Working", "Thinking", "Running", "Reading", "Searching",
                       "Editing", "Writing", "Fetching", "Compacting"]
        for phrase in phrases where line.hasPrefix(phrase + "…") || line.hasPrefix(phrase + "...") {
            return phrase + "…"
        }
        return nil
    }

    private func parseWorkspaceTrustScreen(_ snapshot: TerminalSnapshot) -> AgentEvent? {
        let rows = snapshot.lines.map { normalized($0.text) }
        let compactRows = rows.map(compacted(_:))
        guard compactRows.contains(where: { $0.contains("quicksafetycheck:isthisaproject") }),
              compactRows.contains(where: { $0.contains("claudecode'llbeabletoread,edit,andexecutefileshere.") }),
              compactRows.contains(where: { $0.contains("1.yes,itrustthisfolder") }),
              compactRows.contains(where: { $0.contains("2.no,exit") }) else {
            return nil
        }

        let workspace = rows.drop(while: { !$0.contains("Accessing workspace:") })
            .dropFirst()
            .first(where: { !$0.isEmpty })

        return .permissionRequest(prompt: PermissionPrompt(
            id: random.uuid(),
            toolName: Self.workspaceTrustToolName,
            summary: "Trust this workspace?",
            argumentsSummary: workspace ?? "Claude is asking whether this folder should be trusted.",
            requestedAt: clock.now()
        ))
    }

    private func normalized(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compacted(_ line: String) -> String {
        normalized(line)
            .lowercased()
            .filter { !$0.isWhitespace }
    }
}

// MARK: - Terminal snapshot value types
//
// We keep our own tiny model rather than depend on SwiftTerm types here so the
// fallback parser stays unit-testable without a real terminal.

public struct TerminalLine: Sendable, Hashable {
    public let text: String
    public let row: Int

    public init(text: String, row: Int) {
        self.text = text
        self.row = row
    }

    /// Stable identifier for de-duplication across snapshot ticks.
    public var signature: Int {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(row)
        return hasher.finalize()
    }
}

public struct TerminalSnapshot: Sendable, Hashable {
    public let lines: [TerminalLine]
    public init(lines: [TerminalLine]) { self.lines = lines }

    public init(plainText: String) {
        self.lines = plainText.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { TerminalLine(text: String($0.element), row: $0.offset) }
    }
}
