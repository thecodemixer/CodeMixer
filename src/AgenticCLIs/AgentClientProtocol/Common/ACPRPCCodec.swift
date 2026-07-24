import Foundation
import AgentProtocol

/// Encodes and decodes ACP JSON-RPC 2.0 messages as JSONL frames.
public enum ACPRPCCodec {
    public static func request(id: JSONValue,
                               method: String,
                               params: JSONValue = .object([:])) -> Data {
        JSONRPCFrameEncoding.request(id: id,
                                     method: method,
                                     params: params,
                                     dialect: .jsonrpc2)
    }

    public static func notification(method: String,
                                    params: JSONValue? = nil) -> Data {
        JSONRPCFrameEncoding.notification(method: method,
                                          params: params,
                                          dialect: .jsonrpc2)
    }

    public static func response(id: JSONValue, result: JSONValue) -> Data {
        JSONRPCFrameEncoding.response(id: id,
                                      result: result,
                                      dialect: .jsonrpc2)
    }

    public static func errorResponse(id: JSONValue,
                                     code: Int,
                                     message: String) -> Data {
        JSONRPCFrameEncoding.errorResponse(id: id,
                                           code: code,
                                           message: message,
                                           dialect: .jsonrpc2)
    }

    public static func decode(_ frame: Data) throws -> ACPIncoming {
        try ACPIncoming.decode(frame)
    }

    public static func concatenate(_ frames: [Data]) -> Data {
        JSONRPCFrameEncoding.concatenate(frames)
    }
}
