import Foundation
import AgentCore

/// Minimal `Process` wrapper for hook command execution in `fake-claude`.
struct TwinProcessRunner: Sendable {
    struct Result: Sendable {
        var stdout: Data
        var stderr: Data
        var exitCode: Int32
    }

    func run(shellCommand: String, stdin: Data, cwd: URL) throws -> Result {
        let process = Process()
        process.executableURL = SystemPaths.sh
        process.arguments = ["-c", shellCommand]
        process.currentDirectoryURL = cwd

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        try process.run()
        try stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
        try stdinPipe.fileHandleForWriting.close()

        process.waitUntilExit()
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return Result(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }
}
