import Foundation

/// One user submission and the scripted twin response that follows.
public struct ClaudeCodeTwinTurn: Sendable, Equatable {
    public var userPrompt: String
    public var scenario: ClaudeCodeTwinScenario

    public init(userPrompt: String, scenario: ClaudeCodeTwinScenario) {
        self.userPrompt = userPrompt
        self.scenario = scenario
    }
}
