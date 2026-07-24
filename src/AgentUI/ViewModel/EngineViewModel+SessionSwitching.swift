import Foundation
import AgentCore


enum SessionSwitchingTiming {
    static let emptySessionFallback: Duration = .seconds(2)

    /// Adapters that declare `.sessionHandshakeGate` can spend their first
    /// seconds in protocol bootstrap before they accept a prompt. Keep the
    /// composer honest during that cold start, but never indefinitely.
    static let sessionHandshakeHardUnlock: Duration = .seconds(45)

    /// Same-project ACP/Cursor switch on an already-live process (`session/load`).
    /// Still waits for SessionStart, but must not look like a 45s cold spawn.
    static let warmSessionSwitchHardUnlock: Duration = .seconds(12)

    /// Non-Claude agents can unlock as soon as replayed content proves the UI
    /// is showing the selected session. The engine remains the source of truth
    /// for whether a command can be written to the transport.
    static let composerHardUnlock: Duration = .seconds(3)

    /// Claude Code history is replayed from JSONL, not from the live
    /// `claude --resume` process. Keep the composer locked until the engine's
    /// longer "no live SessionStart arrived" gate would also have released a
    /// held write.
    static let claudeCodeComposerHardUnlock: Duration = ActivityTiming.resumedSessionStartupStallTimeout

    /// Once Claude Code's live hook SessionStart arrives, keep the composer
    /// locked for the same settle/fallback window the engine uses before
    /// writing a held prompt. This aligns GUI sends with API/remote sends while
    /// avoiding the JSONL-history false-ready state.
    static let claudeCodeComposerHookUnlock: Duration = ActivityTiming.resumedSessionPostSessionStartFallback
        + ActivityTiming.resumePromptReadySettleDelay
}

enum ComposerGateState: Sendable, Equatable {
    case unlocked
    case replayUnlock(waitsForClaudeCodeResume: Bool)
    case sessionHandshake(warmSwitch: Bool)

    var isLocked: Bool {
        switch self {
        case .unlocked:
            return false
        case .replayUnlock, .sessionHandshake:
            return true
        }
    }

    var isHandshake: Bool {
        if case .sessionHandshake = self { return true }
        return false
    }

    var isWarmSessionSwitch: Bool {
        if case .sessionHandshake(warmSwitch: true) = self { return true }
        return false
    }

    var waitsForClaudeCodeResume: Bool {
        if case .replayUnlock(waitsForClaudeCodeResume: true) = self { return true }
        return false
    }
}

extension EngineViewModel {
    func beginSessionSwitch(projectPath: String,
                            sessionID id: String,
                            waitsForClaudeCodeResume: Bool = false,
                            isWarmACPSwitch: Bool = false) {
        workspace = URL(fileURLWithPath: projectPath).standardizedFileURL
        sessionID = id
        clearConversationState()
        // Activity follows the newly selected session — unrelated parked reviews
        // stay in `pendingPermissionsBySession` and only show their orange dots.
        refreshPermissionActivity()
        status = .idle
        isSwitchingSession = true
        // Cursor / ACP cold start (~20s) needs the handshake gate. A 3s unlock
        // lets the first prompt race `session/load` and vanish into the queue.
        // Same-project switches on a live process only wait for `session/load`.
        if !waitsForClaudeCodeResume, projectNeedsSessionHandshakeGate(path: projectPath) {
            if isWarmACPSwitch {
                lockComposerForWarmSessionSwitch()
            } else {
                lockComposerForSessionHandshake()
            }
        } else {
            lockComposerForSessionResume(waitsForClaudeCodeResume: waitsForClaudeCodeResume)
        }
        sessionSwitchingTask?.cancel()
        sessionSwitchingTask = Task { [weak self] in
            try? await self?.clock.sleep(for: SessionSwitchingTiming.emptySessionFallback)
            await MainActor.run {
                guard let self,
                      self.messages.isEmpty,
                      self.activeToolCalls.isEmpty else { return }
                // Keep the empty-state "restoring" face while the composer is
                // still gated — otherwise the hero flips to "Ready when you
                // are" with a locked chat box.
                guard !self.isComposerLockedForSessionResume else { return }
                self.isSwitchingSession = false
                self.sessionSwitchingTask = nil
            }
        }
    }

