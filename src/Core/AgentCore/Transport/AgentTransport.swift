import Foundation

/// How an agent child is connected to the engine.
///
/// Terminal emulation is one strategy (Claude Code, to avoid Agent Credits from
/// third-party / SDK-style invocations), not the engine model. Stdio JSON-RPC is
/// used by Codex App Server. Agent Client Protocol is reserved for a future
/// transport implementation.
public enum AgentTransportKind: String, Sendable, Hashable, Codable {
    case interactiveTerminal
    case stdioJSONRPC
    case agentClientProtocol
}

/// Adapter-declared transport policy. Adapters use the static descriptors so
/// invalid kind/flag combinations cannot be constructed downstream.
public struct AgentTransportDescriptor: Sendable, Hashable, Codable {
    public let kind: AgentTransportKind
    public let requiresTerminalEmulation: Bool
    public let supportsOutOfBandInterrupt: Bool

    private init(kind: AgentTransportKind,
                 requiresTerminalEmulation: Bool,
                 supportsOutOfBandInterrupt: Bool) {
        self.kind = kind
        self.requiresTerminalEmulation = requiresTerminalEmulation
        self.supportsOutOfBandInterrupt = supportsOutOfBandInterrupt
    }

    public static let interactiveTerminal = AgentTransportDescriptor(
        kind: .interactiveTerminal,
        requiresTerminalEmulation: true,
        supportsOutOfBandInterrupt: true
    )

    public static let stdioJSONRPC = AgentTransportDescriptor(
        kind: .stdioJSONRPC,
        requiresTerminalEmulation: false,
        supportsOutOfBandInterrupt: false
    )

    public static let agentClientProtocol = AgentTransportDescriptor(
        kind: .agentClientProtocol,
        requiresTerminalEmulation: false,
        supportsOutOfBandInterrupt: false
    )

    /// Reconstruct a static descriptor from its kind. Encoding persists only
    /// `kind` so invalid flag combinations cannot be reconstituted from disk.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let kind = try container.decode(AgentTransportKind.self)
        switch kind {
        case .interactiveTerminal: self = .interactiveTerminal
        case .stdioJSONRPC: self = .stdioJSONRPC
        case .agentClientProtocol: self = .agentClientProtocol
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(kind)
    }
}

/// Transport-neutral child launch description. PTY-named types stay inside
/// `InteractiveTerminalTransport`; stdio/client-protocol transports never
/// depend on them.
public struct AgentTransportLaunchSpec: Sendable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: URL?
    public let windowSize: WindowSize

    public init(executable: URL,
                arguments: [String],
                environment: [String: String],
                workingDirectory: URL?,
                windowSize: WindowSize = .default) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.windowSize = windowSize
    }
}

/// Minimal transport surface the engine needs after spawn.
///
/// Production implementations own a PTY session or a stdio process. Tests
/// inject a scripted implementation so command ordering can be verified
/// without kernel timing.
protocol AgentTransport: Sendable {
    var outboundBytes: AsyncStream<Data> { get }
    var bellEvents: AsyncStream<Void> { get }
    var terminalSnapshot: (any TerminalSnapshotting)? { get }

    func write(_ data: Data) async throws
    func interrupt() async
    func close() async
}

typealias AgentTransportFactory = @Sendable (
    AgentTransportDescriptor,
    AgentTransportLaunchSpec
) throws -> any AgentTransport

/// Failures raised by the transport factory / stdio host.
public enum AgentTransportError: Error, Sendable, Equatable {
    case unsupportedKind(AgentTransportKind)
    case launchFailed(detail: String)
    case alreadyClosed
    case processExited(code: Int32, stderr: String)
    case writeFailed(detail: String)
}

/// Default factory: interactive terminal wraps `PTYHost` + `TerminalEngine`;
/// stdio JSON-RPC wraps `StdioJSONRPCTransport`; ACP is reserved.
enum LiveAgentTransportFactory {
    static func make(descriptor: AgentTransportDescriptor,
                     launch: AgentTransportLaunchSpec) throws -> any AgentTransport {
        switch descriptor.kind {
        case .interactiveTerminal:
            return try InteractiveTerminalTransport(launch: launch)
        case .stdioJSONRPC:
            return try StdioJSONRPCTransport(launch: launch)
        case .agentClientProtocol:
            throw AgentTransportError.unsupportedKind(.agentClientProtocol)
        }
    }
}
