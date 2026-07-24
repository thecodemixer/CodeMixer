@testable import AgentClientProtocol
import Foundation
import Testing

@Suite("ACP protocol framing and codec")
struct ACPProtocolTests {

    @Test("framing splits CRLF-delimited frames")
    func framingCRLF() throws {
        var framing = ACPFraming()
        let frames = try framing.append(Data("{\"a\":1}\r\n{\"b\":2}\r\n".utf8))
        #expect(frames.count == 2)
        #expect(String(decoding: frames[0], as: UTF8.self).contains("\"a\":1"))
    }

    @Test("framing buffers partial frames across append calls")
    func framingPartial() throws {
        var framing = ACPFraming()
        let first = try framing.append(Data("{\"part".utf8))
        #expect(first.isEmpty)
        let second = try framing.append(Data("ial\":1}\n".utf8))
        #expect(second.count == 1)
    }

    @Test("framing rejects oversized unterminated frames")
    func framingTooLarge() {
        var framing = ACPFraming()
        let oversized = Data(repeating: 0x41, count: ACPFraming.maximumFrameBytes + 1)
        #expect(throws: ACPAgentError.self) {
            _ = try framing.append(oversized)
        }
    }

    @Test("ACPFraming.frame appends newline delimiter")
    func framingFrame() {
        let framed = ACPFraming.frame(Data("{\"x\":1}".utf8))
        #expect(framed.last == 0x0A)
    }

    @Test("RPC codec round-trips request notification and response")
    func rpcCodecRoundTrip() throws {
        let request = ACPRPCCodec.request(
            id: .number(7),
            method: "session/new",
            params: .object(["cwd": .string("/tmp")])
        )
        let notification = ACPRPCCodec.notification(method: "initialized")
        let response = ACPRPCCodec.response(id: .number(7), result: .object([:]))

        let decodedRequest = try ACPRPCCodec.decode(request)
        if case .serverRequest(let id, let method, _) = decodedRequest {
            #expect(id == .number(7))
            #expect(method == "session/new")
        } else {
            Issue.record("expected server request")
        }

        let decodedNotification = try ACPRPCCodec.decode(notification)
        if case .notification(let method, _) = decodedNotification {
            #expect(method == "initialized")
        } else {
            Issue.record("expected notification")
        }

        let decodedResponse = try ACPRPCCodec.decode(response)
        if case .response(let id, _, let error) = decodedResponse {
            #expect(id == .number(7))
            #expect(error == nil)
        } else {
            Issue.record("expected response")
        }
    }

    @Test("ACPIncoming decodes RPC error payloads")
    func incomingRPCError() throws {
        let frame = Data("""
        {"jsonrpc":"2.0","id":3,"error":{"code":-32000,"message":"nope","data":{"reason":"x"}}}
        """.utf8)
        let incoming = try ACPIncoming.decode(frame)
        if case .response(let id, _, let error) = incoming {
            #expect(id == .number(3))
            #expect(error?.code == -32_000)
            #expect(error?.message == "nope")
            #expect(error?.data?["reason"]?.stringValue == "x")
        } else {
            Issue.record("expected error response")
        }
    }

    @Test("ACPIncoming rejects malformed frames")
    func incomingMalformed() {
        #expect(throws: ACPAgentError.self) {
            _ = try ACPIncoming.decode(Data("not-json".utf8))
        }
        #expect(throws: ACPAgentError.self) {
            _ = try ACPIncoming.decode(Data("[]".utf8))
        }
        #expect(throws: ACPAgentError.self) {
            _ = try ACPIncoming.decode(Data("{\"jsonrpc\":\"2.0\"}".utf8))
        }
    }

    @Test("ACPRPCCodec.concatenate joins frames")
    func concatenate() {
        let joined = ACPRPCCodec.concatenate([
            Data("a\n".utf8),
            Data("b\n".utf8),
        ])
        #expect(String(decoding: joined, as: UTF8.self) == "a\nb\n")
    }

    @Test("ACPSessionModes parses advertised modes")
    func sessionModes() {
        let modes = ACPSessionModes.parse(.object([
            "currentModeId": .string("plan"),
            "availableModes": .array([
                .object([
                    "id": .string("agent"),
                    "name": .string(""),
                ]),
                .object([
                    "id": .string("plan"),
                    "name": .string("Plan"),
                    "description": .string("Read-only"),
                ]),
                .object(["id": .string("")]),
            ]),
        ]))

        #expect(modes.currentModeID == "plan")
        #expect(modes.available == [
            ACPSessionMode(id: "agent", name: "agent", description: nil),
            ACPSessionMode(id: "plan", name: "Plan", description: "Read-only"),
        ])
    }

    @Test("ACPInitializeResult parses dashboard metadata and auth method")
    func initializeResult() {
        let parsed = ACPInitializeResult.parse(.object([
            "agentInfo": .object([
                "_meta": .object([
                    "codemixer.dev/dashboardUrl": .string("http://127.0.0.1:8423/dashboard"),
                    "codemixer.dev/dashboardTitle": .string("Dashboard"),
                ]),
            ]),
            "authMethods": .array([
                .object(["id": .string("device")]),
            ]),
        ]))

        #expect(parsed.dashboardURL?.absoluteString == "http://127.0.0.1:8423/dashboard")
        #expect(parsed.dashboardTitle == "Dashboard")
        #expect(parsed.authMethodID == "device")
    }
}
