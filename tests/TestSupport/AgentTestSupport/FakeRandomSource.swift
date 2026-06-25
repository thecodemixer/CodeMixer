import Foundation
import AgentCore

/// Pinned `RandomSource` for deterministic tests.
///
/// `@unchecked Sendable`: all mutable state is protected by `NSLock`; no
/// reference escapes to a concurrent caller.
public final class FakeRandomSource: RandomSource, @unchecked Sendable {
    private let lock = NSLock()
    private var uuids: [UUID]
    private var pins: [String]
    private var byteSequence: [UInt8]
    private var uuidIndex = 0
    private var pinIndex = 0
    /// Advances across consecutive `bytes(_:)` calls so distinct invocations
    /// return different data.
    private var byteIndex = 0

    public init(uuids: [UUID] = (0..<32).map { _ in UUID() },
                pins: [String] = ["000000"],
                bytes: [UInt8] = Array(repeating: 0xAB, count: 256)) {
        self.uuids = uuids
        self.pins = pins
        self.byteSequence = bytes
    }

    public func uuid() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let v = uuids[uuidIndex % uuids.count]
        uuidIndex += 1
        return v
    }

    public func bytes(_ count: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        var out = Data(capacity: count)
        for _ in 0..<count {
            out.append(byteSequence[byteIndex % byteSequence.count])
            byteIndex += 1
        }
        return out
    }

    public func pin(digits: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        let v = pins[pinIndex % pins.count]
        pinIndex += 1
        return String(v.padding(toLength: digits, withPad: "0", startingAt: 0))
    }
}
