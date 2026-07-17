import Foundation

/// One decoded message received from Codex App Server.
///
/// Codex uses JSON-RPC's request/response shape over JSONL but omits the
/// optional `"jsonrpc": "2.0"` member. Presence of `method` and `id`
/// distinguishes server requests from notifications.
public enum CodexAppServerIncoming: Sendable, Hashable {
    case response(id: JSONValue, result: JSONValue?, error: RPCError?)
    case notification(method: String, params: JSONValue)
    case serverRequest(id: JSONValue, method: String, params: JSONValue)

    public struct RPCError: Sendable, Hashable {
        public let code: Int
        public let message: String
        public let data: JSONValue?

        public init(code: Int, message: String, data: JSONValue? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }
    }

    public static func decode(_ data: Data) throws -> CodexAppServerIncoming {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw CodexAgentError.malformedFrame(detail: error.localizedDescription)
        }
        guard let object = root.objectValue else {
            throw CodexAgentError.malformedMessage(detail: "root is not an object")
        }

        let method = object["method"]?.stringValue
        let id = object["id"]
        let params = object["params"] ?? .object([:])

        if let method, let id {
            return .serverRequest(id: id, method: method, params: params)
        }
        if let method {
            return .notification(method: method, params: params)
        }
        if let id {
            return .response(
                id: id,
                result: object["result"],
                error: try rpcError(from: object["error"])
            )
        }
        throw CodexAgentError.malformedMessage(detail: "missing method and id")
    }

    private static func rpcError(from value: JSONValue?) throws -> RPCError? {
        guard let value, value != .null else { return nil }
        guard let object = value.objectValue,
              let code = object["code"]?.numberValue,
              let message = object["message"]?.stringValue else {
            throw CodexAgentError.malformedMessage(detail: "invalid RPC error")
        }
        return RPCError(code: Int(code), message: message, data: object["data"])
    }
}
