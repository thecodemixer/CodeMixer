import Foundation

/// Encodes and decodes ACP JSON-RPC 2.0 messages as JSONL frames.
public enum ACPRPCCodec {
    public static func request(id: JSONValue,
                               method: String,
                               params: JSONValue = .object([:])) -> Data {
        encode([
            "jsonrpc": .string("2.0"),
            "id": id,
            "method": .string(method),
            "params": params,
        ])
    }

    public static func notification(method: String,
                                    params: JSONValue? = nil) -> Data {
        var object: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params {
            object["params"] = params
        }
        return encode(object)
    }

    public static func response(id: JSONValue, result: JSONValue) -> Data {
        encode([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": result,
        ])
    }

    public static func errorResponse(id: JSONValue,
                                     code: Int,
                                     message: String) -> Data {
        encode([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ])
    }

    public static func decode(_ frame: Data) throws -> ACPIncoming {
        try ACPIncoming.decode(frame)
    }

    public static func concatenate(_ frames: [Data]) -> Data {
        frames.reduce(into: Data()) { result, frame in
            result.append(frame)
        }
    }

    private static func encode(_ object: [String: JSONValue]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let payload = try? encoder.encode(JSONValue.object(object)) else {
            return Data()
        }
        return ACPFraming.frame(payload)
    }
}
