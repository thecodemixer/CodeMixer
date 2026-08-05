import Foundation

/// Opaque JSON document fragment used only where A2UI must preserve
/// open-ended or unknown wire bytes without exposing `JSONValue` on the
/// public API. Codable round-trips the raw value; there is no public
/// `JSONValue` accessor.
public struct A2UIOpaqueJSON: Sendable, Hashable, Codable {
    package let json: JSONValue

    package init(_ json: JSONValue) {
        self.json = json
    }

    public static let emptyObject = A2UIOpaqueJSON(.object([:]))

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        json = try container.decode(JSONValue.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(json)
    }
}

/// Unknown-catalog / unknown-kind component payload retained for lossless
/// replay. Public consumers only see the wire kind name.
public struct A2UIOpaqueComponent: Sendable, Hashable, Codable {
    public let kindName: String
    package let raw: A2UIOpaqueJSON

    package init(kindName: String, raw: A2UIOpaqueJSON) {
        self.kindName = kindName
        self.raw = raw
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(JSONValue.self)
        guard case .object(let object) = value,
              let kindName = object["component"]?.stringValue else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "A2UIOpaqueComponent requires object with 'component'")
        }
        self.kindName = kindName
        raw = A2UIOpaqueJSON(value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw.json)
    }
}
