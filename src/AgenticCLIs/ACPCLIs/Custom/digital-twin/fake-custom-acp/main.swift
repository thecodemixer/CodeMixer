import Foundation
import AgentClientProtocol

/// Stdio ACP twin for Custom ACP integration tests (project-tool flavored modes).
///
/// Modes are intentionally not Cursor's agent/plan/ask — they prove
/// `CustomACPAdapter` maps whatever `session/new` advertises.
@main
struct FakeCustomACPCLI {
    static func main() {
        setbuf(stdout, nil)
        let env = ProcessInfo.processInfo.environment
        let scenario = ACPTwinScenario.from(environment: env)
        var server = FakeCustomACPServer(scenario: scenario)
        while let line = readLine() {
            guard !line.isEmpty else { continue }
            var frame = Data(line.utf8)
            if frame.last == 0x0D { frame.removeLast() }
            do {
                let incoming = try ACPIncoming.decode(frame)
                let replies = server.handle(incoming)
                for reply in replies {
                    writeFrame(reply)
                }
            } catch {
                writeFrame(ACPRPCCodec.errorResponse(
                    id: .number(-1),
                    code: -32_600,
                    message: String(describing: error)
                ))
            }
        }
    }

    private static func writeFrame(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(STDOUT_FILENO, base, raw.count)
        }
    }
}

private struct FakeCustomACPServer {
    static let defaultReply = "Hello from fake-custom-acp."

    let scenario: ACPTwinScenario
    var authenticated = false
    var sessionID = UUID().uuidString
    var workspacePath: String?
    var pendingPromptID: JSONValue?
    var currentModeID = "migrate"

    init(scenario: ACPTwinScenario) {
        self.scenario = scenario
        switch scenario {
        case .auth, .authFail:
            authenticated = false
        case .text, .permission, .fsRead, .resume:
            authenticated = true
        }
    }

    mutating func handle(_ incoming: ACPIncoming) -> [Data] {
        switch incoming {
        case .serverRequest(let id, let method, let params):
            return handleClientRequest(id: id, method: method, params: params)
        case .response(let id, let result, let error):
            return handleClientResponse(id: id, result: result, error: error)
        case .notification:
            return []
        }
    }

    private mutating func handleClientRequest(id: JSONValue,
                                              method: String,
                                              params: JSONValue) -> [Data] {
        switch method {
        case "initialize":
            return handleInitialize(id: id)
        case "authenticate":
            if scenario == .authFail {
                return [ACPRPCCodec.errorResponse(
                    id: id,
                    code: -32_000,
                    message: "Authentication required"
                )]
            }
            authenticated = true
            return [ACPRPCCodec.response(id: id, result: .object([:]))]
        case "session/new":
            workspacePath = params["cwd"]?.stringValue
            sessionID = UUID().uuidString
            currentModeID = "migrate"
            return [ACPRPCCodec.response(
                id: id,
                result: .object([
                    "sessionId": .string(sessionID),
                    "modes": modesPayload(),
                    "models": modelsPayload(),
                ])
            )]
        case "session/load", "session/resume":
            workspacePath = params["cwd"]?.stringValue
            if let resume = params["sessionId"]?.stringValue {
                sessionID = resume
            }
            return [ACPRPCCodec.response(id: id, result: .object([
                "modes": modesPayload(),
                "models": modelsPayload(),
            ]))]
        case "session/set_mode":
            if let mode = params["modeId"]?.stringValue {
                currentModeID = mode
            }
            return [
                ACPRPCCodec.notification(
                    method: "session/update",
                    params: .object([
                        "sessionId": .string(sessionID),
                        "update": .object([
                            "sessionUpdate": .string("current_mode_update"),
                            "currentModeId": .string(currentModeID),
                        ]),
                    ])
                ),
                ACPRPCCodec.response(id: id, result: .object([:])),
            ]
        case "session/list":
            return [ACPRPCCodec.response(
                id: id,
                result: .object(["sessions": .array([])])
            )]
        case "session/prompt":
            pendingPromptID = id
            switch scenario {
            case .permission:
                return [permissionRequest(id: .number(9001))]
            case .fsRead:
                let path = (workspacePath ?? "/tmp").appending("/probe.txt")
                return [ACPRPCCodec.request(
                    id: .number(9002),
                    method: "fs/read_text_file",
                    params: .object(["path": .string(path)])
                )]
            case .text, .auth, .authFail, .resume:
                return completePrompt(reply: Self.defaultReply)
            }
        default:
            return [ACPRPCCodec.errorResponse(id: id, code: -32601, message: "unsupported method")]
        }
    }

