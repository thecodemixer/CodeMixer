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
    /// Resume should fire `SessionStart:resume` almost immediately. If it does
    /// not, reuse the stalled-turn affordance instead of leaving old sessions
    /// looking idle and empty.
    public static let resumeStartupStallTimeout: Duration = .seconds(8)
    /// Short because this sits on the send path after Claude has visually
    /// reached the prompt. It runs only during resumed-session startup.
    public static let resumePromptReadyPollInterval: Duration = .milliseconds(25)
    /// Recovery-only: after a startup-held prompt is written, this gives
    /// Claude's `UserPromptSubmit` hook time to arrive before sending one
    /// extra Enter if the prompt is still visibly sitting in the input row.
    public static let startupSubmitRecoveryDelay: Duration = .milliseconds(750)
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
    /// Default status phrase when no higher-priority source is active.
    public static let idlePhrase = "Idle"
    /// Fallback heuristic phrase when sources are cleared but the turn is active.
    public static let thinkingPhrase = "Thinking…"
}
