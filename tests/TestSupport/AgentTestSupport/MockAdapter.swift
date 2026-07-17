import Foundation
import os
import AgentCore
import AgentProtocol

/// Adapter that drives the engine from a pre-scripted event sequence.
/// Useful for UI tests, parity tests, and integration coverage that shouldn't
/// reach for the real `claude` binary.
public final class MockAdapter: AgentAdapter, @unchecked Sendable {

    public let id: AgentID
    public let displayName: String
    public let iconSymbol = "ant"
    public let capabilities: AgentCapabilities
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
    private let refreshKind: ModelCatalogRefreshKind
    private let state: OSAllocatedUnfairLock<State>

    private struct State {
        var models: [AgentModelOption] = []
        var refreshCount = 0
        var refreshResult: [AgentModelOption]?
    }

    public init(script: Script = .empty,
                binary: URL = URL(fileURLWithPath: "/usr/bin/true"),
                id: AgentID = .other,
                displayName: String = "Mock",
                capabilities: AgentCapabilities = [],
                models: [AgentModelOption] = [],
                refreshKind: ModelCatalogRefreshKind = .automatic,
                refreshResult: [AgentModelOption]? = nil) {
        self.script = script
        self.binary = binary
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
        self.refreshKind = refreshKind
        self.state = OSAllocatedUnfairLock(initialState: State(
            models: models,
            refreshResult: refreshResult
        ))
    }

    public var refreshCallCount: Int {
        state.withLock { $0.refreshCount }
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

    public func availableModels() -> [AgentModelOption] {
        state.withLock { $0.models }
    }

    public func modelCatalogRefreshKind() -> ModelCatalogRefreshKind {
        refreshKind
    }

    public func refreshModelCatalog() async throws -> [AgentModelOption] {
        state.withLock {
            $0.refreshCount += 1
            let probed = $0.refreshResult ?? $0.models
            $0.models = probed
            return probed
        }
    }

    public func seedModelCatalog(_ models: [AgentModelOption]) {
        state.withLock { $0.models = models }
    }

    public func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] { [] }
    public func listResumableSessions(workspace: URL) async -> [SessionSummary] { [] }
    public func resumeArgvAddition(sessionID: String) -> [String] { [] }
}
