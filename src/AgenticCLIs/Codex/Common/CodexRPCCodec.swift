import Foundation
import AgentProtocol

/// Encodes and decodes Codex App Server JSON-RPC messages as JSONL frames.
public enum CodexRPCCodec {
    public static func request(id: JSONValue,
                               method: String,
                               params: JSONValue = .object([:])) -> Data {
        JSONRPCFrameEncoding.request(id: id,
                                     method: method,
                                     params: params,
                                     dialect: .appServer)
    }

    public static func notification(method: String,
                                    params: JSONValue? = nil) -> Data {
        JSONRPCFrameEncoding.notification(method: method,
                                          params: params,
                                          dialect: .appServer)
    }

    public static func response(id: JSONValue, result: JSONValue) -> Data {
        JSONRPCFrameEncoding.response(id: id,
                                      result: result,
                                      dialect: .appServer)
    }

    public static func errorResponse(id: JSONValue,
                                     code: Int,
                                     message: String) -> Data {
        JSONRPCFrameEncoding.errorResponse(id: id,
                                           code: code,
                                           message: message,
                                           dialect: .appServer)
    }

    public static func decode(_ frame: Data) throws -> CodexAppServerIncoming {
        try CodexAppServerIncoming.decode(frame)
    }

    public static func concatenate(_ frames: [Data]) -> Data {
        JSONRPCFrameEncoding.concatenate(frames)
    }
}
