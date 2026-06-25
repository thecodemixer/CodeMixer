import Foundation
import OSLog

/// Runs `git` against a workspace and parses unified diffs into structured
/// `FileDiff` values.
///
/// We shell out to `SystemPaths.git` directly (not via the user's shell) because
/// the workspace is already known and we want predictable behaviour. Each
/// invocation is async; the engine is an `actor` so concurrent calls are
/// serialised — git already serialises locks, and overlapping runs would just
/// duplicate work.
public actor GitDiffEngine {

    public enum DiffError: Error, Sendable {
        case notARepository(path: String)
        case gitFailed(code: Int32, message: String)
    }

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Diff")
    private let workspace: URL
    private let gitURL: URL
    private let processRunner: ProcessRunner

    public init(workspace: URL,
                gitURL: URL = SystemPaths.git,
                processRunner: ProcessRunner = ProcessRunner()) {
        self.workspace = workspace
        self.gitURL = gitURL
        self.processRunner = processRunner
    }

    /// Names of files that have any change vs `HEAD` (`git status --porcelain`).
    public func changedFiles() async throws -> [String] {
        let output = try await runGit(["status", "--porcelain"])
        return parsePorcelain(output)
    }

    /// Unified diff for one file vs `HEAD`.
    ///
    /// `git diff HEAD` produces no output for new/untracked files — they have no
    /// history entry. When the result is empty we fall back to
    /// `git diff --no-index /dev/null <file>` which surfaces the full addition.
    /// git exits 1 when differences exist (the normal case); we treat 0 and 1
    /// as success via `allowedExitCodes`.
    public func diff(for relativePath: String, context: Int = 3) async throws -> FileDiff {
        let gitPath = pathRelativeToWorkspaceIfPossible(relativePath)
        let raw = relativePath.hasPrefix("/")
            ? ((try? await runGit(["diff", "--no-color", "--unified=\(context)", "HEAD", "--", gitPath])) ?? "")
            : try await runGit(["diff", "--no-color", "--unified=\(context)", "HEAD", "--", gitPath])
        let fileDiff = parseUnifiedDiff(raw, relativePath: relativePath)
        guard fileDiff.hunks.isEmpty else { return fileDiff }

        let absolutePath = absolutePath(for: relativePath)
        let fallbackRaw = await runGitNoIndex(absolutePath: absolutePath, context: context)
        let fallback = parseUnifiedDiff(fallbackRaw, relativePath: relativePath)
        return fallback.hunks.isEmpty ? fileDiff : fallback
    }

    // MARK: - Private

    private func absolutePath(for path: String) -> String {
        path.hasPrefix("/") ? path : workspace.appendingPathComponent(path).path
    }

    private func pathRelativeToWorkspaceIfPossible(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let workspacePaths = [workspace, workspace.resolvingSymlinksInPath()]
            .map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        let fileURL = URL(fileURLWithPath: path)
        let paths = [fileURL.path, fileURL.resolvingSymlinksInPath().path]
        for root in workspacePaths {
            for candidate in paths where candidate.hasPrefix(root) {
                return String(candidate.dropFirst(root.count))
            }
        }
        return path
    }

    /// Diff a file that has no HEAD entry (new/untracked).
    ///
    /// `git diff --no-index /dev/null <file>` exits 1 when the file has content,
    /// so we pass `allowedExitCodes: [0, 1]`. Any other error (e.g. file gone)
    /// returns an empty string so the caller shows "File matches HEAD."
    private func runGitNoIndex(absolutePath: String, context: Int) async -> String {
        let result = try? await processRunner.run(
            executable: gitURL,
            arguments: ["diff", "--no-color", "--unified=\(context)", "--no-index",
                        "/dev/null", absolutePath],
            cwd: workspace,
            allowedExitCodes: [0, 1])
        return result.flatMap { String(data: $0.stdout, encoding: .utf8) } ?? ""
    }

    private func runGit(_ arguments: [String]) async throws -> String {
        do {
            let result = try await processRunner.run(executable: gitURL,
                                                     arguments: arguments,
                                                     cwd: workspace)
            return String(data: result.stdout, encoding: .utf8) ?? ""
        } catch let ProcessRunner.ProcessError.nonZeroExit(code, message) {
            if message.contains("not a git repository") {
                throw DiffError.notARepository(path: workspace.path)
            }
            throw DiffError.gitFailed(code: code, message: message)
        } catch ProcessRunner.ProcessError.executableNotFound(let path) {
            throw DiffError.gitFailed(code: -1, message: "git not found at \(path)")
        } catch let ProcessRunner.ProcessError.spawnFailed(detail) {
            throw DiffError.gitFailed(code: -1, message: detail)
        }
    }

    /// Parse a single-file unified diff.
    ///
    /// Visible-for-testing — the parsing rules are subtle enough that we keep
    /// this package-visible so the test target can call it on canned inputs.
    nonisolated func parseUnifiedDiff(_ raw: String, relativePath: String) -> FileDiff {
        var hunks: [DiffHunk] = []
        var currentHunkLines: [DiffLine] = []
        var currentHeader: String?
        var currentOldRange: ClosedRange<Int> = 0...0
        var currentNewRange: ClosedRange<Int> = 0...0
        var oldCursor = 0
        var newCursor = 0

        func flushHunk() {
            guard let header = currentHeader else { return }
            hunks.append(DiffHunk(header: header,
                                  oldRange: currentOldRange,
                                  newRange: currentNewRange,
                                  lines: currentHunkLines))
            currentHunkLines = []
            currentHeader = nil
        }

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("diff ") || line.hasPrefix("index ") ||
               line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                continue
            }
            if line.hasPrefix("@@") {
                flushHunk()
                let (oldR, newR) = parseHunkHeader(line)
                currentHeader = line
                currentOldRange = oldR
                currentNewRange = newR
                oldCursor = oldR.lowerBound
                newCursor = newR.lowerBound
                continue
            }
            if currentHeader == nil { continue }
            // Unified diff emits this sentinel after +/- lines for files lacking a
            // trailing newline. It is metadata, not a source line, so it must not
            // consume old/new cursors or appear in the rendered hunk.
            if line.hasPrefix("\\ No newline at end of file") { continue }

            if line.hasPrefix("+") {
                currentHunkLines.append(DiffLine(text: String(line.dropFirst()),
                                                 kind: .addition,
                                                 oldLineNumber: nil,
                                                 newLineNumber: newCursor))
                newCursor += 1
            } else if line.hasPrefix("-") {
                currentHunkLines.append(DiffLine(text: String(line.dropFirst()),
                                                 kind: .deletion,
                                                 oldLineNumber: oldCursor,
                                                 newLineNumber: nil))
                oldCursor += 1
            } else {
                let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
                currentHunkLines.append(DiffLine(text: text,
                                                 kind: .context,
                                                 oldLineNumber: oldCursor,
                                                 newLineNumber: newCursor))
                oldCursor += 1
                newCursor += 1
            }
        }
        flushHunk()
        return FileDiff(relativePath: relativePath, hunks: hunks)
    }

    /// Parse `git status --porcelain` output into user-facing changed paths.
    ///
    /// Visible-for-testing because porcelain output has a few non-obvious cases:
    /// status occupies two columns, renames use `old -> new`, and paths with
    /// spaces may be quoted by git.
    nonisolated func parsePorcelain(_ output: String) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawLine -> String? in
                let line = String(rawLine)
                guard line.count > 3 else { return nil }
                let status = String(line.prefix(2))
                let pathStart = line.index(line.startIndex, offsetBy: 3)
                var path = String(line[pathStart...])
                if status.contains("R") || status.contains("C") {
                    path = path.components(separatedBy: " -> ").last ?? path
                }
                return normalizePorcelainPath(path)
            }
    }

    /// `@@ -12,7 +15,8 @@ ...` -> ((12...18), (15...22)).
    private nonisolated func parseHunkHeader(_ header: String) -> (ClosedRange<Int>, ClosedRange<Int>) {
        let parts = header.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return (0...0, 0...0) }
        let oldPart = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let newPart = String(parts[2]).trimmingCharacters(in: CharacterSet(charactersIn: "+"))
        let old = parseRange(oldPart)
        let new = parseRange(newPart)
        return (old, new)
    }

    private nonisolated func parseRange(_ token: String) -> ClosedRange<Int> {
        let parts = token.split(separator: ",")
        let start = Int(parts.first ?? "0") ?? 0
        let length = parts.count > 1 ? (Int(parts[1]) ?? 0) : 1
        let end = max(start, start + max(length - 1, 0))
        return start...end
    }

    private nonisolated func normalizePorcelainPath(_ path: String) -> String {
        var out = path
        if out.hasPrefix("\""), out.hasSuffix("\""), out.count >= 2 {
            out.removeFirst()
            out.removeLast()
            out = out
                .replacingOccurrences(of: #"\""#, with: #"""#)
                .replacingOccurrences(of: #"\\ "#, with: " ")
        }
        return out
    }
}
