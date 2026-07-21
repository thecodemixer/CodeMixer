import Foundation

/// User response to a tool-permission prompt.
public enum PermissionDecision: Sendable, Hashable, Equatable {
    /// Allow this single invocation.
    case allow
    /// Allow this and every future matching invocation in the current session.
    case allowAlways
    /// Deny this invocation.
    case deny
    /// Select a custom ACP permission option by id.
    case option(id: String)
}

extension PermissionDecision: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, id
    }

    private enum Kind: String, Codable {
        case allow, allowAlways, deny, option
    }

    /// Stable string for wire error context and legacy persistence.
    public var wireValue: String {
        switch self {
        case .allow: "allow"
        case .allowAlways: "allowAlways"
        case .deny: "deny"
        case .option(let id): "option:\(id)"
        }
    }

    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let raw = try? container.decode(String.self) {
            switch raw {
            case "allow": self = .allow
            case "allowAlways": self = .allowAlways
            case "deny": self = .deny
            default:
                if raw.hasPrefix("option:") {
                    self = .option(id: String(raw.dropFirst("option:".count)))
                } else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Unknown PermissionDecision: \(raw)"
                    )
                }
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .allow: self = .allow
        case .allowAlways: self = .allowAlways
        case .deny: self = .deny
        case .option:
            self = .option(id: try container.decode(String.self, forKey: .id))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .allow, .allowAlways, .deny:
            var container = encoder.singleValueContainer()
            try container.encode(wireValue)
        case .option(let id):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Kind.option, forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
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
