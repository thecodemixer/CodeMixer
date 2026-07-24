import Foundation
import AgentProtocol
import AgentCore

/// Handles Codex App Server requests for our approval: builds the
/// `PermissionPrompt`, auto-approves when a matching rule already fired this
/// session, and otherwise surfaces the prompt and parks the request id for
/// `CodexInputEncoding.permissionResponse` to answer later.
extension CodexEventDecoder {
    func serverRequest(id: JSONValue,
                       method: String,
                       params: JSONValue) async -> Batch {
        guard Self.approvalMethods.contains(method) else {
            let error = CodexAgentError.unknownServerRequest(method: method)
            return Batch(
                events: [.error(error.agentError)],
                replies: [
                    CodexRPCCodec.errorResponse(
                        id: id,
                        code: -32601,
                        message: "Unsupported server request: \(method)"
                    ),
                ]
            )
        }

        let prompt = approvalPrompt(method: method, params: params)
        let signature = "\(prompt.toolName)|\(prompt.summary)|\(prompt.argumentsSummary)"
        if state.shouldAutoApprove(signature: signature) {
            return Batch(replies: [
                CodexInputEncoding.permissionResponse(id: id, allow: true),
            ])
        }
        state.registerApproval(id: prompt.id, requestID: id, signature: signature)
        return Batch(events: [.permissionRequest(prompt: prompt)])
    }

    private func approvalPrompt(method: String, params: JSONValue) -> PermissionPrompt {
        let toolName: String
        let summary: String
        switch method {
        case "item/commandExecution/requestApproval":
            toolName = "Bash"
            summary = params["reason"]?.stringValue
                ?? params["command"]?.stringValue
                ?? "Approve command execution"
        case "item/fileChange/requestApproval":
            toolName = "Edit"
            summary = params["reason"]?.stringValue
                ?? params["grantRoot"]?.stringValue
                ?? "Approve file changes"
        default:
            toolName = "Permissions"
            summary = params["reason"]?.stringValue ?? "Approve requested permissions"
        }
        return PermissionPrompt(
            id: random.uuid(),
            toolName: toolName,
            summary: summary,
            argumentsSummary: jsonString(params) ?? "{}",
            requestedAt: clock.now()
        )
    }

    private static let approvalMethods: Set<String> = [
        "item/commandExecution/requestApproval",
        "item/fileChange/requestApproval",
        "item/permissions/requestApproval",
    ]
}
