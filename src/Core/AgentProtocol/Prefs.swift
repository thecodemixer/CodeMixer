import Foundation

/// Identifier for an appearance preference.
///
/// Storing the key separately from the value lets a remote client patch a
/// single preference without resending the entire prefs blob.
public enum AppearancePrefKey: String, Sendable, Codable, Hashable {
    case theme
    case codeTheme
    case fontSizeScale
    case showUsageChip
    case reduceMotion
    case densityMode
    case sidebarVisible
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

    public init(id: UUID = UUID(),
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
}

/// What a remote client is asking for via `requestSnapshot`.
public enum SnapshotKind: String, Sendable, Codable, Hashable {
    case conversation
    case diff
    case sessions
    case workspaceTree
    case prefs
}
