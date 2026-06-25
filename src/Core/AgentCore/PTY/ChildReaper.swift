import Foundation
import Darwin
import Dispatch
import OSLog

/// Global, single-instance SIGCHLD reaper.
///
/// Each `PTYHost` waitpid()s its own child, but the engine also spawns
/// short-lived helper processes (git for revert, openssl for cert minting,
/// etc.) and those would accumulate as zombies without a reaper. `Shared`
/// installs a SIGCHLD handler that calls `waitpid(-1, … , WNOHANG)` in a
/// tight loop so no zombie sits around for more than one signal delivery.
///
/// Safe to instantiate multiple times — the SIGCHLD handler is installed
/// only once thanks to `dispatch_once`-equivalent guard.
///
/// `@unchecked Sendable`: all mutable state (`source`, `installed`) is
/// protected by `NSLock`; the `DispatchSourceSignal` is set-once.
public final class ChildReaper: @unchecked Sendable {

    public static let shared = ChildReaper()

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "ChildReaper")
    private var source: (any DispatchSourceSignal)?
    private let lock = NSLock()
    private var installed = false

    private init() {}

    /// Install the SIGCHLD handler. Idempotent — calling twice is a no-op.
    public func install() {
        lock.lock(); defer { lock.unlock() }
        guard !installed else { return }
        installed = true

        // NOTE: We deliberately do NOT call `signal(SIGCHLD, SIG_IGN)` —
        // on macOS that flag asks the kernel to auto-reap children, which
        // races `PTYHost.waitpid` and turns successful exits into ECHILD.
        // `DispatchSource.makeSignalSource` listens via kqueue without
        // consuming the signal, so the default SIGCHLD action ("ignore,
        // but leave zombies until waitpid") is exactly what we want.

        let source = DispatchSource.makeSignalSource(signal: SIGCHLD,
                                                     queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            self?.reapAll()
        }
        source.resume()
        self.source = source
        log.notice("ChildReaper installed")
    }

    /// Stop reaping. The signal handler is detached but the source is kept
    /// alive for re-install.
    public func uninstall() {
        lock.lock(); defer { lock.unlock() }
        source?.cancel()
        source = nil
        installed = false
    }

    private func reapAll() {
        var raw: Int32 = 0
        while waitpid(-1, &raw, WNOHANG) > 0 {
            // Zero or positive pid means we reaped a child; loop until -1.
        }
    }
}
