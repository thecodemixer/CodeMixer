import Foundation
import OSLog

/// Capture the user's interactive-shell environment by running
/// `<shell> -ilc 'env -0'` exactly once and parsing the NUL-separated output.
///
/// We use NUL framing because values can legitimately contain newlines (e.g.
/// `PROMPT='\n$ '`). The shell is the one named in `$SHELL`, falling back to
/// `/bin/zsh`.
public struct ShellEnvironmentResolver: Sendable {

    public enum ResolverError: Error, Sendable, Equatable {
        case shellExited(code: Int32, message: String)
        case timedOut
        case spawnFailed(String)
    }

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "EnvResolver")
    private let environment: any AgentEnvironment
    private let processRunner: ProcessRunner

    public init(environment: any AgentEnvironment,
                processRunner: ProcessRunner = ProcessRunner()) {
        self.environment = environment
        self.processRunner = processRunner
    }

    /// Resolve and return the user's interactive-shell env.
    ///
    /// Times out after `timeout` and returns the inherited process env as a
    /// best-effort fallback (logged at warning level).
    public func resolve(timeout: Duration = .seconds(3)) async -> ResolvedEnvironment {
        let shellPath = environment.processEnvironment()["SHELL"] ?? "/bin/zsh"
        let shell = URL(fileURLWithPath: shellPath)

        do {
            let vars = try await runShellAndCapture(shell: shell, timeout: timeout)
            return ResolvedEnvironment(variables: vars, shell: shell)
        } catch {
            log.warning("env resolver failed: \(String(describing: error), privacy: .public). Falling back to process env.")
            return ResolvedEnvironment(variables: environment.processEnvironment(),
                                       shell: shell)
        }
    }

    // MARK: - Private

    private func runShellAndCapture(shell: URL, timeout: Duration) async throws -> [String: String] {
        // Race the spawn against the timeout. The runner honours task
        // cancellation by terminating the underlying process, so timing out
        // also cleans up the child shell.
        let collected: Data
        do {
            collected = try await withThrowingTaskGroup(of: Data.self) { group in
                let runner = self.processRunner
                group.addTask {
                    do {
                        let result = try await runner.run(executable: shell,
                                                          arguments: ["-ilc", "env -0"])
                        return result.stdout
                    } catch let ProcessRunner.ProcessError.nonZeroExit(code, message) {
                        throw ResolverError.shellExited(code: code, message: message)
                    } catch let ProcessRunner.ProcessError.spawnFailed(detail) {
                        throw ResolverError.spawnFailed(detail)
                    } catch let ProcessRunner.ProcessError.executableNotFound(path) {
                        throw ResolverError.spawnFailed("not executable: \(path)")
                    }
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw ResolverError.timedOut
                }
                guard let data = try await group.next() else {
                    throw ResolverError.timedOut
                }
                group.cancelAll()
                return data
            }
        }
        return parseNULSeparatedEnv(collected)
    }

    /// Parse `env -0` output: zero-terminated `KEY=value` records.
    func parseNULSeparatedEnv(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for record in text.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let eq = record.firstIndex(of: "=") else { continue }
            let key = String(record[record.startIndex..<eq])
            let value = String(record[record.index(after: eq)..<record.endIndex])
            result[key] = value
        }
        return result
    }
}
