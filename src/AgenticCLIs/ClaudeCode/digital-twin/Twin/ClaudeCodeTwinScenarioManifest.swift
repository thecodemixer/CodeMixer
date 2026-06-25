import Foundation

/// JSON manifest for complex scripted scenarios (`CODEMIXER_TWIN_SCENARIO_FILE`).
public struct ClaudeCodeTwinScenarioManifest: Decodable, Sendable {
    public var sessionID: String?
    public var model: String?
    public var permissionMode: String?
    public var turns: [Turn]

    public struct Turn: Decodable, Sendable {
        public var prompt: String?
        public var scenario: String
        public var reply: String?
    }

    public func resolvedSessionID() -> String {
        sessionID ?? ClaudeCodeTwinIdentifiers.sessionID()
    }

    public func scenario(for turn: Turn) -> ClaudeCodeTwinScenario? {
        if let named = ClaudeCodeTwinScenario.named(turn.scenario) { return named }
        if turn.scenario == "text-only", let reply = turn.reply {
            return .textOnly(reply: reply)
        }
        return nil
    }
}
