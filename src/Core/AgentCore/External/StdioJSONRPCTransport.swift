import Darwin
import Foundation
import OSLog

/// Long-lived stdio JSON-RPC transport for agents like Codex App Server.
///
/// Spawns a child with stdin/stdout/stderr pipes. `outboundBytes` is stdout
/// only. Stderr is kept as a bounded 64 KiB diagnostic tail and is never
/// exposed as agent output. `interrupt()` is a no-op — protocol cancels are
/// written as normal frames. `close()` closes stdin, terminates, waits 2s,
/// then SIGKILL.
///
/// Sole production boundary for `Foundation.Process` used as a persistent
/// agent session (one-shot helpers still use `ProcessRunner`).
public actor StdioJSONRPCTransport: AgentTransport {
    public nonisolated let outboundBytes: AsyncStream<Data>
    public nonisolated let bellEvents: AsyncStream<Void>
    public nonisolated var terminalSnapshot: (any TerminalSnapshotting)? { nil }

    private enum State { case idle, connected, closing, closed }

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "StdioJSONRPC")
    private var state: State = .idle
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stderrTail = Data()
    private var outboundContinuation: AsyncStream<Data>.Continuation?
    private var bellContinuation: AsyncStream<Void>.Continuation?

    private static let stderrTailLimit = 65_536
    private static let terminateGrace: Duration = .seconds(2)

    public init(launch: AgentTransportLaunchSpec) throws {
        var outboundCont: AsyncStream<Data>.Continuation!
        self.outboundBytes = AsyncStream(
            bufferingPolicy: .bufferingOldest(StreamBufferDefaults.ptyChunks)
        ) { outboundCont = $0 }
        self.outboundContinuation = outboundCont

        var bellCont: AsyncStream<Void>.Continuation!
        self.bellEvents = AsyncStream(
            bufferingPolicy: .bufferingOldest(8)
        ) { bellCont = $0 }
        self.bellContinuation = bellCont
        // Empty bell stream for non-terminal transports — finish immediately
        // so consumers don't hang waiting for bells that will never arrive.
        bellCont.finish()
        self.bellContinuation = nil

        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        child.executableURL = launch.executable
        child.arguments = launch.arguments
        child.environment = launch.environment
        child.currentDirectoryURL = launch.workingDirectory
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        process = child
        stdinHandle = stdin.fileHandleForWriting
        state = .connected

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receiveStdout(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receiveStderr(data) }
        }
        child.terminationHandler = { [weak self] process in
            Task { await self?.processExited(code: process.terminationStatus) }
        }

        do {
            try child.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw AgentTransportError.launchFailed(detail: error.localizedDescription)
        }

        log.notice("stdio transport spawned pid=\(child.processIdentifier, privacy: .public)")
    }

    public func write(_ data: Data) async throws {
        guard state == .connected, let stdinHandle else {
            throw AgentTransportError.alreadyClosed
        }
        guard !data.isEmpty else { return }
        do {
            try stdinHandle.write(contentsOf: data)
        } catch {
            throw AgentTransportError.writeFailed(detail: error.localizedDescription)
        }
    }

    public func interrupt() async {
        // Protocol cancels are written as normal frames; no SIGINT.
    }

    public func close() async {
        guard state != .closed, state != .closing else { return }
        state = .closing
        try? stdinHandle?.close()
        stdinHandle = nil

        if let process, process.isRunning {
            process.terminate()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: Self.terminateGrace)
            while process.isRunning, clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }
        finish()
    }

    // MARK: - Private

    private func receiveStdout(_ data: Data) {
        guard state == .connected else { return }
        guard !data.isEmpty else { return }
        outboundContinuation?.yield(data)
    }

    private func receiveStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrTail.append(data)
        if stderrTail.count > Self.stderrTailLimit {
            stderrTail.removeFirst(stderrTail.count - Self.stderrTailLimit)
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            log.debug("stderr: \(text, privacy: .public)")
            Task {
                await SilentDiagnostics.shared.record(
                    kind: .other,
                    owner: "StdioJSONRPCTransport",
                    summary: "agent stderr",
                    details: text
                )
            }
        }
    }

    private func processExited(code: Int32) {
        guard state != .closed else { return }
        if state == .closing || code == 0 {
            finish()
        } else {
            let stderr = String(decoding: stderrTail, as: UTF8.self)
            log.error("stdio child exited code=\(code, privacy: .public)")
            Task {
                await SilentDiagnostics.shared.record(
                    kind: .other,
                    owner: "StdioJSONRPCTransport",
                    summary: "process exited \(code)",
                    details: stderr
                )
            }
            finish()
        }
    }

    private func finish() {
        guard state != .closed else { return }
        state = .closed
        outboundContinuation?.finish()
        outboundContinuation = nil
        try? stdinHandle?.close()
        stdinHandle = nil
        process = nil
    }
}
