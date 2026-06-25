import Foundation

/// Runs `body` and returns its value, or throws `TimeoutError` if `duration`
/// elapses first. Cancels the body task on timeout.
///
/// This is a drop-in replacement for the bare `Task.sleep + collector.cancel()`
/// pattern used in older twin test helpers.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Thrown when `withTimeout` reaches its deadline before the body completes.
struct TimeoutError: Error {}
