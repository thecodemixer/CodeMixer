import Foundation

/// Deterministic ID allocation for twin scenarios and tests.
public enum ClaudeCodeTwinIdentifiers: Sendable {
    public static func sessionID(seed: String = "twin-session") -> String {
        deterministicUUID(prefix: "sess", seed: seed)
    }

    public static func toolUseID(index: Int) -> String {
        "toolu_\(String(format: "%04d", index))"
    }

    public static func recordUUID(index: Int) -> String {
        deterministicUUID(prefix: "rec", seed: "record-\(index)")
    }

    private static func deterministicUUID(prefix: String, seed: String) -> String {
        var hasher = Hasher()
        hasher.combine(seed)
        let hash = abs(hasher.finalize())
        return "\(prefix)-\(String(format: "%012x", hash).prefix(12))"
    }
}
