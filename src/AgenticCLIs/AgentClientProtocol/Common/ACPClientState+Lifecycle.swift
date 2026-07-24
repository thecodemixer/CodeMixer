import Foundation

import AgentCore
import AgentProtocol

/// Session begin/prepare, the `Phase` machine, session id, and prompts
/// queued while `phase() == .awaitingSession`.
extension ACPClientState {
    func beginSession(context: LaunchContext,
                      customAgentID: String,
                      displayName: String) {
        withLock {
            self.context = Context(
                workspace: context.workspace,
                permissionMode: context.permissionMode,
                customAgentID: customAgentID,
                displayName: displayName,
                resumeSessionID: context.resumeSessionID
            )
            nextID = 1
            requests.removeAll()
            phaseStorage = .awaitingInitialize
            sessionIDStorage = nil
            loadSessionSupported = false
            resumeSessionSupported = false
            listSessionsSupported = false
            queuedPrompts.removeAll()
            pendingApprovals.removeAll()
            autoApprovalSignatures.removeAll()
            itemIDs.removeAll()
            assistantTextByItemID.removeAll()
            thinkingBlockIDs.removeAll()
            toolMetaByID.removeAll()
            agentCapabilities = nil
            availableModesStorage = []
            currentModeIDStorage = nil
            availableModelOptions = []
            currentModelIDStorage = nil
            thoughtText = ""
            clearReplayLocked()
            parkedPermissionsBySession.removeAll()
        }
    }

    func currentContext() -> Context? {
        withLock { context }
    }

    func phase() -> Phase {
        withLock { phaseStorage }
    }

    func setPhase(_ phase: Phase) {
        withLock { phaseStorage = phase }
    }

    func setSessionID(_ id: String) {
        withLock {
            sessionIDStorage = id
            phaseStorage = .ready
        }
    }

    func sessionID() -> String? {
        withLock { sessionIDStorage }
    }

    func prepareNewSession() {
        withLock {
            requests.removeAll()
            sessionIDStorage = nil
            queuedPrompts.removeAll()
            pendingApprovals.removeAll()
            itemIDs.removeAll()
            assistantTextByItemID.removeAll()
            thinkingBlockIDs.removeAll()
            toolMetaByID.removeAll()
            phaseStorage = .awaitingSession
            availableModesStorage = []
            currentModeIDStorage = nil
            availableModelOptions = []
            currentModelIDStorage = nil
            thoughtText = ""
            clearReplayLocked()
        }
    }

    /// Switch the live ACP process onto another session id without re-running
    /// initialize/auth. Keeps advertised capabilities from the current process.
    func prepareLoadSession(sessionID: String) {
        withLock {
            guard let existing = context else { return }
            context = Context(
                workspace: existing.workspace,
                permissionMode: existing.permissionMode,
                customAgentID: existing.customAgentID,
                displayName: existing.displayName,
                resumeSessionID: sessionID
            )
            requests.removeAll()
            sessionIDStorage = nil
            queuedPrompts.removeAll()
            pendingApprovals.removeAll()
            itemIDs.removeAll()
            assistantTextByItemID.removeAll()
            thinkingBlockIDs.removeAll()
            toolMetaByID.removeAll()
            phaseStorage = .awaitingSession
            availableModesStorage = []
            currentModeIDStorage = nil
            availableModelOptions = []
            currentModelIDStorage = nil
            thoughtText = ""
            clearReplayLocked()
        }
    }

    func enqueuePrompt(_ text: String) {
        withLock { queuedPrompts.append(text) }
    }

    func takeQueuedPrompts() -> [String] {
        withLock {
            let prompts = queuedPrompts
            queuedPrompts.removeAll()
            return prompts
        }
    }
}
