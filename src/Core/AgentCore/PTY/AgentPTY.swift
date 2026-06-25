import Foundation

/// Minimal PTY surface the engine needs after spawn.
///
/// `PTYHost` is the production owner of a real pseudo-terminal. Tests inject a
/// scripted implementation so command ordering can be verified without relying
/// on kernel timing or a child process exiting at just the right moment.
protocol AgentPTY: Sendable {
    var outboundBytes: AsyncStream<Data> { get }

    func write(_ data: Data) async throws
    func interrupt() async
    func close() async
}

typealias AgentPTYFactory = @Sendable (PTYHost.ChildSpec) throws -> any AgentPTY
