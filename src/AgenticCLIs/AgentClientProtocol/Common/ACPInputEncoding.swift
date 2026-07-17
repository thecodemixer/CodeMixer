import Foundation

import AgentCore

/// Encodes Codemixer input into ACP JSON-RPC 2.0 frames.
public enum ACPInputEncoding {
    private static let clientVersion = "0.1.0"

    public static func bootstrap(context: LaunchContext,
                                 state: ACPClientState,
                                 customAgentID: String,
                                 displayName: String) -> Data {
        state.beginSession(
            context: context,
            customAgentID: customAgentID,
            displayName: displayName
        )
        let id = state.nextRequestID(for: .initialize)
        return ACPRPCCodec.request(
            id: id,
            method: "initialize",
            params: .object([
                "protocolVersion": .number(1),
                "clientCapabilities": .object([
                    "fs": .object([
                        "readTextFile": .bool(true),
                        "writeTextFile": .bool(true),
                    ]),
                    "terminal": .bool(true),
                ]),
                "clientInfo": .object([
                    "name": .string("codemixer"),
                    "title": .string("Codemixer"),
                    "version": .string(clientVersion),
                ]),
            ])
        )
    }

    /// Frames sent after a successful `initialize` (no auth required).
    public static func postInitialize(state: ACPClientState) -> Data {
        let initialized = ACPRPCCodec.notification(method: "initialized")
        let session = sessionOpen(state: state)
        return ACPRPCCodec.concatenate([initialized, session])
    }

    public static func authenticate(methodID: String, state: ACPClientState) -> Data {
        let id = state.nextRequestID(for: .authenticate)
        state.setPhase(.awaitingAuthentication)
        return ACPRPCCodec.request(
            id: id,
            method: "authenticate",
            params: .object(["methodId": .string(methodID)])
        )
    }

    public static func sessionOpen(state: ACPClientState) -> Data {
        guard let context = state.currentContext() else { return Data() }
        if let resume = context.resumeSessionID {
            if state.supportsLoadSession() {
                let id = state.nextRequestID(for: .sessionLoad)
                state.setPhase(.awaitingSession)
                return ACPRPCCodec.request(
                    id: id,
                    method: "session/load",
                    params: .object([
                        "sessionId": .string(resume),
                        "cwd": .string(context.workspace.path),
                        "mcpServers": .array([]),
                    ])
                )
            }
            if state.supportsResumeSession() {
                let id = state.nextRequestID(for: .sessionResume)
                state.setPhase(.awaitingSession)
                return ACPRPCCodec.request(
                    id: id,
                    method: "session/resume",
                    params: .object([
                        "sessionId": .string(resume),
                        "cwd": .string(context.workspace.path),
                        "mcpServers": .array([]),
                    ])
                )
            }
        }
        return sessionNew(state: state)
    }

    public static func sessionNew(state: ACPClientState) -> Data {
        guard let context = state.currentContext() else { return Data() }
        let id = state.nextRequestID(for: .sessionNew)
        state.setPhase(.awaitingSession)
        return ACPRPCCodec.request(
            id: id,
            method: "session/new",
            params: .object([
                "cwd": .string(context.workspace.path),
                "mcpServers": .array([]),
            ])
        )
    }

    public static func userPrompt(_ text: String, state: ACPClientState) -> Data {
        guard let sessionID = state.sessionID() else {
            state.enqueuePrompt(text)
            return Data()
        }
        let id = state.nextRequestID(for: .sessionPrompt)
        let blocks = contentBlocks(from: text)
        return ACPRPCCodec.request(
            id: id,
            method: "session/prompt",
            params: .object([
                "sessionId": .string(sessionID),
                "prompt": .array(blocks),
            ])
        )
    }

    public static func cancel(state: ACPClientState) -> Data {
        guard let sessionID = state.sessionID() else { return Data() }
        return ACPRPCCodec.notification(
            method: "session/cancel",
            params: .object(["sessionId": .string(sessionID)])
        )
    }

    /// ACP `session/set_mode` — switches the agent operating mode advertised
    /// on `session/new` / `session/load` (`availableModes`).
    public static func setMode(modeID: String, state: ACPClientState) -> Data {
        guard let sessionID = state.sessionID() else { return Data() }
        let id = state.nextRequestID(for: .sessionSetMode)
        return ACPRPCCodec.request(
            id: id,
            method: "session/set_mode",
            params: .object([
                "sessionId": .string(sessionID),
                "modeId": .string(modeID),
            ])
        )
    }

    public static func listSessions(state: ACPClientState) -> Data? {
        guard state.supportsListSessions(),
              let context = state.currentContext() else { return nil }
        let id = state.nextRequestID(for: .sessionList)
        return ACPRPCCodec.request(
            id: id,
            method: "session/list",
            params: .object(["cwd": .string(context.workspace.path)])
        )
    }

    public static func permissionResponse(id: JSONValue,
                                          optionID: String?,
                                          cancelled: Bool) -> Data {
        if cancelled {
            return ACPRPCCodec.response(
                id: id,
                result: .object([
                    "outcome": .object(["outcome": .string("cancelled")]),
                ])
            )
        }
        guard let optionID else {
            return ACPRPCCodec.response(
                id: id,
                result: .object([
                    "outcome": .object(["outcome": .string("cancelled")]),
                ])
            )
        }
        return ACPRPCCodec.response(
            id: id,
            result: .object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string(optionID),
                ]),
            ])
        )
    }

    public static func queuedPrompts(state: ACPClientState) -> Data {
        let frames = state.takeQueuedPrompts().map { userPrompt($0, state: state) }
        return ACPRPCCodec.concatenate(frames)
    }

    private static func contentBlocks(from prompt: String) -> [JSONValue] {
        var textLines: [Substring] = []
        var blocks: [JSONValue] = []
        for line in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@/") || line.hasPrefix("@~") {
                let path = String(line.dropFirst())
                blocks.append(.object([
                    "type": .string("text"),
                    "text": .string(path),
                ]))
            } else {
                textLines.append(line)
            }
        }
        let text = textLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            blocks.insert(.object([
                "type": .string("text"),
                "text": .string(text),
            ]), at: 0)
        }
        if blocks.isEmpty {
            blocks = [.object(["type": .string("text"), "text": .string(prompt)])]
        }
        return blocks
    }
}
