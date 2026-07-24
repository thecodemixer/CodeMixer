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
    /// Fresh TUI sessions should reach an empty prompt quickly. If they do not,
    /// release the send gate rather than leaving the first prompt blocked.
    public static let resumeStartupStallTimeout: Duration = .seconds(8)
    /// Resumed Claude sessions paint history before the prompt row. Prefer
    /// prompt-ready detection, but fall back quickly enough that missed TUI
    /// scrapes do not make the first resumed prompt feel stuck.
    public static let resumedSessionStartupStallTimeout: Duration = .seconds(12)
    /// Once Claude has confirmed the resumed session via hook `SessionStart`,
    /// missing a ready-prompt scrape should fall back soon — but not so soon
    /// that history paint still owns the PTY when we write the first prompt.
    /// Recovery can re-send, yet cold `--resume` often needs several seconds
    /// before the live input row is stable.
    public static let resumedSessionPostSessionStartFallback: Duration = .seconds(6)
    /// After hook `SessionStart`, ignore ready-prompt scrapes briefly so
    /// history paint / chrome cannot false-open the send gate.
    public static let resumePromptReadySettleDelay: Duration = .milliseconds(250)
    /// Short because this sits on the send path after Claude has visually
    /// reached the prompt. It runs only during resumed-session startup.
    public static let resumePromptReadyPollInterval: Duration = .milliseconds(25)
    /// Recovery-only: after a startup-held prompt is written, this gives
    /// Claude's `UserPromptSubmit` hook time to arrive before sending one
    /// extra Enter if the prompt is still visibly sitting in the input row.
    public static let startupSubmitRecoveryDelay: Duration = .milliseconds(750)
    /// How many recovery polls to keep confirming delivery of the first resumed
    /// prompt. `claude --resume` paints JSONL history and chrome for seconds
    /// after the UI already shows it, so recovery must persist (re-pressing
    /// Enter or re-sending the prompt) until Claude's live `UserPromptSubmit`
    /// hook confirms acceptance. At `startupSubmitRecoveryDelay` per tick this
    /// spans ~18s, comfortably past a cold resume, without waiting forever.
    public static let startupSubmitRecoveryMaxAttempts = 24
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
