import Foundation
import AgentCore
import AgentProtocol

/// Adapter that drives the engine from a pre-scripted event sequence.
/// Useful for UI tests, parity tests, and integration coverage that shouldn't
/// reach for the real `claude` binary.
public final class MockAdapter: AgentAdapter, @unchecked Sendable {

    public let id: AgentID = .other
    public let displayName = "Mock"
    public let iconSymbol = "ant"
    public let capabilities: AgentCapabilities = []
    public var transportDescriptor: AgentTransportDescriptor { .interactiveTerminal }
    public var slashCommandCatalog: [SlashCommand] { [] }

    public struct Script: Sendable {
        public let events: [AgentEvent]
        public let interEventDelay: Duration
        public init(events: [AgentEvent], interEventDelay: Duration = .milliseconds(20)) {
            self.events = events
            self.interEventDelay = interEventDelay
        }
        public static let empty = Script(events: [])
    }

    private let script: Script
    private let binary: URL

    public init(script: Script = .empty,
                binary: URL = URL(fileURLWithPath: "/usr/bin/true")) {
        self.script = script
        self.binary = binary
    }

    public func locateBinary(env: ResolvedEnvironment) async throws -> URL { binary }
    public func defaultEnvOverrides() -> [String: String] { [:] }
    public func buildLaunchArgv(context: LaunchContext) -> [String] { ["true"] }

    public func authStatus(env: ResolvedEnvironment) async -> AuthStatus { .authenticated(account: "mock") }

    public func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            Task {
                for event in script.events {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: script.interEventDelay)
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }

    public func encodeUserPrompt(_ text: String) -> Data { Data(text.utf8) }
    public func cancelSequence() -> Data { Data([0x03]) }

    public func encodePermissionResponse(_ decision: PermissionDecision,
                                         for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        .writePTY(Data())
    }

    public func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] { [] }
    public func listResumableSessions(workspace: URL) async -> [SessionSummary] { [] }
    public func resumeArgvAddition(sessionID: String) -> [String] { [] }
}
