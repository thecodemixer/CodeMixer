import Foundation
import Testing
@testable import AgentCore

/// Wrapper boundary: `Foundation.Process`. Covers the happy paths
/// (`/bin/echo`, `/bin/false`, missing executable, cwd). Failure branches
/// inside `Process.run()` are out of scope per the wrapper-strategy contract.
@Suite("ProcessRunner")
struct ProcessRunnerTests {

    @Test("Captures stdout from /bin/echo")
    func capturesStdout() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(executable: URL(fileURLWithPath: "/bin/echo"),
                                          arguments: ["hello"])
        #expect(result.exitCode == 0)
        #expect(String(data: result.stdout, encoding: .utf8) == "hello\n")
        #expect(result.stderr.isEmpty)
    }

    @Test("Non-zero exit throws nonZeroExit")
    func nonZeroExit() async throws {
        let runner = ProcessRunner()
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                     arguments: ["-c", "exit 7"])
            Issue.record("expected throw")
        } catch let ProcessRunner.ProcessError.nonZeroExit(code, _) {
            #expect(code == 7)
        }
    }

    @Test("Missing executable throws executableNotFound")
    func executableNotFound() async throws {
        let runner = ProcessRunner()
        do {
            _ = try await runner.run(executable: URL(fileURLWithPath: "/no/such/path"),
                                     arguments: [])
            Issue.record("expected throw")
        } catch let ProcessRunner.ProcessError.executableNotFound(path) {
            #expect(path == "/no/such/path")
        }
    }

    @Test("Honours cwd via /usr/bin/pwd")
    func honoursCwd() async throws {
        let runner = ProcessRunner()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let result = try await runner.run(executable: URL(fileURLWithPath: "/bin/pwd"),
                                          arguments: [],
                                          cwd: tmp)
        let resolved = tmp.resolvingSymlinksInPath().path
        let stdout = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // /tmp resolves to /private/tmp on macOS — accept either.
        #expect(stdout == resolved || stdout == tmp.path || stdout.hasSuffix(tmp.lastPathComponent))
    }

    @Test("Honours env")
    func honoursEnv() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                          arguments: ["-c", "printf %s \"$CODEMIXER_TEST\""],
                                          env: ["CODEMIXER_TEST": "abc"])
        #expect(String(data: result.stdout, encoding: .utf8) == "abc")
    }

    @Test("Drains stdout and stderr concurrently")
    func drainsStdoutAndStderrConcurrently() async throws {
        let runner = ProcessRunner()
        let script = """
        i=0
        while [ $i -lt 2000 ]; do
          printf 'stderr-line-%04d........................................................\\n' "$i" >&2
          i=$((i + 1))
        done
        printf done
        """
        let result = try await runner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                          arguments: ["-c", script])
        #expect(String(data: result.stdout, encoding: .utf8) == "done")
        #expect(result.stderr.count > 128_000)
    }

    @Test("Cancellation terminates a long-running child promptly")
    func cancellationTerminatesChildPromptly() async throws {
        let runner = ProcessRunner()
        let started = ContinuousClock.now
        let task = Task {
            try await runner.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                 arguments: ["30"])
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation to terminate the child and throw")
        } catch {
            let elapsed = started.duration(to: ContinuousClock.now)
            #expect(elapsed < .seconds(3))
        }
    }

    @Test("Result is Sendable + Equatable")
    func resultEquality() {
        let a = ProcessRunner.Result(stdout: Data("x".utf8), stderr: Data(), exitCode: 0)
        let b = ProcessRunner.Result(stdout: Data("x".utf8), stderr: Data(), exitCode: 0)
        #expect(a == b)
    }
}
