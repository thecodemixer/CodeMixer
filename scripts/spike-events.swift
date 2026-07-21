#!/usr/bin/env swift
// spike-events.swift — hook-event validation tool
//
// Captures Claude Code hook events for a fixed window and summarizes event
// coverage for the required lifecycle hooks.

import Foundation
import Dispatch

// MARK: - Shared hook helpers (keep in sync with spike-billing.swift)

enum SpikeHookSupport {

    static func quotedShell(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func extractJSONObjects(from stream: String) -> [String] {
        var objects: [String] = []
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaped = false

        for index in stream.indices {
            let ch = stream[index]
            if start == nil {
                if ch == "{" {
                    start = index
                    depth = 1
                    inString = false
                    escaped = false
                }
                continue
            }

            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }

            if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0, let objectStart = start {
                    objects.append(String(stream[objectStart...index]))
                    start = nil
                }
            }
        }

        return objects
    }

    static func canonicalHookName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "pretooluse": return "PreToolUse"
        case "posttooluse": return "PostToolUse"
        case "notification": return "Notification"
        case "stop": return "Stop"
        default: return raw
        }
    }

    static func writeSocatHookSettings(file: URL, socketPath: String) throws {
        let hookCommand = "socat - UNIX-CONNECT:\(socketPath)"
        let json = """
        {
          "hooks": {
            "PreToolUse":    [{"matcher": "*", "hooks": [{"type": "command", "command": "\(hookCommand)"}]}],
            "PostToolUse":   [{"matcher": "*", "hooks": [{"type": "command", "command": "\(hookCommand)"}]}],
            "Notification":  [{"matcher": "*", "hooks": [{"type": "command", "command": "\(hookCommand)"}]}],
            "Stop":          [{"matcher": "*", "hooks": [{"type": "command", "command": "\(hookCommand)"}]}]
          }
        }
        """
        try json.data(using: .utf8)?.write(to: file)
    }

    static func hookClientCommand(socketPath: String) -> String {
        let script = """
        import socket, sys
        path = sys.argv[1]
        payload = sys.stdin.buffer.read()
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(path)
        sock.sendall(payload)
        sock.shutdown(socket.SHUT_WR)
        sys.stdout.buffer.write(sock.recv(65536))
        """
        return "\(ScriptPaths.python3) -c \(quotedShell(script)) \(quotedShell(socketPath))"
    }

    static func writePythonHookSettings(file: URL, socketPath: String, hookNames: [String]) throws {
        let command = hookClientCommand(socketPath: socketPath)
        let hookEntry: [String: Any] = [
            "matcher": "*",
            "hooks": [
                [
                    "type": "command",
                    "command": command,
                ],
            ],
        ]
        var hooks: [String: Any] = [:]
        for name in hookNames {
            hooks[name] = [hookEntry]
        }
        let root: [String: Any] = ["hooks": hooks]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file)
    }
}

enum ScriptPaths {
    static let env = "/usr/bin/env"
    static let tmp = FileManager.default.temporaryDirectory

    static var python3: String {
        if let override = ProcessInfo.processInfo.environment["PYTHON3_BIN"], !override.isEmpty {
            return override
        }
        let candidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }
}

struct Config {
    let workspace: URL
    let durationSeconds: Int
    let selfTest: Bool

    init(arguments: [String]) throws {
        var workspacePath: String?
        var duration = 1800
        var selfTest = false

        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--self-test" {
                selfTest = true
                index += 1
                continue
            }
            if arg == "--duration-secs" {
                guard index + 1 < arguments.count,
                      let value = Int(arguments[index + 1]),
                      value > 0 else {
                    throw NSError(domain: "spike-events", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Invalid --duration-secs value"])
                }
                duration = value
                index += 2
                continue
            }
            if workspacePath == nil {
                workspacePath = arg
                index += 1
                continue
            }
            throw NSError(domain: "spike-events", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected argument: \(arg)"])
        }

        let base = workspacePath ?? FileManager.default.currentDirectoryPath
        self.workspace = URL(fileURLWithPath: base, isDirectory: true)
        self.durationSeconds = duration
        self.selfTest = selfTest
    }
}

