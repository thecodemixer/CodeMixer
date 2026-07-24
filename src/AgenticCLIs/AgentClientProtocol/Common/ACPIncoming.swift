import Foundation
import AgentProtocol

/// One decoded message received from an ACP agent over stdio.
///
/// ACP requires `"jsonrpc":"2.0"`. Presence of `method` and `id` distinguishes
/// server requests from notifications. A `method` with null/missing `id` is a
/// notification (lenient for noisy agent implementations).
public enum ACPIncoming: Sendable, Hashable {
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

    public static func decode(_ data: Data) throws -> ACPIncoming {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ACPAgentError.malformedFrame(detail: error.localizedDescription)
        }
        guard let object = root.objectValue else {
            throw ACPAgentError.malformedMessage(detail: "root is not an object")
        }

        let method = object["method"]?.stringValue
        let id = object["id"]
        let params = object["params"] ?? .object([:])

        if let method {
            if let id, id != .null {
                return .serverRequest(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }
        if let id, id != .null {
            return .response(
                id: id,
                result: object["result"],
                error: try rpcError(from: object["error"])
            )
        }
        throw ACPAgentError.malformedMessage(detail: "missing method and id")
    }

    private static func rpcError(from value: JSONValue?) throws -> RPCError? {
        guard let value, value != .null else { return nil }
        guard let object = value.objectValue,
              let code = object["code"]?.numberValue,
              let message = object["message"]?.stringValue else {
            throw ACPAgentError.malformedMessage(detail: "invalid RPC error")
        }
        return RPCError(code: Int(code), message: message, data: object["data"])
    }
}
