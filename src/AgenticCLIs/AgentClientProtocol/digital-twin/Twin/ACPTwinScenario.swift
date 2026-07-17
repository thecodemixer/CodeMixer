import Foundation

/// Scripted ACP server scenarios shared by `fake-acp` and integration tests.
public enum ACPTwinScenario: String, Sendable {
    case text
    case permission
    case fsRead
    case auth
    case authFail
    case resume

    public static func from(environment: [String: String]) -> Self {
        guard let raw = environment["CODEMIXER_TWIN_SCENARIO"],
              let scenario = Self(rawValue: raw) else {
            return .text
        }
        return scenario
    }

    public var defaultReply: String {
        switch self {
        case .text, .permission, .fsRead, .resume, .authFail:
            return "Hello from fake-acp."
        case .auth:
            return "Hello from authenticated fake-acp."
        }
    }
}
