import Foundation
import Testing
@testable import AgentProtocol

@Suite("JSONRPCFrameEncoding — dialect-specific frames")
struct JSONRPCFrameEncodingTests {
    @Test("app server request omits jsonrpc version")
    func appServerRequest() {
        let data = JSONRPCFrameEncoding.request(
            id: .number(1),
            method: "initialize",
            params: .object([:]),
            dialect: .appServer
        )

        #expect(String(decoding: data, as: UTF8.self) == #"{"id":1,"method":"initialize","params":{}}"# + "\n")
    }

    @Test("jsonrpc2 request includes jsonrpc version")
    func jsonrpc2Request() {
        let data = JSONRPCFrameEncoding.request(
            id: .number(1),
            method: "initialize",
            params: .object([:]),
            dialect: .jsonrpc2
        )

        #expect(String(decoding: data, as: UTF8.self) == #"{"id":1,"jsonrpc":"2.0","method":"initialize","params":{}}"# + "\n")
    }

    @Test("concatenate joins frames without changing bytes")
    func concatenate() {
        let joined = JSONRPCFrameEncoding.concatenate([
            Data("a\n".utf8),
            Data("b\n".utf8),
        ])
        #expect(String(decoding: joined, as: UTF8.self) == "a\nb\n")
    }
}