    private mutating func handleClientResponse(id: JSONValue,
                                               result: JSONValue?,
                                               error: ACPIncoming.RPCError?) -> [Data] {
        guard error == nil else { return [] }
        if id == .number(9001) {
            return completePrompt(reply: Self.defaultReply)
        }
        if id == .number(9002) {
            let content = result?["content"]?.stringValue ?? ""
            return completePrompt(reply: "fs:\(content)")
        }
        return []
    }

    private func modesPayload() -> JSONValue {
        .object([
            "currentModeId": .string(currentModeID),
            "availableModes": .array([
                .object([
                    "id": .string("migrate"),
                    "name": .string("Migrate"),
                    "description": .string("Run schema and data migrations"),
                ]),
                .object([
                    "id": .string("document"),
                    "name": .string("Document"),
                    "description": .string("Generate and refresh project docs"),
                ]),
                .object([
                    "id": .string("agent"),
                    "name": .string("Agent"),
                    "description": .string("General project assistant"),
                ]),
            ]),
        ])
    }

    private func modelsPayload() -> JSONValue {
        .object([
            "currentModelId": .string("custom-auto"),
            "availableModels": .array([
                .object([
                    "modelId": .string("custom-auto"),
                    "name": .string("Custom Auto"),
                ]),
            ]),
        ])
    }

    private mutating func handleInitialize(id: JSONValue) -> [Data] {
        var result: [String: JSONValue] = [
            "protocolVersion": .number(1),
            "agentCapabilities": .object([
                "loadSession": .bool(true),
                "sessionCapabilities": .object([
                    "list": .object([:]),
                    "resume": .object([:]),
                ]),
            ]),
            "agentInfo": .object([
                "name": .string("fake-custom-acp"),
                "title": .string("Fake Custom ACP"),
            ]),
        ]
        if scenario == .auth || scenario == .authFail, !authenticated {
            result["authMethods"] = .array([
                .object([
                    "id": .string("twin_login"),
                    "name": .string("Twin Login"),
                ]),
            ])
        } else {
            result["authMethods"] = .array([])
        }
        return [ACPRPCCodec.response(id: id, result: .object(result))]
    }

    private func permissionRequest(id: JSONValue) -> Data {
        ACPRPCCodec.request(
            id: id,
            method: "session/request_permission",
            params: .object([
                "options": .array([
                    .object(["kind": .string("allow_once"), "optionId": .string("allow-once")]),
                    .object(["kind": .string("reject_once"), "optionId": .string("reject-once")]),
                ]),
                "toolCall": .object([
                    "title": .string("Shell"),
                    "kind": .string("execute"),
                ]),
            ])
        )
    }

    private mutating func completePrompt(reply: String) -> [Data] {
        guard let promptID = pendingPromptID else { return [] }
        pendingPromptID = nil
        return [
            sessionUpdate(
                kind: "agent_message_chunk",
                content: .object(["type": .string("text"), "text": .string(reply)])
            ),
            ACPRPCCodec.response(
                id: promptID,
                result: .object(["stopReason": .string("end_turn")])
            ),
        ]
    }

    private func sessionUpdate(kind: String, content: JSONValue) -> Data {
        ACPRPCCodec.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string(sessionID),
                "update": .object([
                    "sessionUpdate": .string(kind),
                    "content": content,
                ]),
            ])
        )
    }
}
