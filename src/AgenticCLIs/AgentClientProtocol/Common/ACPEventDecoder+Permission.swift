import Foundation

import AgentCore
import AgentProtocol

/// Handles `request_permission` / `session/request_permission` server
/// requests: auto-approve, park-until-`session/load` for a background
/// session, or surface a live `permissionRequest` event.
extension ACPEventDecoder {
    func permissionRequest(id: JSONValue, params: JSONValue) async -> Batch {
        let parsed = parsePermissionOptions(params["options"]?.arrayValue ?? [])
        let toolCall = params["toolCall"]
        let toolName = toolCall?["title"]?.stringValue
            ?? toolCall?["kind"]?.stringValue
            ?? "Permissions"
        let summary = toolCall?["title"]?.stringValue
            ?? "Approve requested permissions"
        let prompt = PermissionPrompt(
            id: random.uuid(),
            toolName: toolName,
            summary: summary,
            argumentsSummary: stringified(params) ?? "{}",
            requestedAt: clock.now(),
            options: parsed.options.isEmpty ? nil : parsed.options
        )
        let signature = "\(prompt.toolName)|\(prompt.summary)"
        if state.shouldAutoApprove(signature: signature),
           let optionID = parsed.optionIDs["allow_always"] ?? parsed.optionIDs["allow_once"] {
            return Batch(replies: [
                ACPInputEncoding.permissionResponse(id: id, optionID: optionID, cancelled: false),
            ])
        }
        let requestSessionID = params["sessionId"]?.stringValue ?? state.sessionID()
        let foregroundSessionID = state.sessionID()
        if let requestSessionID,
           let foregroundSessionID,
           requestSessionID != foregroundSessionID {
            state.parkPermission(
                sessionID: requestSessionID,
                parked: ACPClientState.ParkedPermission(
                    prompt: prompt,
                    requestID: id,
                    optionIDs: parsed.optionIDs
                )
            )
            guard let context = state.currentContext() else { return Batch() }
            await sessionIndex.setNeedsAttention(
                sessionID: requestSessionID,
                customAgentID: context.customAgentID,
                needsAttention: true
            )
            let title = await sessionTitle(
                sessionID: requestSessionID,
                customAgentID: context.customAgentID,
                workspace: context.workspace
            ) ?? requestSessionID
            return Batch(events: [
                .sessionIndexChanged(projectPath: context.workspace),
                .sessionAttentionChanged(
                    sessionID: requestSessionID,
                    title: title,
                    needsAttention: true
                ),
            ])
        }
        state.registerApproval(id: prompt.id, requestID: id, optionIDs: parsed.optionIDs)
        return Batch(events: [.permissionRequest(prompt: prompt)])
    }

    func parsePermissionOptions(_ options: [JSONValue])
        -> (options: [PermissionOption], optionIDs: [String: String]) {
        var optionIDs: [String: String] = [:]
        var customOptions: [PermissionOption] = []
        for option in options {
            guard let optionID = option["optionId"]?.stringValue else { continue }
            if let kind = option["kind"]?.stringValue {
                optionIDs[kind] = optionID
            }
            let label = option["name"]?.stringValue
                ?? option["label"]?.stringValue
                ?? optionID
            customOptions.append(PermissionOption(optionId: optionID, label: label))
        }
        return (customOptions, optionIDs)
    }
}
