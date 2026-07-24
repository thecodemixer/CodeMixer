import Foundation
import AgentCore

/// Classifies Claude Code's interactive input row from a headless VT snapshot.
///
/// Used by `ClaudeAdapter.classifyTerminalInput` so `AgentEngine`'s resume-startup
/// gate and first-prompt submit recovery stay vendor-agnostic. History paint
/// leaves prior `❯ <old text>` lines above the live input — only the **last**
/// prompt-looking row counts.
public enum ClaudeTerminalInputClassification: Sendable {

    public static func classify(_ rows: [String]) -> TerminalInputState {
        let normalizedRows = rows.map(normalizedRow(_:))
        let hasShortcutFooter = normalizedRows.contains { looksLikeShortcutFooter($0) }
        guard let lastPrompt = normalizedRows.last(where: {
            looksLikePrompt($0, hasShortcutFooter: hasShortcutFooter)
        }) else { return .unknown }

        var rest = lastPrompt
        while rest.hasPrefix("❯") || rest.hasPrefix(">") {
            rest.removeFirst()
        }
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.isEmpty {
            return .ready
        }
        return .unsubmitted
    }

    private static func looksLikePrompt(_ row: String, hasShortcutFooter: Bool) -> Bool {
        row.hasPrefix("❯") || (hasShortcutFooter && row.hasPrefix(">"))
    }

    /// Claude 2.x footers sometimes collapse spaces in the SwiftTerm buffer
    /// (`?forshortcuts`); accept both forms.
    private static func looksLikeShortcutFooter(_ row: String) -> Bool {
        row.contains("for shortcuts") || row.contains("forshortcuts")
    }

    private static func normalizedRow(_ row: String) -> String {
        // SwiftTerm back-fills unwritten cells with NUL when output advances rows
        // without a carriage return; strip those before trimming so prompt
        // detection sees the visible glyphs only.
        row
            .replacingOccurrences(of: "\u{0000}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
