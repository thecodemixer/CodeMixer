import Foundation
import AgentCore

/// Runtime seams owned by the Claude Code digital twin.
///
/// The twin is executable specification code, not engine production code, but
/// its clock, random IDs, and transcript filesystem still need one auditable
/// owner. Tests can pass fakes from `AgentTestSupport`; live twin runs use the
/// normal AgentCore seam implementations.
public struct TwinRuntimeSeams: Sendable {
    public static let live = TwinRuntimeSeams()

    private let clock: any AgentClock
    private let random: any RandomSource
    private let fileSystem: any FileSystem

    public init(clock: any AgentClock = SystemClock(),
                random: any RandomSource = SystemRandomSource(),
                fileSystem: any FileSystem = SystemFileSystem()) {
        self.clock = clock
        self.random = random
        self.fileSystem = fileSystem
    }

    public func now() -> Date {
        clock.now()
    }

    public func uuid() -> UUID {
        random.uuid()
    }

    public func uuidString() -> String {
        uuid().uuidString
    }

    public func permissionID() -> String {
        "perm_\(uuidString().prefix(8))"
    }

    public func sleep(for duration: Duration) async {
        try? await clock.sleep(for: duration)
    }

    public func readDataIfPresent(at url: URL) -> Data? {
        guard fileSystem.fileExists(at: url) else { return nil }
        return try? fileSystem.readData(at: url)
    }

    public func ensureParentDirectory(for url: URL) throws {
        try fileSystem.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediates: true
        )
    }

    public func append(_ data: Data, to url: URL) throws {
        try ensureParentDirectory(for: url)
        let existing = readDataIfPresent(at: url) ?? Data()
        try fileSystem.writeAtomically(existing + data, to: url)
    }
}
