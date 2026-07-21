import Foundation
import AgentProtocol

/// Translates between domain `AgentError` and portable `WireAgentError`.
enum WireAgentErrorCoding {

    static func encode(_ err: AgentError) -> WireAgentError {
        var context = WireAgentErrorContext()
        switch err {
        case .binaryNotFound(let agentID, let hint):
            context[.agentID] = agentID.rawValue
            context[.hint] = hint
        case .spawnFailed(let errno, let detail):
            context[.errno] = String(errno)
            context[.detail] = detail
        case .hookSocketFailed(let detail):
            context[.detail] = detail
        case .transcriptDecodeFailed(let path, let detail):
            context[.path] = path
            context[.detail] = detail
        case .workspaceInvalid(let path, let detail):
            context[.path] = path
            context[.detail] = detail
        case .authenticationRequired(let agentID):
            context[.agentID] = agentID.rawValue
        case .staleEditTarget(let targetID):
            context[.targetID] = targetID.uuidString
        case .unsupportedCommand(let name):
            context[.name] = name
        case .gitCheckoutFailed(let path, let detail):
            context[.path] = path
            context[.detail] = detail
        case .hunkRevertFailed(let path, let hunkID, let detail):
            context[.path] = path
            context[.hunkID] = hunkID.uuidString
            context[.detail] = detail
        case .attachmentNotFound(let id):
            context[.id] = id
        case .permissionTimeout(let promptID, let action):
            context[.promptID] = promptID.uuidString
            context[.action] = action.wireValue
        case .internalInvariant(let detail):
            context[.detail] = detail
        case .unsupportedOperation(let detail):
            context[.detail] = detail
        case .engineRestartLimitReached:
            break
        }
        return WireAgentError(code: err.code, message: err.userMessage, context: context.dictionary)
    }

    static func decode(_ wire: WireAgentError) -> AgentError {
        guard let code = WireAgentErrorCode(rawValue: wire.code) else {
            return .internalInvariant(detail: "\(wire.code): \(wire.message)")
        }
        let ctx = WireAgentErrorContext(wire.context)
        switch code {
        case .binaryNotFound:
            let agentID = AgentID(rawValue: ctx[.agentID] ?? "") ?? .other
            return .binaryNotFound(agentID: agentID, hint: ctx[.hint] ?? wire.message)
        case .spawnFailed:
            return .spawnFailed(errno: Int32(ctx[.errno] ?? "") ?? -1,
                                detail: ctx[.detail] ?? wire.message)
        case .hookSocketFailed:
            return .hookSocketFailed(detail: ctx[.detail] ?? wire.message)
        case .transcriptDecodeFailed:
            return .transcriptDecodeFailed(path: ctx[.path] ?? "",
                                           detail: ctx[.detail] ?? wire.message)
        case .workspaceInvalid:
            return .workspaceInvalid(path: ctx[.path] ?? "",
                                     detail: ctx[.detail] ?? wire.message)
        case .authenticationRequired:
            let agentID = AgentID(rawValue: ctx[.agentID] ?? "") ?? .other
            return .authenticationRequired(agentID: agentID)
        case .staleEditTarget:
            guard let targetID = UUID(uuidString: ctx[.targetID] ?? "") else {
                return invalidContext(code, field: .targetID)
            }
            return .staleEditTarget(targetID: targetID)
        case .unsupportedCommand:
            return .unsupportedCommand(name: ctx[.name] ?? wire.message)
        case .gitCheckoutFailed:
            return .gitCheckoutFailed(path: ctx[.path] ?? "",
                                      detail: ctx[.detail] ?? wire.message)
        case .hunkRevertFailed:
            guard let hunkID = UUID(uuidString: ctx[.hunkID] ?? "") else {
                return invalidContext(code, field: .hunkID)
            }
            return .hunkRevertFailed(path: ctx[.path] ?? "",
                                     hunkID: hunkID,
                                     detail: ctx[.detail] ?? wire.message)
        case .attachmentNotFound:
            return .attachmentNotFound(id: ctx[.id] ?? wire.message)
        case .engineRestartLimitReached:
            return .engineRestartLimitReached
        case .permissionTimeout:
            guard let promptID = UUID(uuidString: ctx[.promptID] ?? "") else {
                return invalidContext(code, field: .promptID)
            }
            guard let action = decodePermissionDecision(ctx[.action] ?? "") else {
                return invalidContext(code, field: .action)
            }
            return .permissionTimeout(promptID: promptID, action: action)
        case .internalInvariant:
            return .internalInvariant(detail: ctx[.detail] ?? wire.message)
        case .unsupportedOperation:
            return .unsupportedOperation(detail: ctx[.detail] ?? wire.message)
        }
    }

    private static func invalidContext(_ code: WireAgentErrorCode,
                                       field: WireAgentErrorContextKey) -> AgentError {
        .internalInvariant(detail: "invalid \(code.rawValue) \(field.rawValue)")
    }

    private static func decodePermissionDecision(_ raw: String) -> PermissionDecision? {
        switch raw {
        case "allow": return .allow
        case "allowAlways": return .allowAlways
        case "deny": return .deny
        default:
            if raw.hasPrefix("option:") {
                return .option(id: String(raw.dropFirst("option:".count)))
            }
            return nil
        }
    }
}
