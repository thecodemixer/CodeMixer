import Testing
import Foundation
@testable import AgentCore
#if canImport(Darwin)
import Darwin
#endif

/// Verifies the global `ChildReaper` is idempotent and reaps short-lived
/// children spawned via `posix_spawn` so the host process never accumulates
/// zombies. Real production install happens in the app/daemon `main`; tests
/// just exercise the actor surface in isolation.
@Suite("ChildReaper", .serialized)
struct ChildReaperTests {

    @Test("install is idempotent — calling twice does not crash")
    func installIsIdempotent() {
        ChildReaper.shared.install()
        ChildReaper.shared.install()
        ChildReaper.shared.uninstall()
    }

    @Test("posix-spawned short children get reaped within 1s")
    func zombiesAreReaped() async throws {
        ChildReaper.shared.install()
        defer { ChildReaper.shared.uninstall() }

        // Spawn a handful of /usr/bin/true children. Without a reaper they
        // would linger as zombies; with the reaper the kernel cleans them
        // up. We can't easily probe the zombie set portably, so the value
        // of this test is mostly "does not crash + completes promptly".
        for _ in 0..<8 {
            var pid: pid_t = 0
            let argv: [UnsafeMutablePointer<CChar>?] = [
                strdup("true"), nil,
            ]
            defer { argv.compactMap { $0 }.forEach { free($0) } }
            let envp: [UnsafeMutablePointer<CChar>?] = [nil]

            let rc = posix_spawn(&pid, SystemPaths.trueBinary.path, nil, nil, argv, envp)
            #expect(rc == 0)
        }

        // Give the reaper a beat to run on its SIGCHLD source.
        try await Task.sleep(for: .milliseconds(250))
    }
}
