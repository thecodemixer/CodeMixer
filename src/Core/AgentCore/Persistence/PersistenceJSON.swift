import Foundation

/// Shared JSON encoder/decoder construction for persistence stores.
enum PersistenceJSON {
    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data,
        dateDecodingStrategy: JSONDecoder.DateDecodingStrategy? = nil
    ) throws -> Value {
        let decoder = JSONDecoder()
        if let dateDecodingStrategy {
            decoder.dateDecodingStrategy = dateDecodingStrategy
        }
        return try decoder.decode(type, from: data)
    }

    static func encode<Value: Encodable>(
        _ value: Value,
        dateEncodingStrategy: JSONEncoder.DateEncodingStrategy? = nil,
        withoutEscapingSlashes: Bool = false
    ) throws -> Data {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.prettyPrinted, .sortedKeys]
        if withoutEscapingSlashes {
            formatting.insert(.withoutEscapingSlashes)
        }
        encoder.outputFormatting = formatting
        if let dateEncodingStrategy {
            encoder.dateEncodingStrategy = dateEncodingStrategy
        }
        return try encoder.encode(value)
    }

    static func schemaVersion(in data: Data) throws -> Int {
        try decode(SchemaProbe.self, from: data).schemaVersion
    }

    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }
}
