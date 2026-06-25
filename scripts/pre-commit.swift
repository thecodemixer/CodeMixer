#!/usr/bin/env swift
import Foundation

// Pre-commit hook for Codemixer.
// Install: ln -sf ../../scripts/pre-commit.swift .git/hooks/pre-commit
//
// What it does:
//   1. Builds the full package (errors abort the commit).
//   2. Runs the test suite serially (failures abort the commit).
//   3. Runs SwiftFormat in lint-only mode (diffs abort the commit).
//   4. Runs SwiftLint (errors abort the commit; warnings are tolerated).

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let packageDir = repoRoot

let green = "\u{001B}[0;32m"
let yellow = "\u{001B}[0;33m"
let red = "\u{001B}[0;31m"
let reset = "\u{001B}[0m"

func step(_ message: String) { print("\(green)▶ \(message)\(reset)") }
func warn(_ message: String) { print("\(yellow)⚠ \(message)\(reset)") }
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

@discardableResult
func run(_ executable: URL, _ args: [String], cwd: URL? = nil) -> Int32 {
    let process = Process()
    process.executableURL = executable
    process.arguments = args
    if let cwd { process.currentDirectoryURL = cwd }
    do { try process.run() } catch {
        FileHandle.standardError.write(Data("failed to spawn \(executable.path): \(error)\n".utf8))
        return -1
    }
    process.waitUntilExit()
    return process.terminationStatus
}

guard let swift = which("swift") else { fail("swift not found on PATH") }

step("swift build")
if run(swift, ["build"], cwd: packageDir) != 0 {
    fail("Build failed — fix errors before committing.")
}

step("swift test --no-parallel")
// `--no-parallel` is required: several suites own kernel-level resources
// (PTYs, NWListeners, SIGCHLD handlers) that race under parallel scheduling.
if run(swift, ["test", "--no-parallel"], cwd: packageDir) != 0 {
    fail("Tests failed — fix before committing.")
}

if let swiftformat = which("swiftformat") {
    step("SwiftFormat (lint)")
    if run(swiftformat, ["--lint", "src", "tests"], cwd: packageDir) != 0 {
        fail("SwiftFormat found formatting issues. Run 'swiftformat src tests' to fix.")
    }
} else {
    warn("swiftformat not found — skipping (install via: brew install swiftformat)")
}

if let swiftlint = which("swiftlint") {
    step("SwiftLint")
    if run(swiftlint, ["lint", "--strict", "src"], cwd: packageDir) != 0 {
        fail("SwiftLint found violations.")
    }
} else {
    warn("swiftlint not found — skipping (install via: brew install swiftlint)")
}

print("\n\(green)✓ Pre-commit checks passed\(reset)")
