import Foundation

/// Encodes and decodes Codex App Server JSON-RPC messages as JSONL frames.
public enum CodexRPCCodec {
    public static func request(id: JSONValue,
                               method: String,
                               params: JSONValue = .object([:])) -> Data {
        encode([
            "id": id,
            "method": .string(method),
            "params": params,
        ])
    }

    public static func notification(method: String,
                                    params: JSONValue? = nil) -> Data {
        var object = ["method": JSONValue.string(method)]
        if let params {
            object["params"] = params
        }
        return encode(object)
    }

    public static func response(id: JSONValue, result: JSONValue) -> Data {
        encode([
            "id": id,
            "result": result,
        ])
    }

    public static func errorResponse(id: JSONValue,
                                     code: Int,
                                     message: String) -> Data {
        encode([
            "id": id,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ])
    }

    public static func decode(_ frame: Data) throws -> CodexAppServerIncoming {
        try CodexAppServerIncoming.decode(frame)
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
        return CodexAppServerFraming.frame(payload)
    }
}
