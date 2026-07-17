#!/usr/bin/env swift
/// check-package-layout.swift
///
/// Fails if the SPM package drifts back to the pre-root layout:
/// - `tests/` must live at the repository root (not under `Codemixer/Packages/`).
/// - Agent CLI adapters live under `src/AgenticCLIs/<AgentName>/` (not `src/ClaudeCode/`).
/// - Agent CLI adapter tests live under `tests/AgenticCLIs/<AgentName>/` (not `tests/ClaudeAdapterTests/`).
///
/// Usage:
///   scripts/check-package-layout.swift

import Foundation

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let fm = FileManager.default

let forbiddenPaths = [
    "Codemixer",
    "Codemixer/Packages/Codemixer",
    "Codemixer/Packages/Codemixer/Tests",
    "Codemixer/Packages/Codemixer/Sources",
    "src/AgentTestSupport",
    "src/AgentCore",
    "src/AgentProtocol",
    "src/Project.swift",
    "src/Codemixer.xcodeproj",
    "src/AgentRemoteControl",
    "src/CodemixerDaemon",
    "src/CPosixBridge",
    "src/ClaudeCode",
    "src/ClaudeAdapter",
    "src/ClaudeSupport",
    "src/digital-twins",
    "src/digital-twins/claude-code",
    "tests/AgentRemoteControlTests",
    "tests/RemoteParityTests",
    "tests/Core/AgentRemoteControlTests",
    "tests/Core/RemoteParityTests",
    "tests/AgentTestSupport",
    "tests/AgentTestSupportTests",
    "tests/ClaudeAdapterTests",
    "tests/ClaudeCodeTwinTests",
]

let requiredPaths = [
    "src/CodemixerApp/Project.swift",
    "src/Core/AgentCore/PTY/PTYHost.swift",
    "src/Core/AgentProtocol/AgentCommand.swift",
    "src/AgenticCLIs/README.md",
    "src/Core/CPosixBridge/CPosixBridge.c",
    "src/AgenticCLIs/ClaudeCode/README.md",
    "src/AgenticCLIs/Codex/README.md",
    "tests/AgenticCLIs/README.md",
]

let requiredDirectories = [
    "src/Core/AgentCore",
    "src/Core/AgentProtocol",
    "src/Core/CPosixBridge",
    "src/AgenticCLIs/ClaudeCode/Adapter",
    "src/AgenticCLIs/ClaudeCode/Common",
    "src/AgenticCLIs/ClaudeCode/digital-twin/Twin",
    "src/AgenticCLIs/Codex/Adapter",
    "src/AgenticCLIs/Codex/Common",
    "src/AgenticCLIs/Codex/digital-twin/Twin",
    "tests/AgenticCLIs/ClaudeCode",
    "tests/AgenticCLIs/Codex",
]

let requiredTestSuites = [
    "tests/TestSupport/AgentTestSupport",
    "tests/Core/AgentProtocolTests",
    "tests/Core/AgentCoreTests",
    "tests/AgenticCLIs/ClaudeCode/ClaudeAdapterTests",
    "tests/AgenticCLIs/Codex/CodexAdapterTests",
    "tests/Remote/AgentRemoteControlTests",
    "tests/AgentUITests",
    "tests/Remote/RemoteParityTests",
    "tests/AgenticCLIs/ClaudeCode/ClaudeCodeTwinTests",
    "tests/AgenticCLIs/Codex/CodexTwinTests",
    "tests/TestSupport/AgentTestSupportTests",
]

var failures: [String] = []

for relative in forbiddenPaths {
    let url = repoRoot.appendingPathComponent(relative)
    if fm.fileExists(atPath: url.path) {
        failures.append("forbidden path still exists: \(relative)")
    }
}

for relative in requiredPaths {
    let url = repoRoot.appendingPathComponent(relative)
    if !fm.fileExists(atPath: url.path) {
        failures.append("missing required path: \(relative)")
    }
}

for relative in requiredDirectories {
    let url = repoRoot.appendingPathComponent(relative, isDirectory: true)
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        failures.append("missing required directory: \(relative)")
        continue
    }
}

for relative in requiredTestSuites {
    let url = repoRoot.appendingPathComponent(relative, isDirectory: true)
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        failures.append("missing test suite directory: \(relative)")
        continue
    }
    let swiftFiles = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))?
        .filter { $0.pathExtension == "swift" } ?? []
    if swiftFiles.isEmpty {
        failures.append("test suite has no .swift files: \(relative)")
    }
}

let packageManifest = repoRoot.appendingPathComponent("Package.swift")
if !fm.fileExists(atPath: packageManifest.path) {
    failures.append("missing Package.swift at repository root")
} else if let manifest = try? String(contentsOf: packageManifest, encoding: .utf8) {
    let pathPattern = #"path:\s*"([^"]+)""#
    if let regex = try? NSRegularExpression(pattern: pathPattern) {
        let range = NSRange(manifest.startIndex..<manifest.endIndex, in: manifest)
        let declaredPaths = Set(
            regex.matches(in: manifest, range: range).compactMap { match -> String? in
                guard let capture = Range(match.range(at: 1), in: manifest) else { return nil }
                return String(manifest[capture])
            }
            .filter { $0.hasPrefix("tests/") }
        )
        let requiredPaths = Set(requiredTestSuites)
        for missing in requiredPaths.subtracting(declaredPaths) {
            failures.append("Package.swift missing testTarget path: \(missing)")
        }
        for extra in declaredPaths.subtracting(requiredPaths) {
            failures.append("Package.swift declares undeclared test path: \(extra)")
        }
    } else {
        failures.append("internal error: could not compile Package.swift path regex")
    }
}

if failures.isEmpty {
    print("Package layout OK (\(requiredTestSuites.count) test suites at repo-root tests/).")
    exit(0)
}

for failure in failures {
    FileHandle.standardError.write(Data("error: \(failure)\n".utf8))
}
exit(1)
