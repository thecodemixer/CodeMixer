import Foundation

/// Single boundary between Codemixer business code and `Foundation.Process`.
///
/// Why a wrapper: a grep for `Foundation.Process` in the codebase must return
/// exactly this file. Every short-lived subprocess (openssl, git, the user's
/// login shell for env capture) flows through `run(executable:arguments:cwd:env:)`.
///
/// Lifetime is one-shot per call. The actor only exists to give callers a
/// `Sendable` handle; no shared mutable state lives inside.
public actor ProcessRunner {

    /// Captured outcome of a successful spawn — exit status may still be non-zero.
    public struct Result: Sendable, Equatable {
        public let stdout: Data
        public let stderr: Data
        public let exitCode: Int32
    }

    /// Typed failure surface. Callers receive `nonZeroExit` for the common
    /// case where the binary ran but signalled an error; `spawnFailed` and
    /// `executableNotFound` cover the rarer pre-flight failures.
    public enum ProcessError: Error, Sendable, Equatable {
        case executableNotFound(path: String)
        case spawnFailed(detail: String)
        case nonZeroExit(code: Int32, stderr: String)
    }

    public init() {}

    /// Run `executable` with `arguments`, optionally inside `cwd`, with `env`
    /// (nil means inherit). Captures stdout + stderr and waits for the child
    /// to exit. Honours task cancellation by terminating the child.
    ///
    /// `allowedExitCodes` defaults to `[0]`. Add `1` for commands like
    /// `git diff --no-index` whose convention is exit-1-means-differences-found.
    public func run(executable: URL,
                    arguments: [String],
                    cwd: URL? = nil,
                    env: [String: String]? = nil,
                    stdin: Data? = nil,
                    allowedExitCodes: Set<Int32> = [0]) async throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ProcessError.executableNotFound(path: executable.path)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        if let env { process.environment = env }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inputPipe = stdin.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        let termination = ProcessTermination()
        process.terminationHandler = { process in
            termination.complete(status: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw ProcessError.spawnFailed(detail: error.localizedDescription)
        }

        if let stdin, let inputPipe {
            inputPipe.fileHandleForWriting.write(stdin)
            try? inputPipe.fileHandleForWriting.close()
        }

        let pidBox = PIDBox(process: process)
        return try await withTaskCancellationHandler {
            let stdoutTask = Task.detached(priority: .userInitiated) {
                outPipe.fileHandleForReading.readDataToEndOfFile()
            }
            let stderrTask = Task.detached(priority: .userInitiated) {
                errPipe.fileHandleForReading.readDataToEndOfFile()
            }
            return try await Task.detached(priority: .userInitiated) {
                let code = await termination.wait()
                let stdout = await stdoutTask.value
                let stderr = await stderrTask.value
                if !allowedExitCodes.contains(code) {
                    let message = String(data: stderr, encoding: .utf8) ?? ""
                    throw ProcessError.nonZeroExit(code: code, stderr: message)
                }
                return Result(stdout: stdout, stderr: stderr, exitCode: code)
            }.value
        } onCancel: {
            pidBox.terminate()
        }
    }
}

/// Tiny box so the cancellation handler can reach the `Process` from the
/// outside without capturing the actor.
private final class PIDBox: @unchecked Sendable {
    private let process: Process
    init(process: Process) { self.process = process }
    func terminate() { if process.isRunning { process.terminate() } }
}

/// Bridges `Process.terminationHandler` into async code without relying on
/// `waitUntilExit`, which can wedge under piped SwiftPM test output.
private final class ProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func complete(status: Int32) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: status)
        } else {
            self.status = status
            lock.unlock()
        }
    }
}
