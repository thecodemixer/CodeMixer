import Foundation

/// Typed JSON Pointer string used as overlay / data-model path keys.
public struct A2UIJSONPointerPath: Sendable, Hashable, Codable, RawRepresentable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }
}

/// Closed literal JSON tree for overlays, resolved action context, and
/// data-model leaves. Domain stand-in for bare `JSONValue` at A2UI borders.
public enum A2UIResolvedValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([A2UIResolvedValue])
    case object([String: A2UIResolvedValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let json = try container.decode(JSONValue.self)
        self = A2UIResolvedValue(json: json)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }

    package init(json: JSONValue) {
        switch json {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .number(let value): self = .number(value)
        case .string(let value): self = .string(value)
        case .array(let values): self = .array(values.map { A2UIResolvedValue(json: $0) })
        case .object(let object):
            self = .object(object.mapValues { A2UIResolvedValue(json: $0) })
        }
    }

    package var jsonValue: JSONValue {
        switch self {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .number(let value): return .number(value)
        case .string(let value): return .string(value)
        case .array(let values): return .array(values.map(\.jsonValue))
        case .object(let object): return .object(object.mapValues(\.jsonValue))
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [A2UIResolvedValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: A2UIResolvedValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

/// Renderer-local, not-yet-synced path→value edits. Used by the SwiftUI
/// overlay state, `A2UIInteractionIntent`, and `A2UIEvaluator` so callers
/// never hand around a bare `[A2UIJSONPointerPath: A2UIResolvedValue]`.
///
/// Never persisted; discarded after the engine re-resolves an interaction.
public struct A2UILocalOverlay: Sendable, Hashable, Codable, ExpressibleByDictionaryLiteral {
    public static let empty = A2UILocalOverlay()

    private var values: [A2UIJSONPointerPath: A2UIResolvedValue]

    public init(_ values: [A2UIJSONPointerPath: A2UIResolvedValue] = [:]) {
        self.values = values
    }

    /// Convenience for tests and call sites that still hold raw pointer strings.
    public init(_ values: [String: A2UIResolvedValue]) {
        self.values = Dictionary(uniqueKeysWithValues: values.map { (A2UIJSONPointerPath($0.key), $0.value) })
    }

    public init(dictionaryLiteral elements: (String, A2UIResolvedValue)...) {
        values = Dictionary(uniqueKeysWithValues: elements.map { (A2UIJSONPointerPath($0.0), $0.1) })
    }

    public var isEmpty: Bool { values.isEmpty }

    public subscript(path: A2UIJSONPointerPath) -> A2UIResolvedValue? {
        get { values[path] }
        set { values[path] = newValue }
    }

    public subscript(path: String) -> A2UIResolvedValue? {
        get { values[A2UIJSONPointerPath(path)] }
        set { values[A2UIJSONPointerPath(path)] = newValue }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let object = try container.decode([String: A2UIResolvedValue].self)
        values = Dictionary(uniqueKeysWithValues: object.map { (A2UIJSONPointerPath($0.key), $0.value) })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }))
    }
}

/// Root data-model document for an A2UI surface. Wraps opaque JSON so callers
/// never hold a public `JSONValue`.
public struct A2UIDataDocument: Sendable, Hashable, Codable {
    private var storage: A2UIOpaqueJSON

    public static let empty = A2UIDataDocument(storage: .emptyObject)

    public init() {
        storage = .emptyObject
    }

    package init(storage: A2UIOpaqueJSON) {
        self.storage = storage
    }

    package init(json: JSONValue) {
        storage = A2UIOpaqueJSON(json)
    }

    package var json: JSONValue { storage.json }

    public var isEmptyObject: Bool {
        guard case .object(let object) = storage.json else { return false }
        return object.isEmpty
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        storage = try container.decode(A2UIOpaqueJSON.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storage)
    }
}
