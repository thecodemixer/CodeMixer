import Foundation

struct GitReverter: Sendable {
    private let processRunner: ProcessRunner

    init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    func checkout(path: String, workspace: URL?) async throws {
        try await runGit(["checkout", "--", path], workspace: workspace)
    }

    func revertHunk(path: String, hunkID: UUID, workspace: URL?) async throws {
        guard let workspace else {
            throw AgentError.workspaceInvalid(path: path, detail: "No workspace is open.")
        }
        let diff = try await GitDiffEngine(workspace: workspace).diff(for: path)
        guard let hunk = diff.hunks.first(where: { $0.id == hunkID }) else {
            throw AgentError.hunkRevertFailed(path: path,
                                              hunkID: hunkID,
                                              detail: "No matching hunk in the current diff.")
        }
        try await applyReversePatch(buildPatch(path: path, hunk: hunk),
                                    path: path,
                                    hunkID: hunkID,
                                    workspace: workspace)
    }

    private func runGit(_ args: [String], workspace: URL?) async throws {
        guard let workspace else {
            throw AgentError.workspaceInvalid(path: "", detail: "No workspace is open.")
        }
        do {
            _ = try await processRunner.run(executable: SystemPaths.env,
                                            arguments: ["git"] + args,
                                            cwd: workspace)
        } catch let ProcessRunner.ProcessError.nonZeroExit(_, stderr) {
            let path = args.last ?? ""
            throw AgentError.gitCheckoutFailed(path: path, detail: stderr)
        } catch {
            let path = args.last ?? ""
            throw AgentError.gitCheckoutFailed(path: path, detail: String(describing: error))
        }
    }

    private func applyReversePatch(_ patch: Data,
                                   path: String,
                                   hunkID: UUID,
                                   workspace: URL) async throws {
        do {
            _ = try await processRunner.run(executable: SystemPaths.env,
                                            arguments: ["git", "apply", "--reverse", "--unidiff-zero", "-"],
                                            cwd: workspace,
                                            stdin: patch)
        } catch let ProcessRunner.ProcessError.nonZeroExit(_, stderr) {
            throw AgentError.hunkRevertFailed(path: path, hunkID: hunkID, detail: stderr)
        } catch {
            throw AgentError.hunkRevertFailed(path: path, hunkID: hunkID, detail: String(describing: error))
        }
    }
}

/// Build a single-hunk unified diff suitable for `git apply --reverse`.
///
/// Package-visible by default so tests can validate the exact patch contract.
func buildPatch(path: String, hunk: DiffHunk) -> Data {
    var lines = [
        "diff --git a/\(path) b/\(path)",
        "--- a/\(path)",
        "+++ b/\(path)",
        hunk.header
    ]
    for line in hunk.lines {
        let prefix = switch line.kind {
        case .context: " "
        case .addition: "+"
        case .deletion: "-"
        }
        lines.append(prefix + line.text)
    }
    lines.append("")
    return Data(lines.joined(separator: "\n").utf8)
}
