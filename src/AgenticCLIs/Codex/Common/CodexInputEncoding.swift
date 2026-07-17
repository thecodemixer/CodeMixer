import Foundation

import AgentCore

/// Encodes Codemixer input into Codex App Server JSON-RPC frames.
public enum CodexInputEncoding {
    public static func bootstrap(context: LaunchContext,
                                 state: CodexSessionState,
                                 clientVersion: String) -> Data {
        state.beginSession(context: context)
        let initializeID = state.nextRequestID(for: .initialize)
        let initialize = CodexRPCCodec.request(
            id: initializeID,
            method: "initialize",
            params: .object([
                "clientInfo": .object([
                    "name": .string("codemixer"),
                    "title": .string("Codemixer"),
                    "version": .string(clientVersion),
                ]),
                "capabilities": .object([:]),
            ])
        )
        let initialized = CodexRPCCodec.notification(method: "initialized")
        let thread = context.resumeSessionID.map {
            resumeThread(id: $0, state: state)
        } ?? startThread(context: context, state: state)
        return CodexRPCCodec.concatenate([initialize, initialized, thread])
    }

    public static func turnStart(inputs: [CodexUserInput],
                                 state: CodexSessionState) -> Data {
        guard !inputs.isEmpty else { return Data() }
        guard let threadID = state.threadID() else {
            state.enqueue(inputs)
            return Data()
        }

        let title = inputs.compactMap { input -> String? in
            guard case .text(let text) = input else { return nil }
            return text
        }.first
        let requestID = state.nextRequestID(for: .turnStart(title: title))
        var params: [String: JSONValue] = [
            "threadId": .string(threadID),
            "input": .array(inputs.map(\.jsonValue)),
        ]
        if let model = state.selectedModel() {
            params["model"] = .string(model)
        }
        return CodexRPCCodec.request(
            id: requestID,
            method: "turn/start",
            params: .object(params)
        )
    }

    public static func userPrompt(_ text: String,
                                  state: CodexSessionState) -> Data {
        turnStart(inputs: inputs(from: text), state: state)
    }

    public static func interrupt(state: CodexSessionState) -> Data {
        guard let active = state.activeTurn() else { return Data() }
        let id = state.nextRequestID(for: .other("turn/interrupt"))
        return CodexRPCCodec.request(
            id: id,
            method: "turn/interrupt",
            params: .object([
                "threadId": .string(active.threadID),
                "turnId": .string(active.turnID),
            ])
        )
    }

    public static func permissionResponse(id: JSONValue, allow: Bool) -> Data {
        CodexRPCCodec.response(
            id: id,
            result: .object(["decision": .string(allow ? "allow" : "deny")])
        )
    }

    public static func compact(state: CodexSessionState) -> Data? {
        guard let threadID = state.threadID() else { return nil }
        let id = state.nextRequestID(for: .compact)
        return CodexRPCCodec.request(
            id: id,
            method: "thread/compact/start",
            params: .object(["threadId": .string(threadID)])
        )
    }

    public static func review(state: CodexSessionState) -> Data? {
        guard let threadID = state.threadID() else { return nil }
        let id = state.nextRequestID(for: .review)
        return CodexRPCCodec.request(
            id: id,
            method: "review/start",
            params: .object([
                "threadId": .string(threadID),
                "target": .object(["type": .string("uncommittedChanges")]),
            ])
        )
    }

    public static func startThread(context: LaunchContext,
                                   state: CodexSessionState) -> Data {
        let id = state.nextRequestID(for: .threadStart)
        let policy = CodexPolicyMapping.policy(for: context.permissionMode)
        return CodexRPCCodec.request(
            id: id,
            method: "thread/start",
            params: .object([
                "cwd": .string(context.workspace.path),
                "approvalPolicy": .string(policy.approval.rawValue),
                "sandbox": .string(policy.sandbox.rawValue),
            ])
        )
    }

    static func queuedTurns(state: CodexSessionState) -> Data {
        let frames = state.takeQueuedInputs().map {
            turnStart(inputs: $0, state: state)
        }
        return CodexRPCCodec.concatenate(frames)
    }

    private static func resumeThread(id threadID: String,
                                     state: CodexSessionState) -> Data {
        let id = state.nextRequestID(for: .threadResume)
        return CodexRPCCodec.request(
            id: id,
            method: "thread/resume",
            params: .object(["threadId": .string(threadID)])
        )
    }

    private static func inputs(from prompt: String) -> [CodexUserInput] {
        var textLines: [Substring] = []
        var references: [CodexUserInput] = []
        for line in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("@/") || line.hasPrefix("@~") else {
                textLines.append(line)
                continue
            }
            let path = String(line.dropFirst())
            let url = URL(fileURLWithPath: path)
            if imageExtensions.contains(url.pathExtension.lowercased()) {
                references.append(.localImage(url))
            } else {
                references.append(.mention(name: url.lastPathComponent, path: url))
            }
        }
        let text = textLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = text.isEmpty ? [] : [CodexUserInput.text(text)]
        return primary + references
    }

    private static let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "webp"])
}
