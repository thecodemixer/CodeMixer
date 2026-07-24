import Foundation

/// JSON-RPC frame construction shared by stdio agent adapters.
public enum JSONRPCDialect: Sendable, Hashable {
    case appServer
    case jsonrpc2
}

public enum JSONRPCFrameEncoding {
    public static func request(id: JSONValue,
                               method: String,
                               params: JSONValue = .object([:]),
                               dialect: JSONRPCDialect) -> Data {
        encode(dialect: dialect, fields: [
            "id": id,
            "method": .string(method),
            "params": params,
        ])
    }

    public static func notification(method: String,
                                    params: JSONValue? = nil,
                                    dialect: JSONRPCDialect) -> Data {
        var object = ["method": JSONValue.string(method)]
        if let params {
            object["params"] = params
        }
        return encode(dialect: dialect, fields: object)
    }

    public static func response(id: JSONValue,
                                result: JSONValue,
                                dialect: JSONRPCDialect) -> Data {
        encode(dialect: dialect, fields: [
            "id": id,
            "result": result,
        ])
    }

    public static func errorResponse(id: JSONValue,
                                     code: Int,
                                     message: String,
                                     dialect: JSONRPCDialect) -> Data {
        encode(dialect: dialect, fields: [
            "id": id,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ])
    }

    public static func concatenate(_ frames: [Data]) -> Data {
        frames.reduce(into: Data()) { result, frame in
            result.append(frame)
        }
    }

    private static func encode(dialect: JSONRPCDialect,
                               fields: [String: JSONValue]) -> Data {
        var object = fields
        if dialect == .jsonrpc2 {
            object["jsonrpc"] = .string("2.0")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let payload = try? encoder.encode(JSONValue.object(object)) else {
            return Data()
        }
        return JSONLFraming.frame(payload)
    }
}
