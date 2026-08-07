import Foundation

/// Shared timing constants for activity escalation and UI affordances.
///
/// Server-side escalation (`noEventGap`, heartbeat thresholds) remains
/// canonical and is **not** affected by the UI-only Reduce Motion preference.
/// UI-only durations are named here so clients do not grow unexplained
/// timeout literals.
public enum ActivityTiming {
    public static let noEventPollInterval: Duration = .milliseconds(500)
    public static let stillWorkingThreshold: Duration = .seconds(10)
    public static let probablyStuckThreshold: Duration = .seconds(90)
    public static let stalledToastDuration: Duration = .seconds(8)
    public static let stillWorkingPhrase = "Still working…"
    /// Shown the instant a prompt is sent, before the engine emits its first
    /// real status phrase. Keeps the optimistic-send path free of literals.
    public static let workingPhrase = "Working…"
    /// How long after an optimistic send (or a materialised user turn) a
    /// matching `.userTurn` echo is treated as the same turn rather than a new
    /// one. Covers the engine echo plus the Claude `UserPromptSubmit` hook echo.
    public static let userTurnEchoWindow: Duration = .seconds(10)
    /// How long the "project removed · Undo" toast stays offered before the
    /// removal becomes final.
    public static let undoToastWindow: Duration = .seconds(8)
    /// Composer gate while the **first** agent process for a project is spawning
    /// (Cursor initialize/auth is the long case). Project switch and session
    /// resume on a live pooled agent use the shorter budgets below.
    public static let sessionHandshakeColdStartTimeout: Duration = .seconds(120)
    /// Composer gate while restoring / loading an existing session on an
    /// already-known project (local history + adapter resume / session/load).
    public static let sessionHandshakeResumeTimeout: Duration = .seconds(45)
    /// Composer gate when switching to a project whose agent is already pooled,
    /// or starting a new chat on that live process.
    public static let sessionHandshakeWarmTimeout: Duration = .seconds(45)
    /// Granularity of the engine's wait for a respawned agent to accept
    /// prompts (`editAndResubmitLast`). The budget itself is
    /// `sessionHandshakeColdStartTimeout`: the pre-edit process is gone, so the
    /// respawn really is a cold start, and a revised turn written before the
    /// agent's input is live is lost with no error anywhere.
    public static let promptReadinessPollInterval: Duration = .milliseconds(100)
    /// Default status phrase when no higher-priority source is active.
    public static let idlePhrase = "Idle"
    /// Fallback heuristic phrase when sources are cleared but the turn is active.
    public static let thinkingPhrase = "Thinking…"
}
