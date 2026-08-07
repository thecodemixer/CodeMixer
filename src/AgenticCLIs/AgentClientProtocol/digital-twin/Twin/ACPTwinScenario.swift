import Foundation

/// Scripted ACP server scenarios shared by `fake-acp` and integration tests.
public enum ACPTwinScenario: String, Sendable {
    case text
    case permission
    case fsRead
    case auth
    case authFail
    case resume
    case dashboard
    case backgroundPermission
    /// Authenticated agent with no dashboard URL (client must not expect WebView).
    case degradedNoDashboard
    /// Emits `session_info_update` with `_meta.archived: true`.
    case degradedArchived
    /// Replies with `echo:<prompt text>` instead of a canned string, so a test
    /// can prove which prompt bytes actually reached the agent process. Needed
    /// for edit-and-resubmit, where the failure mode is a revised prompt that
    /// is written but never arrives.
    case echo

    public static func from(environment: [String: String]) -> Self {
        guard let raw = environment["CODEMIXER_TWIN_SCENARIO"],
              let scenario = Self(rawValue: raw) else {
            return .text
        }
        return scenario
    }

    /// Prefix the `echo` scenario puts in front of the received prompt text.
    public static let echoReplyPrefix = "echo:"

    public var defaultReply: String {
        switch self {
        case .text, .permission, .fsRead, .resume, .dashboard, .backgroundPermission,
             .degradedNoDashboard, .degradedArchived, .authFail:
            return "Hello from fake-acp."
        case .auth:
            return "Hello from authenticated fake-acp."
        case .echo:
            return Self.echoReplyPrefix
        }
    }

    /// Whether initialize should advertise a dashboard URL.
    public var advertisesDashboard: Bool {
        self == .dashboard
    }

    public var isPreAuthenticated: Bool {
        switch self {
        case .auth, .authFail:
            return false
        case .text, .permission, .fsRead, .resume, .dashboard, .backgroundPermission,
             .degradedNoDashboard, .degradedArchived, .echo:
            return true
        }
    }
}
