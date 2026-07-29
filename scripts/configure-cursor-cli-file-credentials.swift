#!/usr/bin/env swift
/// Ensures `AGENT_CLI_CREDENTIAL_STORE=file` is exported in the user's `~/.zprofile`.
///
/// Cursor CLI on macOS can fail to read Keychain-backed tokens after auto-updates or
/// re-login (`Keychain operation timed out`, `Authentication required` on `models`).
/// File-based credential storage bypasses Keychain for `cursor-agent` and Codemixer
/// model discovery (which shells out to `cursor-agent models`).
///
/// Idempotent: skips when the export is already present.
///
/// Usage:
///   scripts/configure-cursor-cli-file-credentials.swift
import Foundation

let exportLine = "export AGENT_CLI_CREDENTIAL_STORE=file"
let marker = "# Cursor CLI: store auth in file instead of macOS Keychain (Codemixer model probe)"
let block = "\n\(marker)\n\(exportLine)\n"

let home = FileManager.default.homeDirectoryForCurrentUser
let zprofile = home.appendingPathComponent(".zprofile")

func existingContent() -> String {
    guard FileManager.default.fileExists(atPath: zprofile.path) else { return "" }
    return (try? String(contentsOf: zprofile, encoding: .utf8)) ?? ""
}

let content = existingContent()
if content.contains(exportLine) {
    print("OK: \(exportLine) already present in \(zprofile.path)")
    exit(0)
}

let trimmed = content.hasSuffix("\n") || content.isEmpty ? content : content + "\n"
let updated = trimmed + block

do {
    try updated.write(to: zprofile, atomically: true, encoding: .utf8)
    print("Added Cursor CLI file credential store to \(zprofile.path)")
    print("  \(exportLine)")
    print("Open a new terminal or run: source ~/.zprofile")
} catch {
    fputs("FAIL: could not write \(zprofile.path): \(error)\n", stderr)
    exit(1)
}
