import Foundation
import AgentClientProtocol
import AgentProtocol

/// Stdio ACP agent-server twin for CI and local development without a real backend.
@main
struct FakeACPCLI {
    static func main() {
        let env = ProcessInfo.processInfo.environment
        let scenario = ACPTwinScenario.from(environment: env)
        var server = FakeACPServer(scenario: scenario)
        runACPTwinStdioLoop(&server)
    }
}

private struct FakeACPServer: ACPTwinServer {
    let scenario: ACPTwinScenario
    var authenticated = false
    var sessionID = UUID().uuidString
    var workspacePath: String?
    var pendingPromptID: JSONValue?
    var pendingReplyPrefix = ""
    var currentModeID = "agent"

    init(scenario: ACPTwinScenario) {
        self.scenario = scenario
        authenticated = scenario.isPreAuthenticated
    }

    mutating func handle(_ incoming: ACPIncoming) -> [Data] {
        switch incoming {
        case .serverRequest(let id, let method, let params):
            return handleClientRequest(id: id, method: method, params: params)
        case .response(let id, let result, let error):
            return handleClientResponse(id: id, result: result, error: error)
        case .notification(let method, _):
            if method == "initialized" || method == "session/cancel" {
                return []
            }
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
            currentModeID = "agent"
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
            if scenario == .resume, method == "session/load" {
                // Replay a short transcript before the load response so clients
                // can rebuild chat history (ACP session/load contract).
                return [
                    sessionUpdate(
                        kind: "user_message_chunk",
                        content: .object([
                            "type": .string("text"),
                            "text": .string("prior user"),
                        ]),
                        messageID: "hist-user-1"
                    ),
                    sessionUpdate(
                        kind: "agent_message_chunk",
                        content: .object([
                            "type": .string("text"),
                            "text": .string("prior assistant"),
                        ]),
                        messageID: "hist-agent-1"
                    ),
                    ACPRPCCodec.response(id: id, result: .object([
                        "modes": modesPayload(),
                        "models": modelsPayload(),
                    ])),
                ]
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
            case .degradedArchived:
                return [
                    ACPRPCCodec.notification(
                        method: "session/update",
                        params: .object([
                            "sessionId": .string(sessionID),
                            "update": .object([
                                "sessionUpdate": .string("session_info_update"),
                                "title": .string("Archived session"),
                                "_meta": .object(["archived": .bool(true)]),
                            ]),
                        ])
                    ),
                ] + completePrompt(reply: scenario.defaultReply)
            case .text, .auth, .authFail, .resume, .dashboard, .backgroundPermission,
                 .degradedNoDashboard:
                return completePrompt(reply: scenario.defaultReply)
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
            return completePrompt(reply: scenario.defaultReply)
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
                    "id": .string("agent"),
                    "name": .string("Agent"),
                    "description": .string("Full agent capabilities with tool access"),
                ]),
                .object([
                    "id": .string("plan"),
                    "name": .string("Plan"),
                    "description": .string("Read-only planning"),
                ]),
                .object([
                    "id": .string("ask"),
                    "name": .string("Ask"),
                    "description": .string("Q&A mode"),
                ]),
            ]),
        ])
    }

    private func modelsPayload() -> JSONValue {
        .object([
            "currentModelId": .string("auto"),
            "availableModels": .array([
                .object([
                    "modelId": .string("auto"),
                    "name": .string("Auto"),
                ]),
                .object([
                    "modelId": .string("gpt-5.4"),
                    "name": .string("GPT-5.4"),
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
        let prefix = pendingReplyPrefix
        pendingReplyPrefix = ""
        let text = prefix + reply
        return [
            sessionUpdate(
                kind: "agent_message_chunk",
                content: .object(["type": .string("text"), "text": .string(text)])
            ),
            ACPRPCCodec.response(
                id: promptID,
                result: .object(["stopReason": .string("end_turn")])
            ),
        ]
    }

    private func sessionUpdate(kind: String, content: JSONValue, messageID: String? = nil) -> Data {
        var update: [String: JSONValue] = [
            "sessionUpdate": .string(kind),
            "content": content,
        ]
        if let messageID {
            update["messageId"] = .string(messageID)
        }
        return ACPRPCCodec.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string(sessionID),
                "update": .object(update),
            ])
        )
    }
}
