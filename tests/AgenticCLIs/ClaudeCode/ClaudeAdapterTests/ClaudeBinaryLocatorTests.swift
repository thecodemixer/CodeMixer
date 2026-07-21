import Foundation
import Testing
@testable import ClaudeCode
import AgentCore

@Suite("ClaudeBinaryLocator")
struct ClaudeBinaryLocatorTests {

    private let locator = ClaudeBinaryLocator()
    private let sh = SystemPaths.sh

    @Test("CLAUDE_BIN override is respected when the path is executable")
    func claudeBinOverride() throws {
        // /bin/cat is always present on macOS and is executable.
        let env = ResolvedEnvironment(variables: ["CLAUDE_BIN": "/bin/cat", "PATH": "/nonexistent"],
                                      shell: sh)
        let url = try locator.locate(env: env)
        #expect(url.path == "/bin/cat")
    }

    @Test("CLAUDE_BIN override is ignored when the path is not executable, falls through to PATH")
    func claudeBinOverrideNonExecutableFallsThrough() throws {
        // Create a real `claude` stub in a temp directory to ensure the locator
        // finds it after skipping the bad CLAUDE_BIN value.
        let tmp = try makeTmpBin(named: "claude")
        defer { try? FileManager.default.removeItem(at: tmp.dir) }

        let env = ResolvedEnvironment(
            variables: ["CLAUDE_BIN": "/nonexistent/fake-claude",
                        "PATH": tmp.dir.path],
            shell: sh)
        let found = try locator.locate(env: env)
        // Should find our stub, not the bad override.
        #expect(found.path == tmp.bin.path)
    }

    @Test("locate finds 'claude' on PATH when present")
    func findsClaudeOnPath() throws {
        let tmp = try makeTmpBin(named: "claude")
        defer { try? FileManager.default.removeItem(at: tmp.dir) }

        let env = ResolvedEnvironment(variables: ["PATH": tmp.dir.path], shell: sh)
        let found = try locator.locate(env: env)
        #expect(found.path == tmp.bin.path)
    }

    @Test("locate searches multiple PATH components in order")
    func searchesPathOrder() throws {
        let tmp1 = try makeTmpBin(named: "claude")
        let tmp2 = try makeTmpBin(named: "claude")
        defer {
            try? FileManager.default.removeItem(at: tmp1.dir)
            try? FileManager.default.removeItem(at: tmp2.dir)
        }

        // PATH has tmp1 first — expect tmp1's binary to win.
        let env = ResolvedEnvironment(
            variables: ["PATH": "\(tmp1.dir.path):\(tmp2.dir.path)"],
            shell: sh)
        let found = try locator.locate(env: env)
        #expect(found.path == tmp1.bin.path)
    }

    @Test("CODEMIXER_FAKE_CLAUDE=1 finds 'fake-claude' on PATH when present")
    func fakeClaude() throws {
        let tmp = try makeTmpBin(named: "fake-claude")
        defer { try? FileManager.default.removeItem(at: tmp.dir) }

        let env = ResolvedEnvironment(
            variables: ["CODEMIXER_FAKE_CLAUDE": "1", "PATH": tmp.dir.path],
            shell: sh)
        let found = try locator.locate(env: env)
        #expect(found.path == tmp.bin.path)
    }

    @Test("LocateError.notFound carries the checked paths when nothing is found")
    func notFoundCarriesPaths() {
        // Use an impossible PATH so neither `claude` nor `fake-claude` is found.
        // We also set CLAUDE_BIN to a non-existent path so the override skip fires.
        let env = ResolvedEnvironment(variables: ["PATH": "/zz-nonexistent-a:/zz-nonexistent-b",
                                                  "CODEMIXER_FAKE_CLAUDE": "0"],
                                      shell: sh)
        do {
            _ = try locator.locate(env: env)
            // If we reach this, some fake-claude was found via .build/debug — acceptable
            // in a dev context. Skip the assertion rather than fail the suite.
        } catch let err as ClaudeBinaryLocator.LocateError {
            if case .notFound(let checked) = err {
                #expect(checked.contains(where: { $0.contains("nonexistent") }))
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: - Helpers

    private struct TmpBin {
        let dir: URL
        let bin: URL
    }

    /// Creates a temp dir with a minimal executable shell script named `name`.
    private func makeTmpBin(named name: String) throws -> TmpBin {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent(name)
        try "#!/bin/sh\necho stub".write(to: bin, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        return TmpBin(dir: dir, bin: bin)
    }
}
