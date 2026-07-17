import Foundation
import AgentCore
import AgentProtocol

extension EngineViewModel {

    // MARK: - Optimistic send

    /// Send a prompt with instant local feedback: append the user bubble and
    /// flip to a working state on the main actor *before* the engine round-trip,
    /// then reconcile when the engine (and the Claude hook) echo `.userTurn`.
    /// Rolls the optimistic bubble back if the send throws.
    ///
    /// Activate a slash-command palette entry. Mode-style slashes (e.g. Cursor
    /// `/agent`) reuse the same `selectCommands` as the composer mode menu;
    /// prompt-style commands get optimistic conversation feedback.
    public func activateSlashCommand(_ command: SlashCommand) {
        guard !isComposerLockedForSessionResume else { return }
        if let mode = agentMode(matchingSlashName: command.name) {
            selectAgentMode(mode)
            return
        }
        if !command.sendsAsPrompt {
            recordAndSend(
                ClientAction(
                    id: random.uuid(),
                    kind: .slashCommand,
                    title: "Slash command",
                    detail: command.name
                ),
                commands: [
                    command.isProjectDefined
                        ? .runCustomCommand(path: command.name, args: [])
                        : .runSlashCommand(name: command.name, args: []),
                ]
            )
            return
        }
        sendPrompt(command.name)
    }

    /// Select a composer agent mode: one history row, then the adapter's
    /// internal select commands in order.
    public func selectAgentMode(_ mode: AgentModeOption) {
        guard !isComposerLockedForSessionResume else { return }
        selectedAgentModeID = mode.id
        recordAndSend(
            ClientAction(
                id: random.uuid(),
                kind: .mode,
                title: "Mode",
                detail: mode.label
            ),
            commands: mode.selectCommands
        )
    }

    /// Set a session permission mode with a visible history marker.
    public func setPermissionMode(_ mode: PermissionMode) {
        let label: String
        switch mode {
        case .default: label = "Default"
        case .acceptEdits: label = "Accept Edits"
        case .plan: label = "Plan"
        case .bypassPermissions: label = "Bypass Permissions"
        }
        recordAndSend(
            ClientAction(
                id: random.uuid(),
                kind: .permissionMode,
                title: "Permission mode",
                detail: label
            ),
            commands: [.setPermissionMode(mode)]
        )
    }

    /// Respond to a pending permission prompt and record the decision.
    public func respondToPermission(id: UUID, decision: PermissionDecision) {
        let label: String
        switch decision {
        case .allow: label = "Allow"
        case .allowAlways: label = "Allow Always"
        case .deny: label = "Deny"
        }
        pendingPermission = nil
        recordAndSend(
            ClientAction(
                id: random.uuid(),
                kind: .permissionResponse,
                title: "Permission",
                detail: label
            ),
            commands: [.respondToPermission(id: id, decision: decision)]
        )
    }

    /// Select a model with a visible history marker.
    public func selectModel(id: String, label: String? = nil) {
        guard !isComposerLockedForSessionResume else { return }
        let detail = label
            ?? availableModels.first { $0.id == id }?.label
            ?? id
        recordAndSend(
            ClientAction(
                id: random.uuid(),
                kind: .model,
                title: "Model",
                detail: detail
            ),
            commands: [.selectModel(id: id)]
        )
    }

    /// Start a fresh session with a visible history marker.
    public func startNewSession() {
        recordAndSend(
            ClientAction(
                id: random.uuid(),
                kind: .sessionLifecycle,
                title: "Session",
                detail: "New session"
            ),
            commands: [.newSession]
        )
    }

    /// Compact agent context with a visible history marker.
    public func compactContext() {
        recordAndSend(
            ClientAction(
                id: random.uuid(),
                kind: .sessionLifecycle,
                title: "Session",
                detail: "Compact context"
            ),
            commands: [.compact]
        )
    }

    /// Record a Codemixer-owned history marker, then forward commands in order.
    public func recordAndSend(_ action: ClientAction, commands: [AgentCommand]) {
        Task { [engine, weak self] in
            do {
                try await engine.send(.recordClientAction(action))
                for command in commands {
                    try await engine.send(command)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    let message = (error as? AgentError)?.userMessage ?? error.localizedDescription
                    self.diagnostics.append(self.diagnostic(level: .error, message: message))
                }
            }
        }
    }

    func agentMode(matchingSlashName name: String) -> AgentModeOption? {
        availableAgentModes.first { mode in
            mode.selectCommands.contains { command in
                guard case .runSlashCommand(let slashName, let args) = command else { return false }
                return slashName == name && args.isEmpty
            }
        }
    }

