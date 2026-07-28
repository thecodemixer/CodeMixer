import Foundation

/// Wire-protocol version carried on every frame.
///
/// Bump `current` whenever a breaking wire change ships (removed fields, renamed
/// tags, stricter decoding). Clients and servers must agree on the version —
/// mismatches are rejected with `ServerFrame.versionMismatch`; there is no
/// dual-speak or `unknown`-case fallback decoding across versions.
public enum WireVersion: Int, Sendable, Codable {
    case v1 = 1
    case v2 = 2
    case v3 = 3

    public static let current: WireVersion = .v3
}
