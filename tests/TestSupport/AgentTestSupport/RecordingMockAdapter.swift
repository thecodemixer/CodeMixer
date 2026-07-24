import Foundation
import AgentCore
import AgentProtocol

/// Test adapter that records every command-shaped interaction
/// (`encodeUserPrompt`, `cancelSequence`, `encodePermissionResponse`) for
/// later assertion, while letting the test feed events back through an
/// injectable `AsyncStream` continuation.
///
/// Tests use this to assert that a given `AgentCommand` produced exactly the
/// expected adapter calls — without spawning a real CLI.
public final class RecordingMockAdapter: AgentAdapter, @unchecked Sendable {

    public enum Recorded: Sendable, Equatable {
        case userPrompt(String)
        case cancel
        case permissionResponse(PermissionDecision, promptID: UUID)
    }

    public let id: AgentID = .other
    public let displayName = "Recording Mock"
    public let iconSymbol = "ant"
    public let capabilities: AgentCapabilities
    public var transportDescriptor: AgentTransportDescriptor { .interactiveTerminal }
    public var slashCommandCatalog: [SlashCommand] { [] }

    private let lock = NSLock()
    private var _recorded: [Recorded] = []
    private var continuation: AsyncStream<AgentEvent>.Continuation?

    private let binaryURL: URL
    private let permissionDelivery: PermissionResponseDelivery
    /// Optional TUI input classifier (Claude glyph heuristics in AgentCoreTests).
    public var terminalInputClassifier: (@Sendable ([String]) -> TerminalInputState)?

    public init(binary: URL = SystemPaths.cat,
                capabilities: AgentCapabilities = [],
                permissionDelivery: PermissionResponseDelivery = .writePTY(Data()),
                terminalInputClassifier: (@Sendable ([String]) -> TerminalInputState)? = nil) {
        self.binaryURL = binary
        self.capabilities = capabilities
        self.permissionDelivery = permissionDelivery
        self.terminalInputClassifier = terminalInputClassifier
    }

    public var recorded: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return _recorded
    }

    /// Push an event into the live event stream. Returns false if the stream
    /// hasn't been created yet (i.e. the engine hasn't started).
    @discardableResult
    public func emit(_ event: AgentEvent) -> Bool {
        lock.lock()
        let cont = continuation
        lock.unlock()
        guard let cont else { return false }
        cont.yield(event)
        return true
    }

    public func finish() {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.finish()
    }

    // MARK: AgentAdapter

    public func locateBinary(env: ResolvedEnvironment) async throws -> URL { binaryURL }
    public func defaultEnvOverrides() -> [String: String] { [:] }
    public func buildLaunchArgv(context: LaunchContext) -> [String] { [binaryURL.lastPathComponent] }

    public func authStatus(env: ResolvedEnvironment) async -> AuthStatus { .authenticated(account: "mock") }

    public func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent> {
        AsyncStream { cont in
            lock.lock()
            self.continuation = cont
            lock.unlock()
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuation = nil
                self.lock.unlock()
            }
        }
    }

    public func encodeUserPrompt(_ text: String) -> Data {
        lock.lock(); _recorded.append(.userPrompt(text)); lock.unlock()
        return Data(text.utf8)
    }

    public func classifyTerminalInput(rows: [String]) -> TerminalInputState {
        terminalInputClassifier?(rows) ?? .unknown
    }

    public func cancelSequence() -> Data {
        lock.lock(); _recorded.append(.cancel); lock.unlock()
        return Data([0x03])
    }

    public func encodePermissionResponse(_ decision: PermissionDecision,
                                         for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        lock.lock()
        _recorded.append(.permissionResponse(decision, promptID: prompt.id))
        lock.unlock()
        return permissionDelivery
    }

    public func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] { [] }
    public func listResumableSessions(workspace: URL) async -> [SessionSummary] { [] }
    public func resumeArgvAddition(sessionID: String) -> [String] { [] }
}
