import Foundation
import AgentCore

extension EngineViewModel {
    /// Which composer-gate budget to arm while waiting for `sessionPromptReady`.
    enum SessionHandshakeKind: Sendable {
        /// First agent spawn for a project (Cursor initialize/auth is slow).
        case coldStart
        /// Open an existing session (history restore + adapter resume).
        case resume
        /// Project switch / New Chat on an already-pooled agent process.
        case warm
    }

    public func beginSessionSwitch(projectPath: String, sessionID id: String) {
        rememberSupersededSessionSwitch(replacingWith: id)
        workspace = URL(fileURLWithPath: projectPath).standardizedFileURL
        sessionID = id
        clearConversationState()
        promotePendingPhases(for: id, projectPath: projectPath)
        refreshPermissionActivity()
        status = .idle
        sessionActivation = .restoringHistory(sessionID: id)
        // Resume on a live pooled agent is fast; reopening after quit still needs
        // a cold spawn before session/load or --resume can finish.
        let handshake: SessionHandshakeKind =
            livePooledProjectPaths.contains(workspace?.path ?? projectPath)
            ? .resume
            : .coldStart
        armSessionHandshakeTimeout(handshake)
    }

    func noteHistoryRestored(sessionID id: String) {
        guard sessionID == id else { return }
        sessionActivation = .awaitingAdapter(sessionID: id)
        // History is already on screen. Keep the budget chosen at switch start
        // (cold if spawning, resume if pooled) — do not shrink to resume-only
        // when the agent process is still coming up.
        let projectPath = workspace?.path ?? ""
        let handshake: SessionHandshakeKind =
            livePooledProjectPaths.contains(projectPath) ? .resume : .coldStart
        armSessionHandshakeTimeout(handshake)
    }

    func notePromptReady(sessionID id: String) {
        // Drop ready signals for sessions the user already navigated away from.
        if !id.isEmpty, supersededSessionSwitchIDs.contains(id) {
            return
        }
        // Before history lands, require an exact match — remapping is only
        // allowed after `sessionHistoryRestored` confirmed the requested id
        // (ACP session/load may then report a normalized ready id).
        if case .restoringHistory(let expected) = sessionActivation {
            guard id.isEmpty || expected.isEmpty || id == expected else { return }
        }
        cancelSessionHandshakeTimeout()
        supersededSessionSwitchIDs.removeAll(keepingCapacity: true)
        if !id.isEmpty {
            sessionID = id
        }
        sessionActivation = .ready(sessionID: sessionID ?? id)
    }

    func noteAdapterPending() {
        sessionActivation = .awaitingAdapter(sessionID: sessionID ?? "")
        // prepareProjectOpen / overview restart — first bind before spawn.
        armSessionHandshakeTimeout(.coldStart)
    }

    func clearSessionActivation() {
        cancelSessionHandshakeTimeout()
        supersededSessionSwitchIDs.removeAll(keepingCapacity: true)
        sessionActivation = .idle
    }

    /// Marks the previous in-flight / ready resume id as stale so late bus
    /// events from that switch cannot complete a newer handshake.
    private func rememberSupersededSessionSwitch(replacingWith id: String) {
        func consider(_ previous: String) {
            guard !previous.isEmpty, previous != id else { return }
            supersededSessionSwitchIDs.insert(previous)
        }
        switch sessionActivation {
        case .restoringHistory(let previous),
             .awaitingAdapter(let previous),
             .ready(let previous),
             .failed(let previous, _):
            consider(previous)
        case .idle:
            break
        }
        if let sessionID {
            consider(sessionID)
        }
        supersededSessionSwitchIDs.remove(id)
    }

    /// Fail the composer gate if `sessionPromptReady` never arrives.
    func armSessionHandshakeTimeout(_ kind: SessionHandshakeKind) {
        cancelSessionHandshakeTimeout()
        sessionHandshakeGeneration &+= 1
        let generation = sessionHandshakeGeneration
        let timeout = Self.timeout(for: kind)
        sessionHandshakeTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                guard self.sessionHandshakeGeneration == generation else { return }
                switch self.sessionActivation {
                case .awaitingAdapter, .restoringHistory:
                    let id = self.sessionID ?? ""
                    self.sessionActivation = .failed(
                        sessionID: id,
                        message: "Agent did not become ready. Reopen the project and try again."
                    )
                    self.diagnostics.append(self.diagnostic(
                        level: .error,
                        message: "Agent handshake timed out. Reopen the project and try again."
                    ))
                default:
                    break
                }
            }
        }
    }

    func cancelSessionHandshakeTimeout() {
        sessionHandshakeTimeoutTask?.cancel()
        sessionHandshakeTimeoutTask = nil
    }

    private static func timeout(for kind: SessionHandshakeKind) -> Duration {
        switch kind {
        case .coldStart: return ActivityTiming.sessionHandshakeColdStartTimeout
        case .resume: return ActivityTiming.sessionHandshakeResumeTimeout
        case .warm: return ActivityTiming.sessionHandshakeWarmTimeout
        }
    }
}
