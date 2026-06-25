import Foundation

/// User response to a tool-permission prompt.
public enum PermissionDecision: String, Sendable, Codable, Hashable {
    /// Allow this single invocation.
    case allow
    /// Allow this and every future matching invocation in the current session.
    case allowAlways
    /// Deny this invocation.
    case deny
}

/// Coarse permission policy for a session — mirrors `claude --permission-mode`.
public enum PermissionMode: String, Sendable, Codable, Hashable {
    case `default`
    case acceptEdits
    case bypassPermissions
    case plan
}

/// Text-to-speech intent for a specific assistant bubble.
public enum TTSAction: String, Sendable, Codable, Hashable {
    case play
    case pause
    case stop
}

/// Reason a session ended.
public enum StopReason: String, Sendable, Codable, Hashable {
    case userCancel
    case naturalExit
    case spawnFailed
    case crashed
    case authExpired
}

/// File-touched event source — distinguishes "agent says it touched" from
/// "filesystem actually changed."
public enum FileChangeKind: String, Sendable, Codable, Hashable {
    /// Reported by an adapter hook (e.g. Claude `PostToolUse` for Edit/Write).
    case hookReported
    /// Detected by FSEvents — ground truth.
    case fsObserved
    /// Scraped from the TUI fallback parser.
    case tuiScraped
}

/// Source authority for the displayed status phrase.
///
/// Higher cases override lower when multiple are simultaneously valid.
public enum StatusPhraseSource: Int, Sendable, Codable, Hashable, Comparable {
    case heuristic = 0
    case tuiScrape = 1
    case hookHint = 2
    case adapterPinned = 3

    public static func < (lhs: StatusPhraseSource, rhs: StatusPhraseSource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Derived "what is the engine doing right now?" substate, used for activity
/// indicators. Pure presentation hint — the engine state machine is the source
/// of truth.
public enum ActivitySubstate: String, Sendable, Codable, Hashable {
    case idle
    case awaitingFirstChunk
    case streamingText
    case thinking
    case runningTool
    case waitingPermission
    case stillWorking          // 10s gap with no events
    case probablyStuck         // 90s gap
}
