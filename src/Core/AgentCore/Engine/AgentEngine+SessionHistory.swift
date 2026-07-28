/// Connects live engine events to the transcript repository without allowing
/// persistence work to alter turn/activity reduction.
import Foundation

extension AgentEngine {
    func activeTranscriptKey(sessionID: String? = nil) -> SessionTranscriptKey? {
        guard let workspace, let adapter else { return nil }
        let id = sessionID ?? currentSessionID
        guard let id, !id.isEmpty else { return nil }
        return SessionTranscriptKey(projectRoot: workspace,
                                    namespace: adapter.historyNamespace,
                                    sessionID: id)
    }

    func persistTranscriptEvent(_ event: AgentEvent) async {
        let key: SessionTranscriptKey?
        if case .sessionPhaseChanged(let sessionID, _) = event {
            key = activeTranscriptKey(sessionID: sessionID)
        } else {
            key = activeTranscriptKey()
        }
        guard let key else {
            if !TranscriptEventMapper.mutations(
                for: event,
                recordedAt: seams.clock.now(),
                projectRoot: workspace ?? URL(fileURLWithPath: "/")
            ).isEmpty {
                pendingTranscriptEvents.append(event)
            }
            return
        }
        do {
            try await transcriptRepository.record(event, for: key)
        } catch {
            await publishHistoryError(error, key: key, operation: "write")
        }
    }

    func bindTranscriptSession(_ sessionID: String) async {
        guard let key = activeTranscriptKey(sessionID: sessionID), let adapter else {
            return
        }
        do {
            try await transcriptRepository.registerSession(
                sessionID,
                namespace: key.namespace,
                agentID: adapter.id,
                in: key.projectRoot
            )
            if !pendingTranscriptEvents.isEmpty {
                let pending = pendingTranscriptEvents
                pendingTranscriptEvents.removeAll()
                try await transcriptRepository.record(pending, for: key)
            }
            try await publishStoredSessions(in: key.projectRoot)
        } catch {
            await publishHistoryError(error, key: key, operation: "write")
        }
    }

    func recordBackgroundSessionEvents(_ batch: BackgroundSessionEventBatch,
                                       adapter: any AgentAdapter,
                                       workspace: URL) async {
        let key = SessionTranscriptKey(projectRoot: workspace,
                                       namespace: adapter.historyNamespace,
                                       sessionID: batch.sessionID)
        do {
            try await transcriptRepository.registerSession(
                batch.sessionID,
                namespace: key.namespace,
                agentID: adapter.id,
                in: key.projectRoot
            )
            try await transcriptRepository.record(batch.events, for: key)
            try await publishStoredSessions(in: key.projectRoot)
        } catch {
            await publishHistoryError(error, key: key, operation: "write")
        }
    }

    func updateSessionMetadata(_ update: SessionMetadataUpdate,
                               adapter: any AgentAdapter,
                               workspace: URL) async {
        do {
            switch update {
            case .registered(let sessionID, let title):
                try await transcriptRepository.registerSession(
                    sessionID,
                    namespace: adapter.historyNamespace,
                    agentID: adapter.id,
                    in: workspace,
                    title: title
                )
            case .markAsOverview(let sessionID, let url):
                try await transcriptRepository.markOverview(sessionID,
                                                            isOverview: true,
                                                            url: url,
                                                            in: workspace)
            case .unmarkAsOverview(let sessionID):
                try await transcriptRepository.markOverview(sessionID,
                                                            isOverview: false,
                                                            url: nil,
                                                            in: workspace)
            case .archived(let sessionID):
                try await transcriptRepository.markArchived(sessionID,
                                                            archived: true,
                                                            in: workspace)
            case .unarchived(let sessionID):
                try await transcriptRepository.markArchived(sessionID,
                                                            archived: false,
                                                            in: workspace)
            case .superseded(let sessionID):
                try await transcriptRepository.markSuperseded(sessionID,
                                                              in: workspace)
            }
            try await publishStoredSessions(in: workspace)
        } catch {
            let key = SessionTranscriptKey(projectRoot: workspace,
                                           namespace: adapter.historyNamespace,
                                           sessionID: update.sessionID)
            await publishHistoryError(error, key: key, operation: "write")
        }
    }

    func publishStoredSessions(in projectRoot: URL) async throws {
        let path = projectRoot.standardizedFileURL.path
        let sessions = try await transcriptRepository.sessions(
            inProject: projectRoot,
            attentionSessionIDs: attentionSessionIDsByProject[path] ?? []
        )
        await bus.publish(.sessionsListed(projectPath: projectRoot,
                                          sessions: sessions))
    }

    func noteSessionAttention(_ sessionID: String,
                              needsAttention: Bool,
                              in projectRoot: URL) {
        let path = projectRoot.standardizedFileURL.path
        if needsAttention {
            attentionSessionIDsByProject[path, default: []].insert(sessionID)
        } else {
            attentionSessionIDsByProject[path]?.remove(sessionID)
        }
    }

    func restoreHistory(for key: SessionTranscriptKey) async {
        sessionActivationState = .restoring(key)
        transcript = []
        changedFiles = []
        do {
            let restored = try await transcriptRepository.transcript(for: key)
            transcript = restored.snapshotMessages()
            changedFiles = restored.changedFiles
            for event in restored.replayEvents() {
                await bus.publish(event)
            }
            await bus.publish(.sessionHistoryRestored(sessionID: key.sessionID))
            sessionActivationState = .awaitingAdapter(key, historyPublished: true)
        } catch {
            await bus.publish(.sessionHistoryRestored(sessionID: key.sessionID))
            sessionActivationState = .awaitingAdapter(key, historyPublished: true)
            await publishHistoryError(error, key: key, operation: "load")
        }
    }

    func markSessionPromptReady(_ sessionID: String) async {
        guard let key = activeTranscriptKey(sessionID: sessionID) else { return }
        sessionActivationState = .ready(key)
        await bus.publish(.sessionPromptReady(sessionID: sessionID))
    }

    private func publishHistoryError(_ error: any Error,
                                     key: SessionTranscriptKey,
                                     operation: String) async {
        let agentError: AgentError
        if case SessionTranscriptRepositoryError.locked(_, let ownerPID) = error {
            agentError = .historyJournalLocked(sessionID: key.sessionID,
                                               ownerPID: ownerPID)
        } else if operation == "load" {
            agentError = .historyLoadFailed(path: key.projectRoot.path,
                                            detail: String(describing: error))
        } else {
            agentError = .historyWriteFailed(path: key.projectRoot.path,
                                             detail: String(describing: error))
        }
        await bus.publish(.error(agentError))
    }
}

private extension SessionMetadataUpdate {
    var sessionID: String {
        switch self {
        case .registered(let sessionID, _),
             .markAsOverview(let sessionID, _),
             .unmarkAsOverview(let sessionID),
             .archived(let sessionID),
             .unarchived(let sessionID),
             .superseded(let sessionID):
            return sessionID
        }
    }
}
