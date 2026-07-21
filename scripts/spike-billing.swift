#!/usr/bin/env swift
// spike-billing.swift - live billing validation over Claude's interactive path.
//
// This script intentionally launches `claude` with no non-interactive flags.
// It opens a real PTY, sends one prompt over stdin, waits for Claude's normal
// Stop hook, then reads token/cost usage from the interactive transcript JSONL.

import Darwin
import Foundation

// MARK: - Shared hook helpers (keep in sync with spike-events.swift)

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

    static func standardBinary(named name: String) -> [String] {
        var paths: [String] = []
        if let prefix = ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"], !prefix.isEmpty {
            paths.append("\(prefix)/bin/\(name)")
        }
        paths.append(contentsOf: [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ])
        return paths
    }
}

struct Config {
    let workspace: URL
    let prompt: String
    let timeoutSeconds: Int

    init(arguments: [String]) throws {
        var workspacePath: String?
        var prompt = "count to 10"
        var timeout = 180

        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--prompt" {
                guard index + 1 < arguments.count else {
                    throw NSError(domain: "spike-billing", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing --prompt value"])
                }
                prompt = arguments[index + 1]
                index += 2
                continue
            }
            if arg == "--timeout-secs" {
                guard index + 1 < arguments.count,
                      let value = Int(arguments[index + 1]),
                      value > 0 else {
                    throw NSError(domain: "spike-billing", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Invalid --timeout-secs value"])
                }
                timeout = value
                index += 2
                continue
            }
            if arg.hasPrefix("-") {
                throw NSError(domain: "spike-billing", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Unexpected option: \(arg)"])
            }
            if workspacePath == nil {
                workspacePath = arg
                index += 1
                continue
            }
            throw NSError(domain: "spike-billing", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unexpected argument: \(arg)"])
        }

        let base = workspacePath ?? FileManager.default.currentDirectoryPath
        self.workspace = URL(fileURLWithPath: base, isDirectory: true)
        self.prompt = prompt
        self.timeoutSeconds = timeout
    }
}

struct UsageTotals {
    var inputTokens = 0
    var outputTokens = 0
    var costUSD = 0.0
}

struct TranscriptRecord: Decodable {
    let message: Message?

    struct Message: Decodable {
        let usage: Usage?
    }

    struct Usage: Decodable {
        let input_tokens: Int?
        let output_tokens: Int?
        let cost_usd: Double?
    }
}

func openPTYPair() -> (master: Int32, slave: Int32)? {
    var master: Int32 = -1
    var slave: Int32 = -1
    guard openpty(&master, &slave, nil, nil, nil) == 0 else { return nil }
    return (master, slave)
}

func commandExists(_ path: String) -> Bool {
    FileManager.default.isExecutableFile(atPath: path)
}

func locateClaude() -> String? {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
    let searchPaths = ScriptPaths.standardBinary(named: "claude") + [
        "\(home)/.local/bin/claude",
        "\(home)/.nvm/current/bin/claude",
        "\(home)/.volta/bin/claude",
    ]
    let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map { String($0) + "/claude" }
    return (searchPaths + pathCandidates).first(where: commandExists)
}

func runHookListener(socketPath: String, captureFile: URL) throws -> Process {
    let script = """
    import os, socket, sys
    path, capture = sys.argv[1], sys.argv[2]
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(32)
    while True:
        conn, _ = server.accept()
        chunks = []
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        payload = b"".join(chunks)
        with open(capture, "ab") as handle:
            handle.write(payload + b"\\n")
        conn.sendall(b"{}\\n")
        conn.close()
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ScriptPaths.python3)
    process.arguments = ["-c", script, socketPath, captureFile.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    return process
}

func hookState(captureFile: URL) -> (sawStop: Bool, sessionID: String?) {
    guard let data = try? Data(contentsOf: captureFile),
          let text = String(data: data, encoding: .utf8) else {
        return (false, nil)
    }
    var sawStop = false
    var sessionID: String?
    for objectText in SpikeHookSupport.extractJSONObjects(from: text) {
        guard let data = objectText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }
        let event = (object["hook_event_name"] as? String) ??
            (object["event"] as? String) ??
            (object["type"] as? String)
        if event == "Stop" { sawStop = true }
        if sessionID == nil {
            sessionID = object["session_id"] as? String
        }
    }
    return (sawStop, sessionID)
}

func projectSlug(for workspace: URL) -> String {
    String(workspace.path.map { ch in
        (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
    })
}

func transcriptURL(sessionID: String, workspace: URL, claudeDirectory: URL) -> URL {
    claudeDirectory
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(projectSlug(for: workspace), isDirectory: true)
        .appendingPathComponent("\(sessionID).jsonl")
}

func newestTranscript(workspace: URL, claudeDirectory: URL, startedAt: Date) -> URL? {
    let directory = claudeDirectory
        .appendingPathComponent("projects", isDirectory: true)
        .appendingPathComponent(projectSlug(for: workspace), isDirectory: true)
    guard let urls = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else {
        return nil
    }
    return urls
        .filter { $0.pathExtension == "jsonl" }
        .compactMap { url -> (URL, Date)? in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = values?.contentModificationDate, date >= startedAt else { return nil }
            return (url, date)
        }
        .sorted { $0.1 > $1.1 }
        .first?.0
}

func usageTotals(in transcript: URL) -> UsageTotals {
    guard let text = try? String(contentsOf: transcript, encoding: .utf8) else {
        return UsageTotals()
    }
    var totals = UsageTotals()
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
        guard let data = String(rawLine).data(using: .utf8),
              let record = try? JSONDecoder().decode(TranscriptRecord.self, from: data),
              let usage = record.message?.usage else {
            continue
        }
        totals.inputTokens += usage.input_tokens ?? 0
        totals.outputTokens += usage.output_tokens ?? 0
        totals.costUSD += usage.cost_usd ?? 0
    }
    return totals
}

func writeLine(_ line: String, to fd: Int32) {
    let data = Data((line + "\n").utf8)
    data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else { return }
        _ = Darwin.write(fd, base, buffer.count)
    }
}

func waitForExit(pid: pid_t, seconds: Int) -> Bool {
    var status: Int32 = 0
    for _ in 0..<(seconds * 10) {
        if waitpid(pid, &status, WNOHANG) == pid { return true }
        usleep(100_000)
    }
    return false
}

let config: Config
do {
    config = try Config(arguments: CommandLine.arguments)
} catch {
    fputs("Usage: scripts/spike-billing.swift [workspace-path] [--prompt TEXT] [--timeout-secs N]\n", stderr)
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(2)
}

guard FileManager.default.isExecutableFile(atPath: ScriptPaths.python3) else {
    fputs("spike-billing: python3 is required for hook forwarding (set PYTHON3_BIN)\n", stderr)
    exit(1)
}

guard let claudePath = locateClaude() else {
    fputs("spike-billing: `claude` not found. Install with:\n  npm install -g @anthropic-ai/claude-code\n", stderr)
    exit(1)
}

guard let home = ProcessInfo.processInfo.environment["HOME"] else {
    fputs("spike-billing: HOME is not set\n", stderr)
    exit(1)
}

let startedAt = Date()
let ts = Int(startedAt.timeIntervalSince1970)
let captureFile = ScriptPaths.tmp.appendingPathComponent("codemixer-spike-billing-\(ts).jsonl")
let socketPath = ScriptPaths.tmp.appendingPathComponent("codemixer-spike-billing-\(ts).sock").path
let settingsDir = config.workspace.appendingPathComponent(".claude", isDirectory: true)
let settingsFile = settingsDir.appendingPathComponent("settings.local.json")
let backupFile = settingsFile.appendingPathExtension("spike-backup")
let claudeDirectory = URL(fileURLWithPath: home, isDirectory: true)
    .appendingPathComponent(".claude", isDirectory: true)

try? FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
if FileManager.default.fileExists(atPath: settingsFile.path) {
    try? FileManager.default.removeItem(at: backupFile)
    try FileManager.default.copyItem(at: settingsFile, to: backupFile)
}

func restoreSettings() {
    if FileManager.default.fileExists(atPath: backupFile.path) {
        try? FileManager.default.removeItem(at: settingsFile)
        try? FileManager.default.moveItem(at: backupFile, to: settingsFile)
    } else {
        try? FileManager.default.removeItem(at: settingsFile)
    }
}

do {
    try SpikeHookSupport.writePythonHookSettings(file: settingsFile,
                                                 socketPath: socketPath,
                                                 hookNames: ["SessionStart", "Stop"])
} catch {
    restoreSettings()
    fputs("spike-billing: failed writing hook settings: \(error)\n", stderr)
    exit(1)
}

let listener: Process
do {
    listener = try runHookListener(socketPath: socketPath, captureFile: captureFile)
} catch {
    restoreSettings()
    fputs("spike-billing: failed to start hook listener: \(error)\n", stderr)
    exit(1)
}

guard let pty = openPTYPair() else {
    listener.terminate()
    restoreSettings()
    fputs("spike-billing: openpty failed, errno \(errno)\n", stderr)
    exit(1)
}

let args = [claudePath]
var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
argv.append(nil)

var env = ProcessInfo.processInfo.environment
env["TERM"] = "xterm-256color"
env["FORCE_COLOR"] = "1"
env["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] = "1"
env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
let envStrings = env.map { "\($0.key)=\($0.value)" }
var envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) }
envp.append(nil)

defer {
    argv.forEach { free($0) }
    envp.forEach { free($0) }
}

var attr = posix_spawnattr_t(bitPattern: 0)
posix_spawnattr_init(&attr)
var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
posix_spawn_file_actions_init(&fileActions)
posix_spawn_file_actions_adddup2(&fileActions, pty.slave, STDIN_FILENO)
posix_spawn_file_actions_adddup2(&fileActions, pty.slave, STDOUT_FILENO)
posix_spawn_file_actions_adddup2(&fileActions, pty.slave, STDERR_FILENO)

var pid: pid_t = 0
let oldCWD = FileManager.default.currentDirectoryPath
FileManager.default.changeCurrentDirectoryPath(config.workspace.path)
let rc = posix_spawn(&pid, claudePath, &fileActions, &attr, &argv, &envp)
FileManager.default.changeCurrentDirectoryPath(oldCWD)
posix_spawn_file_actions_destroy(&fileActions)
posix_spawnattr_destroy(&attr)
close(pty.slave)

guard rc == 0 else {
    close(pty.master)
    listener.terminate()
    restoreSettings()
    fputs("spike-billing: posix_spawn failed, errno \(rc)\n", stderr)
    exit(1)
}

var outputData = Data()
let outputLock = NSLock()
Thread.detachNewThread {
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { buffer.deallocate() }
    while true {
        let n = Darwin.read(pty.master, buffer, 4096)
        if n <= 0 { break }
        outputLock.lock()
        outputData.append(buffer, count: n)
        outputLock.unlock()
    }
}

print("spike-billing: workspace = \(config.workspace.path)")
print("spike-billing: claude    = \(claudePath)")
print("spike-billing: mode      = interactive PTY")
print("spike-billing: prompt    = \(config.prompt)")

sleep(3)
writeLine(config.prompt, to: pty.master)

let deadline = Date().addingTimeInterval(TimeInterval(config.timeoutSeconds))
var finalHookState = hookState(captureFile: captureFile)
while Date() < deadline {
    finalHookState = hookState(captureFile: captureFile)
    if finalHookState.sawStop { break }
    usleep(250_000)
}

writeLine("/quit", to: pty.master)
if !waitForExit(pid: pid, seconds: 5) {
    Darwin.kill(pid, SIGTERM)
    _ = waitForExit(pid: pid, seconds: 2)
}
close(pty.master)
listener.terminate()
listener.waitUntilExit()
restoreSettings()
try? FileManager.default.removeItem(atPath: socketPath)

guard finalHookState.sawStop else {
    outputLock.lock()
    let output = String(data: outputData.suffix(2048), encoding: .utf8) ?? ""
    outputLock.unlock()
    fputs("spike-billing: timed out waiting for Stop hook\n", stderr)
    if !output.isEmpty {
        fputs("spike-billing: recent PTY output:\n\(output)\n", stderr)
    }
    exit(1)
}

let transcript: URL?
if let sessionID = finalHookState.sessionID {
    transcript = transcriptURL(sessionID: sessionID,
                               workspace: config.workspace,
                               claudeDirectory: claudeDirectory)
} else {
    transcript = newestTranscript(workspace: config.workspace,
                                  claudeDirectory: claudeDirectory,
                                  startedAt: startedAt)
}

guard let transcript else {
    fputs("spike-billing: no transcript found for interactive session\n", stderr)
    exit(1)
}

let totals = usageTotals(in: transcript)
print("""
spike-billing: RESULTS
  transcript   : \(transcript.path)
  input_tokens : \(totals.inputTokens)
  output_tokens: \(totals.outputTokens)
  cost_usd     : \(String(format: "%.6f", totals.costUSD))
""")

if totals.inputTokens == 0 && totals.outputTokens == 0 {
    fputs("spike-billing: WARNING - no token usage found in transcript\n", stderr)
    exit(1)
}

print("spike-billing: PASS - billing data captured from interactive Claude.")