@discardableResult
func runProcess(executable: String, arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    return process
}

func commandExists(_ name: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ScriptPaths.env)
    process.arguments = ["which", name]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func writeHookSettings(file: URL, socketPath: String) throws {
    try SpikeHookSupport.writeSocatHookSettings(file: file, socketPath: socketPath)
}

func canonicalHookName(_ raw: String) -> String {
    SpikeHookSupport.canonicalHookName(raw)
}

func extractJSONObjects(from stream: String) -> [String] {
    SpikeHookSupport.extractJSONObjects(from: stream)
}

func parseEventCounts(from stream: String) -> [String: Int] {
    var counts: [String: Int] = [:]
    for jsonObject in extractJSONObjects(from: stream) {
        guard let lineData = jsonObject.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            continue
        }
        if json.isEmpty { continue }
        let raw = (json["event"] as? String) ??
            (json["type"] as? String) ??
            (json["hook_event_name"] as? String) ??
            "unknown"
        let event = canonicalHookName(raw)
        counts[event, default: 0] += 1
    }
    return counts
}

func printSummary(for counts: [String: Int]) {
    let total = counts.values.reduce(0, +)
    print("  Total events: \(total)")
    print("")
    print("  By type:")
    for (event, count) in counts.sorted(by: { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.key < rhs.key
    }) {
        print("    \(count) \(event)")
    }

    print("")
    let required = ["PreToolUse", "PostToolUse", "Stop", "Notification"]
    var allPassed = true
    for event in required {
        if counts[event, default: 0] > 0 {
            print("  [PASS] \(event) fired")
        } else {
            print("  [MISS] \(event) never fired — extend the session or verify hook config")
            allPassed = false
        }
    }
    print("")
    if allPassed {
        print("spike-events: PASS — all required event types captured.")
    } else {
        print("spike-events: PARTIAL — some events missing.")
    }
}

func summarize(captureFile: URL) {
    print("")
    print("=== spike-events: SUMMARY ===")
    guard let data = try? Data(contentsOf: captureFile),
          let text = String(data: data, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        print("  No events captured.")
        return
    }

    let counts = parseEventCounts(from: text)
    printSummary(for: counts)
}

func runSelfTests() -> Bool {
    struct Scenario {
        let name: String
        let input: String
        let expected: [String: Int]
    }

    let scenarios: [Scenario] = [
        Scenario(
            name: "newline-delimited hook_event_name payloads",
            input: """
            {"hook_event_name":"PreToolUse"}
            {"hook_event_name":"PostToolUse"}
            {"hook_event_name":"Stop"}
            """,
            expected: ["PreToolUse": 1, "PostToolUse": 1, "Stop": 1]
        ),
        Scenario(
            name: "concatenated objects without newlines",
            input: #"{"event":"PreToolUse"}{"event":"Notification"}{"event":"Stop"}"#,
            expected: ["PreToolUse": 1, "Notification": 1, "Stop": 1]
        ),
        Scenario(
            name: "mixed key shapes and casing",
            input: """
            {"type":"pretooluse"}
            {"event":"posttooluse"}
            {"hook_event_name":"Notification"}
            {"type":"STOP"}
            """,
            expected: ["PreToolUse": 1, "PostToolUse": 1, "Notification": 1, "Stop": 1]
        ),
        Scenario(
            name: "escaped braces inside string values",
            input: #"{"event":"PreToolUse","note":"literal { brace in string"}{"event":"Stop"}"#,
            expected: ["PreToolUse": 1, "Stop": 1]
        ),
        Scenario(
            name: "ignore malformed and empty json objects",
            input: #"{"event":"PreToolUse"}not-json{"event":"Stop"}{}"#,
            expected: ["PreToolUse": 1, "Stop": 1]
        ),
    ]

    print("spike-events: running self-tests (\(scenarios.count) scenarios)")
    var failed = 0
    for scenario in scenarios {
        let actual = parseEventCounts(from: scenario.input)
        if actual == scenario.expected {
            print("  [PASS] \(scenario.name)")
        } else {
            failed += 1
            print("  [FAIL] \(scenario.name)")
            print("    expected: \(scenario.expected)")
            print("    actual  : \(actual)")
        }
    }
    if failed == 0 {
        print("spike-events: self-tests PASS")
        return true
    }
    print("spike-events: self-tests FAIL (\(failed) scenario(s))")
    return false
}

