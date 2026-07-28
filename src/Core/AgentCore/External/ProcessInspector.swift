/// Wraps the two process-identity calls used to reclaim stale transcript lock
/// files. No process lifecycle or spawning responsibility lives here.
import Darwin

struct ProcessInspector: Sendable {
    var currentPID: Int32 {
        getpid()
    }

    func isRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
