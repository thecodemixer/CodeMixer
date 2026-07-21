import Foundation

/// Identifier for an appearance preference.
///
/// Storing the key separately from the value lets a remote client patch a
/// single preference without resending the entire prefs blob.
public enum AppearancePrefKey: String, Sendable, Codable, Hashable {
    case theme
    case codeTheme
    case fontFamily
    case floatingCornerStyle
    case fontSizeScale
    case showUsageChip
    case reduceMotion
    case densityMode
    case sidebarVisible
    case showSilentRecoveryLog
}

/// Tagged-union of permissible appearance values.
///
/// Sum type rather than `Any` so the wire stays strongly typed.
public enum AppearancePrefValue: Sendable, Codable, Hashable {
    case string(String)
    case double(Double)
    case bool(Bool)

    private enum CodingKeys: String, CodingKey { case kind, value }
    private enum Kind: String, Codable { case string, double, bool }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        case .double: self = .double(try container.decode(Double.self, forKey: .value))
        case .bool:   self = .bool(try container.decode(Bool.self,   forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let v): try container.encode(Kind.string, forKey: .kind); try container.encode(v, forKey: .value)
        case .double(let v): try container.encode(Kind.double, forKey: .kind); try container.encode(v, forKey: .value)
        case .bool(let v):   try container.encode(Kind.bool,   forKey: .kind); try container.encode(v, forKey: .value)
        }
    }
}

/// Single auto-approval rule for tool permissions.
///
/// `match` is a glob-style pattern over the canonical tool-name + argument
/// summary string. Engine-side compilation is the source of truth; the wire
/// only carries the rule itself.
public struct AutoApprovalRule: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public var enabled: Bool
    public var match: String
    public var decision: PermissionDecision
    public var note: String

    public init(id: UUID,
                enabled: Bool = true,
                match: String,
                decision: PermissionDecision,
                note: String = "") {
        self.id = id
        self.enabled = enabled
        self.match = match
        self.decision = decision
        self.note = note
    }

    public init(enabled: Bool = true,
                match: String,
                decision: PermissionDecision,
                note: String = "") {
        self.init(id: AutoApprovalRuleID.stable(
            enabled: enabled,
            match: match,
            decision: decision,
            note: note
        ),
        enabled: enabled,
        match: match,
        decision: decision,
        note: note)
    }
}

/// What a remote client is asking for via `requestSnapshot`.
public enum SnapshotKind: String, Sendable, Codable, Hashable {
    case conversation
    case diff
    case sessions
    case prefs
}

private enum AutoApprovalRuleID {
    private static let offset: UInt64 = 0xcbf29ce484222325
    private static let alternateOffset: UInt64 = 0x84222325cbf29ce4
    private static let prime: UInt64 = 0x100000001b3

    static func stable(enabled: Bool,
                       match: String,
                       decision: PermissionDecision,
                       note: String) -> UUID {
        uuid(for: "\(enabled)|\(match)|\(decision.wireValue)|\(note)")
    }

    private static func uuid(for material: String) -> UUID {
        var first = offset
        var second = alternateOffset
        for byte in material.utf8 {
            mix(&first, byte: byte)
            mix(&second, byte: byte &+ 31)
        }
        return UUID(uuid: (
            byte(first, 56), byte(first, 48), byte(first, 40), byte(first, 32),
            byte(first, 24), byte(first, 16), byte(first, 8), byte(first, 0),
            byte(second, 56), byte(second, 48), byte(second, 40), byte(second, 32),
            byte(second, 24), byte(second, 16), byte(second, 8), byte(second, 0)
        ))
    }

    private static func mix(_ hash: inout UInt64, byte: UInt8) {
        hash ^= UInt64(byte)
        hash &*= prime
    }

    private static func byte(_ value: UInt64, _ shift: UInt64) -> UInt8 {
        UInt8((value >> shift) & 0xff)
    }
}