let config: Config
do {
    config = try Config(arguments: CommandLine.arguments)
} catch {
    fputs("Usage: scripts/spike-events.swift [workspace-path] [--duration-secs N] [--self-test]\n", stderr)
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(2)
}

if config.selfTest {
    exit(runSelfTests() ? 0 : 1)
}

for dep in ["socat", "claude"] {
    if !commandExists(dep) {
        fputs("spike-events: missing dependency: \(dep)\n", stderr)
        fputs("Install with:\n  brew install socat\n  npm install -g @anthropic-ai/claude-code\n", stderr)
        exit(1)
    }
}

let ts = Int(Date().timeIntervalSince1970)
let captureFile = ScriptPaths.tmp.appendingPathComponent("codemixer-spike-events-\(ts).jsonl")
let socketPath = ScriptPaths.tmp.appendingPathComponent("codemixer-spike-hook-\(ts).sock").path
let settingsDir = config.workspace.appendingPathComponent(".claude", isDirectory: true)
let settingsFile = settingsDir.appendingPathComponent("settings.local.json")
let backupFile = settingsFile.appendingPathExtension("spike-backup")

try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
if FileManager.default.fileExists(atPath: settingsFile.path) {
    try? FileManager.default.removeItem(at: backupFile)
    try FileManager.default.copyItem(at: settingsFile, to: backupFile)
}

do {
    try writeHookSettings(file: settingsFile, socketPath: socketPath)
} catch {
    fputs("spike-events: failed writing hook settings: \(error)\n", stderr)
    exit(1)
}

print("spike-events: workspace = \(config.workspace.path)")
print("spike-events: socket    = \(socketPath)")
print("spike-events: capture   = \(captureFile.path)")
print("spike-events: duration  = \(config.durationSeconds)s (Ctrl-C to stop early)")
print("")
print("spike-events: hook config written to \(settingsFile.path)")
print("spike-events: now run Claude sessions in this workspace.")
print("")

let listener: Process
do {
    listener = try runProcess(
        executable: ScriptPaths.env,
        arguments: [
            "socat",
            "UNIX-LISTEN:\(socketPath),fork,reuseaddr",
            "SYSTEM:cat >> \"\(captureFile.path)\"; printf '{}\\n'"
        ]
    )
} catch {
    fputs("spike-events: failed to start socket listener: \(error)\n", stderr)
    exit(1)
}

var preview: Process?
if commandExists("jq") {
    do {
        preview = try runProcess(
            executable: "/bin/sh",
            arguments: [
                "-lc",
                "tail -f \"\(captureFile.path)\" 2>/dev/null | jq -r 'if .event then \"[\\(.event)]\" elif .type then \"[\\(.type)]\" else \"[?]\" end'"
            ]
        )
    } catch {
        // Preview is best-effort only.
    }
}

var interrupted = false
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigInt.setEventHandler { interrupted = true }
sigInt.resume()
let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigTerm.setEventHandler { interrupted = true }
sigTerm.resume()

let deadline = Date().addingTimeInterval(TimeInterval(config.durationSeconds))
while !interrupted && Date() < deadline {
    Thread.sleep(forTimeInterval: 1)
}

preview?.terminate()
listener.terminate()
preview?.waitUntilExit()
listener.waitUntilExit()

if FileManager.default.fileExists(atPath: backupFile.path) {
    try? FileManager.default.removeItem(at: settingsFile)
    try? FileManager.default.moveItem(at: backupFile, to: settingsFile)
}

print("")
print("spike-events: capture written to \(captureFile.path)")
summarize(captureFile: captureFile)
