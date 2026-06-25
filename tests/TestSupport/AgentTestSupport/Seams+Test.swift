import Foundation
import AgentCore

/// A pinned reference date for use in tests that need a deterministic
/// `Date` value without involving the real system clock.
///
/// Equivalent to 2024-01-01T00:00:00Z. Tests should prefer this constant
/// over bare `Date()` whenever the exact timestamp is not load-bearing.
public let testEpoch: Date = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: DateComponents(year: 2024, month: 1, day: 1))!
}()

public extension Seams {
    /// Bundle of fakes suitable for unit tests.
    static func fake(clock: FakeClock = FakeClock(),
                     random: FakeRandomSource = FakeRandomSource(),
                     environment: FakeEnvironment = FakeEnvironment(),
                     fileSystem: any FileSystem = InMemoryFileSystem()) -> Seams {
        Seams(clock: clock, random: random, environment: environment, fileSystem: fileSystem)
    }
}
