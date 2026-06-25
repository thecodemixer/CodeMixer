import Foundation

/// Bundle of all four DI seams.
///
/// Top-level types accept a single `Seams` rather than four separate
/// arguments. Production wiring: `Seams.live`. Tests construct a `Seams` with
/// fakes from `AgentTestSupport`.
public struct Seams: Sendable {
    public let clock: any AgentClock
    public let random: any RandomSource
    public let environment: any AgentEnvironment
    public let fileSystem: any FileSystem

    public init(clock: any AgentClock,
                random: any RandomSource,
                environment: any AgentEnvironment,
                fileSystem: any FileSystem) {
        self.clock = clock
        self.random = random
        self.environment = environment
        self.fileSystem = fileSystem
    }

    /// Production wiring — real clock, system random, real env, real FS.
    public static var live: Seams {
        Seams(clock: SystemClock(),
              random: SystemRandomSource(),
              environment: SystemEnvironment(),
              fileSystem: SystemFileSystem())
    }
}