    /// Prefer this over `send(.sendPrompt(...))` from the UI so sending never
    /// waits on the PTY write + bus fan-out (visual-style §1.6).
    public func sendPrompt(_ text: String, attachments: [AttachmentRef] = []) {
        guard !isComposerLockedForSessionResume else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let bubbleID = random.uuid()
        messages.append(.user(bubbleID: bubbleID, text: trimmed))
        lastUserBubbleID = bubbleID
        pendingOptimisticBubbleID = bubbleID
        armEchoDedup(for: trimmed)
        enterWorkingState()

        Task { [engine, weak self] in
            do {
                try await engine.send(.sendPrompt(text: text, attachments: attachments))
            } catch {
                await MainActor.run { self?.rollBackOptimisticSend(bubbleID: bubbleID, error: error) }
            }
        }
    }

    /// Edit-and-resubmit restarts the session (which clears `messages` and
    /// replays the truncated transcript), so we don't pre-insert a bubble —
    /// the genuine `.userTurn` carries the revised text. We only flip to a
    /// working state immediately for instant feedback, and let the echo dedup
    /// collapse the engine + hook duplicates.
    public func editAndResubmit(targetBubbleID: UUID,
                                text: String,
                                attachments: [AttachmentRef] = []) {
        guard !isComposerLockedForSessionResume else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enterWorkingState()
        send(.editAndResubmitLast(targetBubbleID: targetBubbleID,
                                  text: text,
                                  attachments: attachments))
    }

    /// Cancel the active turn and clear local waiting affordances immediately.
    /// A truly stalled PTY may not emit a clean idle event after Ctrl-C, so the
    /// UI treats the user's cancel action as authoritative.
    public func cancelCurrentTurn() {
        settleTurnIdle()
        send(.cancelCurrentTurn)
    }

    func enterWorkingState() {
        status = .working(phrase: ActivityTiming.workingPhrase)
        activity = .awaitingFirstChunk
        isAwaitingFirstReplyForPrompt = true
        stalledToastFiredThisTurn = false
        stalledToastVisible = false
    }

    /// Arm duplicate detection for a just-sent/materialised user turn. We expect
    /// exactly one further echo (the Claude hook) beyond the one that creates
    /// the bubble, so `dedupDropsRemaining` is 1.
    func armEchoDedup(for trimmed: String) {
        dedupUserText = trimmed
        dedupArmedAt = clock.now()
        dedupDropsRemaining = 1
    }

    func rollBackOptimisticSend(bubbleID: UUID, error: any Error) {
        if pendingOptimisticBubbleID == bubbleID {
            messages.removeAll {
                if case .user(let b, _) = $0 { return b == bubbleID }
                return false
            }
            pendingOptimisticBubbleID = nil
            dedupUserText = nil
            dedupArmedAt = nil
            dedupDropsRemaining = 0
            lastUserBubbleID = lastUserBubbleIDInMessages()
            status = .idle
            activity = .idle
            isAwaitingFirstReplyForPrompt = false
        }
        let message = (error as? AgentError)?.userMessage ?? error.localizedDescription
        diagnostics.append(diagnostic(level: .error, message: message))
    }

    func lastUserBubbleIDInMessages() -> UUID? {
        for message in messages.reversed() {
            if case .user(let id, _) = message { return id }
        }
        return nil
    }

    /// Reconcile a `.userTurn` echo against any optimistic bubble + duplicate
    /// hook echo. See `pendingOptimisticBubbleID` for the full rationale.
    func applyUserTurn(id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = clock.now()
        let withinWindow = (dedupArmedAt.map { now.timeIntervalSince($0) <= echoWindowSeconds }) ?? false

        if dedupUserText == trimmed, withinWindow {
            if let optimisticID = pendingOptimisticBubbleID {
                // First real echo for an optimistic bubble: adopt the engine id
                // so edit-and-resubmit targets the right turn.
                let adoptedID = UUID(uuidString: id) ?? optimisticID
                if let idx = messages.lastIndex(where: {
                    if case .user(let b, _) = $0 { return b == optimisticID }
                    return false
                }) {
                    messages[idx] = .user(bubbleID: adoptedID, text: text)
                }
                lastUserBubbleID = adoptedID
                pendingOptimisticBubbleID = nil
                // Re-arm the window so the later hook echo still drops.
                dedupArmedAt = now
                return
            }
            if dedupDropsRemaining > 0 {
                dedupDropsRemaining -= 1
                return  // duplicate (engine + hook double-publish) — drop.
            }
        }

        // Genuine new user turn.
        let uid = UUID(uuidString: id) ?? random.uuid()
        messages.append(.user(bubbleID: uid, text: text))
        lastUserBubbleID = uid
        pendingOptimisticBubbleID = nil
        armEchoDedup(for: trimmed)
    }
}
