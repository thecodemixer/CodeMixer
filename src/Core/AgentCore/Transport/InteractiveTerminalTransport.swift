import Foundation

/// Interactive-terminal transport: real PTY + headless VT emulation.
///
/// Used by Claude Code so the child runs as an interactive terminal session,
/// staying off the Agent Credits path used by third-party / SDK-style
/// invocations. The PTY is private to this type; the engine only sees
/// `AgentTransport`.
///
/// Policy: feed every outbound chunk into `TerminalEngine`, expose snapshots,
/// emit bell events, and deliberately do **not** write
/// `TerminalEngine.outboundReplies` back to the child.
actor InteractiveTerminalTransport: AgentTransport {
    nonisolated let outboundBytes: AsyncStream<Data>
    nonisolated let bellEvents: AsyncStream<Void>
    nonisolated var terminalSnapshot: (any TerminalSnapshotting)? { terminal }

    private let host: PTYHost
    private let terminal: TerminalEngine
    private let outboundContinuation: AsyncStream<Data>.Continuation
    private let bellContinuation: AsyncStream<Void>.Continuation
    private var closed = false

    init(launch: AgentTransportLaunchSpec) throws {
        let host = try PTYHost(launch: launch)
        let terminal = TerminalEngine(size: launch.windowSize)
        self.host = host
        self.terminal = terminal

        var outboundCont: AsyncStream<Data>.Continuation!
        self.outboundBytes = AsyncStream(
            bufferingPolicy: .bufferingOldest(StreamBufferDefaults.ptyChunks)
        ) { outboundCont = $0 }
        self.outboundContinuation = outboundCont

        var bellCont: AsyncStream<Void>.Continuation!
        self.bellEvents = AsyncStream(
            bufferingPolicy: .bufferingOldest(StreamBufferDefaults.terminalReplies)
        ) { bellCont = $0 }
        self.bellContinuation = bellCont

        let hostBytes = host.outboundBytes
        Task { [weak self] in
            for await chunk in hostBytes {
                await self?.handleChunk(chunk)
            }
            await self?.finishStreams()
        }
    }

    func write(_ data: Data) async throws {
        try await host.write(data)
    }

    func interrupt() async {
        await host.interrupt()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        await host.close()
        finishStreams()
    }

    private func handleChunk(_ chunk: Data) async {
        guard !closed else { return }
        await terminal.feed(chunk)
        if await terminal.consumeBell() {
            bellContinuation.yield(())
        }
        outboundContinuation.yield(chunk)
    }

    private func finishStreams() {
        outboundContinuation.finish()
        bellContinuation.finish()
    }
}