    func endSessionSwitch() {
        isSwitchingSession = false
        sessionSwitchingTask?.cancel()
        sessionSwitchingTask = nil
    }

    func finishSessionSwitchIfNeeded() {
        if isSwitchingSession {
            endSessionSwitch()
        }
        // This is called when conversation content arrives. For Codex and other
        // non-Claude agents, that content means the selected session is ready
        // enough for the composer because command delivery is not racing a TUI
        // resume screen. For Claude Code, the same content may be JSONL replay
        // only; live input readiness is handled by SessionStart below.
        // Handshake-gated agents (Cursor / ACP) stream history during
        // `session/load` *before* the session is prompt-ready — keep locked.
        if isComposerLockedForSessionResume, !isComposerWaitingForClaudeCodeResume {
            if isComposerLockedForSessionHandshake {
                return
            }
            unlockComposerForSessionResume()
        }
    }

    func lockComposerForSessionResume(waitsForClaudeCodeResume: Bool = false) {
        composerGateState = .replayUnlock(waitsForClaudeCodeResume: waitsForClaudeCodeResume)
        scheduleComposerResumeUnlock(after: waitsForClaudeCodeResume
            ? SessionSwitchingTiming.claudeCodeComposerHardUnlock
            : SessionSwitchingTiming.composerHardUnlock)
    }

    func lockComposerForSessionHandshake() {
        composerGateState = .sessionHandshake(warmSwitch: false)
        scheduleComposerResumeUnlock(after: SessionSwitchingTiming.sessionHandshakeHardUnlock)
    }

    /// Same-project `session/load` on a live ACP/Cursor process — still gated
    /// until SessionStart, but not the cold-spawn 45s / "Starting session…" path.
    func lockComposerForWarmSessionSwitch() {
        composerGateState = .sessionHandshake(warmSwitch: true)
        scheduleComposerResumeUnlock(after: SessionSwitchingTiming.warmSessionSwitchHardUnlock)
    }

    func scheduleComposerResumeUnlock(after delay: Duration) {
        composerResumeUnlockTask?.cancel()
        let clock = clock
        composerResumeUnlockTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.unlockComposerForSessionResume()
            }
        }
    }

    func unlockComposerForSessionResume() {
        composerGateState = .unlocked
        composerResumeUnlockTask?.cancel()
        composerResumeUnlockTask = nil
        // Empty resumes never get replay content that would end the switch;
        // drop the restoring banner once input is allowed again.
        if isSwitchingSession, messages.isEmpty, activeToolCalls.isEmpty {
            endSessionSwitch()
        }
    }

    func sessionResumeNeedsClaudeCodeReadiness(projectPath: String, sessionID id: String) -> Bool {
        // Prefer the session row because mixed projects can contain both Claude
        // and Codex sessions. If the row is not loaded yet, fall back to the
        // project type; this is still correct for dedicated Claude projects.
        if let session = sessionsByProject[projectPath]?.first(where: { $0.id == id }) {
            return session.agentID == .claudeCode
        }
        if let project = projects.first(where: { $0.path == projectPath }) {
            return project.projectType == .claudeCode
        }
        return false
    }

    func projectNeedsSessionHandshakeGate(path projectPath: String) -> Bool {
        if projectCapabilities.requiresSessionHandshakeGate(for: projectPath) {
            return true
        }
        // `applyAdapterCapabilities` is async; when the index is not warm yet,
        // fall back to project types that always ship with handshake-gated adapters.
        let standardized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        guard let project = projects.first(where: {
            URL(fileURLWithPath: $0.path).standardizedFileURL.path == standardized
        }) else { return false }
        switch project.projectType {
        case .cursorCLI, .custom:
            return true
        default:
            return false
        }
    }
}
