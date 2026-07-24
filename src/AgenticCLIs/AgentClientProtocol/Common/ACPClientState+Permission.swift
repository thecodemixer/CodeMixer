import Foundation

import AgentCore
import AgentProtocol

/// Live permission approvals, auto-approval signatures, and background
/// (foreign-session) permissions parked until that session's next
/// `session/load`.
extension ACPClientState {
    func registerApproval(id: UUID, requestID: JSONValue, optionIDs: [String: String]) {
        withLock {
            pendingApprovals[id] = PendingApproval(requestID: requestID, optionIDs: optionIDs)
        }
    }

    func takeApproval(id: UUID) -> PendingApproval? {
        withLock { pendingApprovals.removeValue(forKey: id) }
    }

    /// Drain live approvals (prompt id + wire request) so callers can cancel them.
    @discardableResult
    func takeAllPendingApprovals() -> [(promptID: UUID, approval: PendingApproval)] {
        withLock {
            let pairs = pendingApprovals.map { (promptID: $0.key, approval: $0.value) }
            pendingApprovals.removeAll()
            return pairs
        }
    }

    func parkPermission(sessionID: String, parked: ParkedPermission) {
        withLock {
            parkedPermissionsBySession[sessionID, default: []].append(parked)
        }
    }

    func takeParkedPermissions(sessionID: String) -> [ParkedPermission] {
        withLock {
            let parked = parkedPermissionsBySession.removeValue(forKey: sessionID) ?? []
            return parked
        }
    }

    /// Drop parked background reviews when the owning session is archived
    /// (migration Restart) so a later `session/load` cannot re-fire stale prompts.
    @discardableResult
    func clearParkedPermissions(sessionID: String) -> [ParkedPermission] {
        withLock {
            parkedPermissionsBySession.removeValue(forKey: sessionID) ?? []
        }
    }

    func shouldAutoApprove(signature: String) -> Bool {
        withLock { autoApprovalSignatures.contains(signature) }
    }

    func rememberAutoApproval(signature: String) {
        withLock { _ = autoApprovalSignatures.insert(signature) }
    }
}
