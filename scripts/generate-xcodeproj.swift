#!/usr/bin/env swift
import Foundation

// generate-xcodeproj.swift — generate Codemixer.xcodeproj via Tuist.
//
// Tuist (https://tuist.io) reads `src/CodemixerApp/Project.swift` and emits a
// fresh Xcode project under `src/CodemixerApp/` that wires up the SPM package at
// the repository root (`Package.swift`, `src/`, `tests/`).
//
// Install Tuist:
//   curl -Ls https://install.tuist.io | bash
//   # or via mise / asdf — see https://docs.tuist.io/guides/quick-start/install-tuist
//
// Usage:
//   scripts/generate-xcodeproj.swift            # generate (opens in Xcode by default)
//   scripts/generate-xcodeproj.swift --no-open  # generate without opening
//   scripts/generate-xcodeproj.swift --clean    # purge .tuist/derived caches first
//
// Any flags not understood by this wrapper are forwarded verbatim to `tuist generate`.

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let tuistProjectDir = repoRoot.appendingPathComponent("src/CodemixerApp", isDirectory: true)

func which(_ tool: String) -> URL? {
    let candidates = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "\(NSHomeDirectory())/.tuist/bin",
        "\(NSHomeDirectory())/.local/share/mise/installs/tuist/latest/bin",
        "\(NSHomeDirectory())/.local/bin",
        "/usr/bin",
        "/bin",
    ]
    for prefix in candidates {
        let candidate = URL(fileURLWithPath: prefix).appendingPathComponent(tool)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
}

@discardableResult
func run(_ executable: URL, _ args: [String], cwd: URL) -> Int32 {
    let process = Process()
    process.executableURL = executable
    process.arguments = args
    process.currentDirectoryURL = cwd
    do { try process.run() } catch {
        FileHandle.standardError.write(Data("failed to spawn \(executable.path): \(error)\n".utf8))
        return -1
    }
    process.waitUntilExit()
    return process.terminationStatus
}

guard let tuist = which("tuist") else {
    FileHandle.standardError.write(Data("""
    ERROR: tuist not found on PATH.
    Install with: curl -Ls https://install.tuist.io | bash
    Or via mise:  mise install tuist
    Docs:         https://docs.tuist.io/guides/quick-start/install-tuist
    """.utf8))
    exit(1)
}

var forwarded = Array(CommandLine.arguments.dropFirst())
let cleanRequested = forwarded.contains("--clean")
forwarded.removeAll { $0 == "--clean" }

if cleanRequested {
    print("Cleaning Tuist caches…")
    let status = run(tuist, ["clean"], cwd: tuistProjectDir)
    if status != 0 { exit(status) }
}

print("Generating src/CodemixerApp/Codemixer.xcodeproj via tuist generate…")
let status = run(tuist, ["generate"] + forwarded, cwd: tuistProjectDir)
exit(status)
