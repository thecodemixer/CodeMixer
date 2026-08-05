#!/usr/bin/env swift
/// swift-test.swift
///
/// Runs the Codemixer SPM suite with the required `--no-parallel` flag, after
/// clearing opt-in live harness environment gates that would otherwise turn a
/// "default" test run into a multi-minute (or tens-of-minutes) live agent
/// pipeline when those vars linger in the shell from a prior live session.
///
/// Usage (from repository root):
///   scripts/swift-test.swift
///   scripts/swift-test.swift --filter A2UIActionResolverTests
///   scripts/swift-test.swift --allow-live --filter LiveCustomACPIntegrationTests
///
/// Extra arguments after optional flags are forwarded to `swift test`.
/// `--no-parallel` is always injected when missing.

import Foundation

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()

let green = "\u{001B}[0;32m"
let yellow = "\u{001B}[0;33m"
let red = "\u{001B}[0;31m"
let reset = "\u{001B}[0m"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(red)✗ \(message)\(reset)\n".utf8))
    exit(1)
}

func which(_ tool: String) -> URL? {
    let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    for prefix in candidates {
        let url = URL(fileURLWithPath: prefix).appendingPathComponent(tool)
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    return nil
}

/// Opt-in gates that activate live / networked harnesses inside the default
/// `swift test` discovery. Clearing them keeps the unit/integration suite
/// deterministic and fast. Path/workspace companion vars are cleared too so a
/// half-set live config cannot partially arm a suite.
let liveGateVariables: [String] = [
    "CODEMIXER_LIVE_CLAUDE",
    "CODEMIXER_LIVE_CLAUDE_RESUME_DIAG",
    "CODEMIXER_LIVE_CODEX",
    "CODEMIXER_LIVE_ACP",
    "CODEMIXER_LIVE_ACP_BIN",
    "CODEMIXER_LIVE_ACP_ARGS",
    "CODEMIXER_CUSTOM_ACP_BIN",
    "CODEMIXER_LIVE_CUSTOM_ACP",
    "CODEMIXER_LIVE_MIGRATION_PIPELINE",
    "CODEMIXER_LIVE_CURSOR_ACP",
    "CODEMIXER_LIVE_CURSOR_BIN",
    "CODEMIXER_LIVE_GUI_PATH",
    "CODEMIXER_LIVE_RUNTIME_POOL",
    "CODEMIXER_LIVE_WORKSPACE",
    "CODEMIXER_LIVE_CLAUDE_PROJECT",
    "CODEMIXER_LIVE_CLAUDE_PROJECT_A",
    "CODEMIXER_LIVE_CLAUDE_PROJECT_B",
    "CODEMIXER_LIVE_CODEX_PROJECT",
    "CODEMIXER_LIVE_CURSOR_PROJECT",
    "MIGRATION_LIVE",
    "CODEMIXER_LIVE_MIGRATION",
    "MIGRATION_LIVE_PIPELINE",
]

var allowLive = false
var forwarded: [String] = []
var args = Array(CommandLine.arguments.dropFirst())
while let head = args.first {
    args.removeFirst()
    switch head {
    case "--allow-live":
        allowLive = true
    case "--help", "-h":
        print(
            """
            Usage: scripts/swift-test.swift [--allow-live] [--] [swift test args...]

              Runs `swift test --no-parallel` from the repository root.

              By default, strips CODEMIXER_LIVE_* / MIGRATION_LIVE* environment
              gates so a leftover live-session export cannot arm multi-minute
              harnesses during a normal unit/integration run.

              --allow-live   Keep live gates from the current environment.
              Extra args     Forwarded to `swift test` (e.g. --filter SuiteName).
            """
        )
        exit(0)
    case "--":
        forwarded.append(contentsOf: args)
        args.removeAll()
    default:
        forwarded.append(head)
        forwarded.append(contentsOf: args)
        args.removeAll()
    }
}

guard let swift = which("swift") else { fail("swift not found on PATH") }

var env = ProcessInfo.processInfo.environment
var cleared: [String] = []
if !allowLive {
    for key in liveGateVariables {
        if env.removeValue(forKey: key) != nil {
            cleared.append(key)
        }
    }
}

if !forwarded.contains("--no-parallel") {
    forwarded.insert("--no-parallel", at: 0)
}

// Announce on stderr so the banner is not reordered behind child stdout when
// the script's stdout is fully buffered (non-TTY / piped runs).
func announce(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

if allowLive {
    announce("\(yellow)▶ swift test \(forwarded.joined(separator: " ")) (live gates kept)\(reset)")
} else if cleared.isEmpty {
    announce("\(green)▶ swift test \(forwarded.joined(separator: " "))\(reset)")
} else {
    announce("\(green)▶ swift test \(forwarded.joined(separator: " "))\(reset)")
    announce("\(yellow)  cleared live gates: \(cleared.sorted().joined(separator: ", "))\(reset)")
}

let process = Process()
process.executableURL = swift
process.arguments = ["test"] + forwarded
process.currentDirectoryURL = repoRoot
process.environment = env

do {
    try process.run()
} catch {
    fail("failed to spawn swift test: \(error)")
}
process.waitUntilExit()
exit(process.terminationStatus)
