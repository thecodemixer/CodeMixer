import Foundation
import Security

/// Source of randomness. Injected so tests can pin sequences.
public protocol RandomSource: Sendable {
    /// Generate a fresh UUID v4. Cryptographically random in production.
    func uuid() -> UUID

    /// Fill a buffer with cryptographically secure random bytes.
    func bytes(_ count: Int) -> Data

    /// Generate a numeric PIN of the given digit count, zero-padded.
    func pin(digits: Int) -> String
}

/// Production implementation backed by `SecRandomCopyBytes`.
public struct SystemRandomSource: RandomSource {
    public init() {}

    public func uuid() -> UUID { UUID() }

    public func bytes(_ count: Int) -> Data {
        precondition(count > 0, "byte count must be positive")
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        precondition(result == errSecSuccess, "SecRandomCopyBytes failed: \(result)")
        return data
    }

    public func pin(digits: Int) -> String {
        precondition(digits > 0 && digits <= 18, "pin digits out of range")
        var rng = SystemRandomNumberGenerator()
        let upper: UInt64 = (0..<digits).reduce(1) { acc, _ in acc * 10 }
        let value = UInt64.random(in: 0..<upper, using: &rng)
        return String(format: "%0\(digits)llu", value)
    }
}
