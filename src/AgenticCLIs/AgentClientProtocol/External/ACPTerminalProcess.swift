import Foundation

/// Long-lived process handle for one ACP reverse-terminal session.
///
/// The only `Process()` site for ACP terminal reverse RPCs.
public actor ACPTerminalProcess {
    public struct Snapshot: Sendable {
        public let output: String
        public let exitCode: Int32?
        public let truncated: Bool
    }

    private var process: Process?
    private var output = ""
    private var truncated = false
    private let outputByteLimit: Int
    private var exitCode: Int32?
    private var waiters: [CheckedContinuation<Int32?, Never>] = []

    public init(outputByteLimit: Int = 1_000_000) {
        self.outputByteLimit = outputByteLimit
    }

    public func start(executable: URL,
                      arguments: [String],
                      cwd: URL?,
                      environment: [String: String]?) throws {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        proc.currentDirectoryURL = cwd
        if let environment {
            proc.environment = environment
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] process in
            Task { await self?.didExit(code: process.terminationStatus) }
        }
        try proc.run()
        process = proc
        attach(pipe: outPipe)
        attach(pipe: errPipe)
    }

    public func snapshot() -> Snapshot {
        Snapshot(output: output, exitCode: exitCode, truncated: truncated)
    }

    public func waitForExit() async -> Int32? {
        if let exitCode { return exitCode }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func kill() {
        process?.terminate()
    }

    public func release() {
        kill()
        process = nil
    }

    private func attach(pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { await self?.append(chunk) }
        }
    }

    private func append(_ chunk: String) {
        if output.utf8.count >= outputByteLimit {
            truncated = true
            return
        }
        let remaining = outputByteLimit - output.utf8.count
        if chunk.utf8.count > remaining {
            let prefix = String(decoding: Data(chunk.utf8.prefix(remaining)), as: UTF8.self)
            output += prefix
            truncated = true
        } else {
            output += chunk
        }
    }

    private func didExit(code: Int32) {
        exitCode = code
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: code)
        }
    }
}
