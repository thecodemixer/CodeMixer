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
        // Engine `sessionPromptReady` is authoritative for the in-flight
        // handshake. Do not require the navigator's resume id to match — ACP
        // session/load can return the same chat under a normalized id, and a
        // mismatched guard left the composer locked forever after a successful
        // adapter ready signal.
        cancelSessionHandshakeTimeout()
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
        sessionActivation = .idle
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
