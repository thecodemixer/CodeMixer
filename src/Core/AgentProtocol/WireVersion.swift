import Foundation

/// Wire-protocol version carried on every frame.
///
/// Bumped only for breaking changes. Additive changes (new optional fields,
/// new enum cases gated by `unknown` decoding) keep the same major version.
public enum WireVersion: Int, Sendable, Codable {
    case v1 = 1

    public static let current: WireVersion = .v1
}
