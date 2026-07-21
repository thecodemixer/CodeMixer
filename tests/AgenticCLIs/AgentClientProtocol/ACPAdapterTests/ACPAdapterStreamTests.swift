@testable import AgentClientProtocol
import AgentCore
import AgentProtocol
import AgentTestSupport
import Foundation
import Testing

@Suite("ACP adapter event stream")
struct ACPAdapterStreamTests {

    @Test("event stream decodes agent bytes and writes protocol replies")
    func streamRoundTrip() async throws {
        let adapter = acpAdapter()
        let workspace = TestPaths.underTemporary("acp-ws")
        let (outputBytes, outputContinuation) = AsyncStream<Data>.makeStream()
        let written = WrittenBytesCollector()
        let inputs = AgentInputs(
            outputBytes: outputBytes,
            writeBytes: { await written.append($0) },
            terminal: nil,
            hookSocket: nil,
            workspace: workspace,
            sessionID: AsyncStream { $0.finish() }
        )
        _ = adapter.sessionBootstrapBytes(context: LaunchContext(
            workspace: workspace,
            permissionMode: .default
        ))

        let stream = adapter.makeEventStream(inputs: inputs)
        let consumer = Task {
            var events: [AgentEvent] = []
            for await event in stream {
                events.append(event)
            }
            return events
        }

        outputContinuation.yield(encodeResponse(
            id: 1,
            result: [
                "protocolVersion": 1,
                "agentCapabilities": [:] as [String: Any],
                "authMethods": [] as [Any],
            ]
        ))
        outputContinuation.yield(encodeResponse(
            id: 2,
            result: ["sessionId": "stream-session"]
        ))
        outputContinuation.yield(encodeNotification(
            method: "session/update",
            params: [
                "update": [
                    "sessionUpdate": "agent_message_chunk",
                    "content": ["text": "hello"],
                ],
            ]
        ))
        outputContinuation.finish()

        let events = await consumer.value
        #expect(events.contains {
            if case .sessionStarted(let id, _, _) = $0 { return id == "stream-session" }
            return false
        })
        #expect(events.contains {
            if case .assistantText(_, _, let text, false) = $0 { return text == "hello" }
            return false
        })

        let outbound = await written.snapshot()
        let joined = outbound.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(joined.contains("initialized"))
        #expect(joined.contains("session/new"))
    }

    @Test("event stream surfaces malformed frame as AgentEvent error")
    func streamMalformedFrame() async {
        let adapter = acpAdapter()
        let workspace = TestPaths.underTemporary("acp-ws")
        let (outputBytes, outputContinuation) = AsyncStream<Data>.makeStream()
        let inputs = AgentInputs(
            outputBytes: outputBytes,
            terminal: nil,
            hookSocket: nil,
            workspace: workspace,
            sessionID: AsyncStream { $0.finish() }
        )
        let stream = adapter.makeEventStream(inputs: inputs)
        let consumer = Task {
            var events: [AgentEvent] = []
            for await event in stream {
                events.append(event)
            }
            return events
        }
        outputContinuation.yield(Data("not-json\n".utf8))
        outputContinuation.finish()
        let events = await consumer.value
        #expect(events.contains {
            if case .error(.unsupportedOperation(let detail)) = $0 {
                return detail.contains("malformed")
            }
            return false
        })
    }

    @Test("event stream reports write failure when reply write throws")
    func streamWriteFailure() async {
        let adapter = acpAdapter()
        let workspace = TestPaths.underTemporary("acp-ws")
        let (outputBytes, outputContinuation) = AsyncStream<Data>.makeStream()
        let inputs = AgentInputs(
            outputBytes: outputBytes,
            writeBytes: { _ in throw AgentError.unsupportedOperation(detail: "write-failed") },
            terminal: nil,
            hookSocket: nil,
            workspace: workspace,
            sessionID: AsyncStream { $0.finish() }
        )
        _ = adapter.sessionBootstrapBytes(context: LaunchContext(workspace: workspace, permissionMode: .default))
        let stream = adapter.makeEventStream(inputs: inputs)
        let consumer = Task {
            var events: [AgentEvent] = []
            for await event in stream {
                events.append(event)
            }
            return events
        }
        outputContinuation.yield(encodeResponse(
            id: 1,
            result: [
                "protocolVersion": 1,
                "agentCapabilities": [:] as [String: Any],
                "authMethods": [] as [Any],
            ]
        ))
        outputContinuation.finish()
        let events = await consumer.value
        #expect(events.contains {
            if case .error(.unsupportedOperation(let detail)) = $0 {
                return detail.contains("reply-write")
            }
            return false
        })
    }

    @Test("event stream surfaces permission prompts from server requests")
    func streamPermissionPrompt() async {
        let adapter = acpAdapter()
        let workspace = TestPaths.underTemporary("acp-ws")
        let (outputBytes, outputContinuation) = AsyncStream<Data>.makeStream()
        let inputs = AgentInputs(
            outputBytes: outputBytes,
            writeBytes: { _ in },
            terminal: nil,
            hookSocket: nil,
            workspace: workspace,
            sessionID: AsyncStream { $0.finish() }
        )
        let stream = adapter.makeEventStream(inputs: inputs)
        let consumer = Task {
            var events: [AgentEvent] = []
            for await event in stream {
                events.append(event)
            }
            return events
        }

        outputContinuation.yield(encodeServerRequest(
            id: 99,
            method: "session/request_permission",
            params: [
                "options": [
                    ["kind": "allow_once", "optionId": "allow"],
                ],
                "toolCall": ["title": "Shell"],
            ]
        ))
        outputContinuation.finish()

        let events = await consumer.value
        #expect(events.contains {
            if case .permissionRequest(let prompt) = $0 { return prompt.toolName == "Shell" }
            return false
        })
    }

    private func encodeResponse(id: Int, result: [String: Any]) -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        return ACPFraming.frame(jsonData(payload))
    }

    private func encodeNotification(method: String, params: [String: Any]) -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ]
        return ACPFraming.frame(jsonData(payload))
    }

    private func encodeServerRequest(id: Int, method: String, params: [String: Any]) -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        return ACPFraming.frame(jsonData(payload))
    }

    private func jsonData(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

private actor WrittenBytesCollector {
    private var chunks: [Data] = []

    func append(_ data: Data) {
        chunks.append(data)
    }

    func snapshot() -> [Data] { chunks }
}
