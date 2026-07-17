import CPosixBridge
import Darwin
import Dispatch
import Foundation
import OSLog

/// Owns one pseudo-terminal master and the spawned child attached to its
/// slave end. Reads stream out as `AsyncStream<Data>`; writes are async and
/// resolve when the master accepts the bytes.
///
/// Lifecycle is symmetric: every `PTYHost` instance must be `closed()`
/// exactly once. After close, the host is inert — further reads complete the
/// stream, further writes throw `.alreadyClosed`. The reaper task awaits the
/// child's exit and forwards the status via `exitStatus`.
public actor PTYHost {

    /// Description of the child to spawn under the new pty.
    public struct ChildSpec: Sendable {
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

    /// How the child finished.
    public enum ExitStatus: Sendable, Equatable {
        case exited(code: Int32)
        case signaled(signal: Int32)
    }

    // MARK: - State

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "PTYHost")
    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var readSource: (any DispatchSourceRead)?
    private var outboundContinuation: AsyncStream<Data>.Continuation?
    private var exitContinuation: CheckedContinuation<ExitStatus, Never>?
    private var isClosed = false

    /// Live byte stream from the master fd. Buffered to 256 chunks; on
    /// pressure we drop the *oldest* unconsumed chunks (presentation is fine
    /// with that — humans don't notice 1ms of skipped bytes mid-burst).
    public nonisolated let outboundBytes: AsyncStream<Data>

    /// Resolves when the child exits.
    public let exitStatus: Task<ExitStatus, Never>

    // MARK: - Init

    public init(spec: ChildSpec) throws {
        var continuation: AsyncStream<Data>.Continuation!
        self.outboundBytes = AsyncStream(bufferingPolicy: .bufferingOldest(StreamBufferDefaults.ptyChunks)) { c in
            continuation = c
        }

        var exitC: CheckedContinuation<ExitStatus, Never>!
        self.exitStatus = Task { await withCheckedContinuation { c in exitC = c } }

        // Allocate the pty pair first — easy to back out of.
        var master: Int32 = -1
        var slave: Int32 = -1
        guard cpx_openpty(&master, &slave) == 0 else {
            throw PTYError.openptyFailed(errno: errno)
        }

        // Set the window size on the slave so curses-style apps see it at startup.
        if cpx_set_winsize(slave,
                           spec.windowSize.rows,
                           spec.windowSize.cols) != 0 {
            let saved = errno
            Darwin.close(master); Darwin.close(slave)
            throw PTYError.setWinsizeFailed(errno: saved)
        }

        let exePath = spec.executable.path
        let cwdPath = spec.workingDirectory?.path

        // Build argv / envp as NULL-terminated C-string arrays. We own the
        // strdup'd memory and free it at function exit.
        var argv: [UnsafeMutablePointer<CChar>?] =
            ([exePath] + spec.arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] =
            spec.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in argv where p != nil { free(p) }
            for p in envp where p != nil { free(p) }
        }

        var pid: pid_t = -1
        let spawnResult = argv.withUnsafeMutableBufferPointer { argvBuf in
            envp.withUnsafeMutableBufferPointer { envpBuf in
                cpx_spawn_under_pty(exePath,
                                    argvBuf.baseAddress,
                                    envpBuf.baseAddress,
                                    cwdPath,
                                    slave,
                                    &pid)
            }
        }

        // Parent always closes its copy of the slave — the child has its own.
        Darwin.close(slave)

        guard spawnResult == 0 else {
            Darwin.close(master)
            throw PTYError.spawnFailed(errno: spawnResult, executable: exePath)
        }

        self.masterFD = master
        self.childPID = pid
        self.outboundContinuation = continuation
        self.exitContinuation = exitC

        log.notice("PTY spawned pid=\(pid, privacy: .public) exe=\(exePath, privacy: .public)")

        Task { await self.startReadLoop() }
        Task { await self.reapChild() }
    }

    // MARK: - Public surface

    /// Write `data` to the master end. Returns when all bytes are accepted by
    /// the kernel (short writes are looped). Throws `.alreadyClosed` after
    /// `close()`, `.writeFailed(errno:)` on hard IO errors.
    public func write(_ data: Data) async throws {
        guard !isClosed else { throw PTYError.alreadyClosed }
        guard !data.isEmpty else { return }
        let fd = masterFD
        try await writeAllToPTY(data) { chunk in
            var savedErrno: Int32 = 0
            let written: Int = chunk.withUnsafeBytes { buf in
                let result = Darwin.write(fd, buf.baseAddress, buf.count)
                if result == -1 { savedErrno = errno }
                return result
            }
            return (written, savedErrno)
        }
    }

    /// Send SIGINT (Ctrl-C equivalent) to the child's process group.
    public func interrupt() {
        guard !isClosed, childPID > 0 else { return }
        _ = cpx_killpg(childPID, SIGINT)
    }

    /// Resize the pty.
    public func resize(to size: WindowSize) throws {
        guard !isClosed else { throw PTYError.alreadyClosed }
        guard cpx_set_winsize(masterFD, size.rows, size.cols) == 0 else {
            throw PTYError.setWinsizeFailed(errno: errno)
        }
    }

    /// Close the master, cancel the read source, and signal SIGTERM to the
    /// child group. Idempotent.
    public func close() {
        guard !isClosed else { return }
        isClosed = true

        readSource?.cancel()
        readSource = nil

        if masterFD >= 0 {
            Darwin.close(masterFD)
            masterFD = -1
        }

        if childPID > 0 {
            _ = cpx_killpg(childPID, SIGTERM)
        }

        outboundContinuation?.finish()
        outboundContinuation = nil

        log.notice("PTY closed pid=\(self.childPID, privacy: .public)")
    }

    // MARK: - Internal loops

    private func startReadLoop() {
        guard !isClosed, masterFD >= 0 else { return }
        let fd = masterFD
        let queue = DispatchQueue(label: AppIdentity.ptyReadQueueLabel, qos: .userInitiated)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)

        source.setEventHandler { [weak self] in
            // 8KB buffer per read — measured sweet spot for PTYs on macOS.
            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                Darwin.read(fd, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                let chunk = Data(buffer.prefix(n))
                Task { [weak self] in await self?.deliver(chunk) }
            } else if n == 0 || (n == -1 && errno != EAGAIN && errno != EINTR) {
                Task { [weak self] in await self?.close() }
            }
        }

        source.setCancelHandler { /* fd closed by `close()` */ }
        source.resume()
        readSource = source
    }

    private func deliver(_ chunk: Data) {
        outboundContinuation?.yield(chunk)
    }

    private func reapChild() async {
        // waitpid is blocking; offload it.
        let pid = childPID
        let status: ExitStatus = await withCheckedContinuation { c in
            DispatchQueue.global(qos: .utility).async {
                var raw: Int32 = 0
                let r = waitpid(pid, &raw, 0)
                if r < 0 {
                    c.resume(returning: .exited(code: -1))
                    return
                }
                if (raw & 0x7f) == 0 {
                    c.resume(returning: .exited(code: (raw >> 8) & 0xff))
                } else {
                    c.resume(returning: .signaled(signal: raw & 0x7f))
                }
            }
        }
        log.notice("child pid=\(pid, privacy: .public) exited status=\(String(describing: status), privacy: .public)")
        exitContinuation?.resume(returning: status)
        exitContinuation = nil
        close()
    }
}

func writeAllToPTY(_ data: Data,
                            sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                            writeChunk: @Sendable (Data) -> (written: Int, errno: Int32)) async throws {
    var remaining = data
    while !remaining.isEmpty {
        let result = writeChunk(remaining)
        if result.written > 0 {
            remaining.removeFirst(result.written)
            continue
        }
        if result.written == -1 && result.errno == EINTR { continue }
        if result.written == -1 && result.errno == EAGAIN {
            try await sleep(.milliseconds(2))
            continue
        }
        throw PTYError.writeFailed(errno: result.errno)
    }
}
