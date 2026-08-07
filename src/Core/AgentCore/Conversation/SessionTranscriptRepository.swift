/// Serializes access to session transcript aggregates, batches journal writes,
/// and exposes the only history/listing API used by the engine.
import A2UICore
import Foundation

actor SessionTranscriptRepository {
    private static let mutationBatchSize = 32
    private static let flushDebounce: Duration = .milliseconds(250)

    let store: ProjectSessionTranscriptStore
    let clock: any AgentClock
    private let ownerPID: Int32
    private let processIsRunning: @Sendable (Int32) -> Bool
    private var cached: [SessionTranscriptKey: CachedTranscript] = [:]
    var indexes: [String: [StoredSessionRecord]] = [:]
    var catalogStates: [String: CatalogImportState] = [:]

    init(store: ProjectSessionTranscriptStore,
         clock: any AgentClock,
         ownerPID: Int32 = ProcessInspector().currentPID,
         processIsRunning: @escaping @Sendable (Int32) -> Bool = {
             ProcessInspector().isRunning($0)
         }) {
        self.store = store
        self.clock = clock
        self.ownerPID = ownerPID
        self.processIsRunning = processIsRunning
    }

    func record(_ event: AgentEvent, for key: SessionTranscriptKey) throws {
        let mutations = TranscriptEventMapper.mutations(
            for: event,
            recordedAt: clock.now(),
            projectRoot: key.projectRoot
        )
        try record(mutations, for: key, updatesIndex: true)
    }

    func record(_ events: [AgentEvent], for key: SessionTranscriptKey) throws {
        let now = clock.now()
        let mutations = events.flatMap {
            TranscriptEventMapper.mutations(for: $0,
                                            recordedAt: now,
                                            projectRoot: key.projectRoot)
        }
        try record(mutations, for: key, updatesIndex: true)
    }

    func recordImported(_ events: [AgentEvent],
                        for key: SessionTranscriptKey) throws -> SessionTranscript {
        let now = clock.now()
        let mutations = events.flatMap {
            TranscriptEventMapper.mutations(for: $0,
                                            recordedAt: now,
                                            projectRoot: key.projectRoot)
        }
        try record(mutations, for: key, updatesIndex: false)
        return try transcript(for: key)
    }

    func transcript(for key: SessionTranscriptKey) throws -> SessionTranscript {
        try flush(key)
        return try cachedTranscript(for: key).transcript
    }

    func replayEvents(for key: SessionTranscriptKey) throws -> [AgentEvent] {
        try transcript(for: key).replayEvents()
    }

    func truncatedEntryCount(for key: SessionTranscriptKey) throws -> Int {
        try transcript(for: key).truncatedEntryCount
    }

    func truncate(afterUserTurnID id: AdapterTurnID,
                  for key: SessionTranscriptKey) throws {
        try record([.truncateAfterUser(id: id, recordedAt: clock.now())],
                   for: key,
                   updatesIndex: true)
        try flush(key)
    }

    func replaceUserTurn(id: AdapterTurnID,
                         text: String,
                         for key: SessionTranscriptKey) throws {
        try record([.replaceUser(id: id, text: text, recordedAt: clock.now())],
                   for: key,
                   updatesIndex: true)
        try flush(key)
    }

    func snapshotMessages(for key: SessionTranscriptKey) throws
        -> [SnapshotService.SnapshotMessage] {
        try transcript(for: key).snapshotMessages()
    }

    func changedFiles(for key: SessionTranscriptKey) throws -> [ChangedFile] {
        try transcript(for: key).changedFiles
    }

    /// The canonical, durable surface an `A2UIInteractionIntent` or client
    /// error report must be resolved against — never the renderer's own
    /// possibly-stale copy (trust boundary, see `AgentEngine+A2UI`).
    func a2uiSurface(surfaceID: String, for key: SessionTranscriptKey) throws -> A2UISurfaceState? {
        try transcript(for: key).a2uiSurfaces[surfaceID]
    }

    func reconcileChangedFiles(_ gitPaths: [ChangedFile],
                               for key: SessionTranscriptKey) throws {
        try record([.reconcileChangedFiles(gitPaths, recordedAt: clock.now())],
                   for: key,
                   updatesIndex: true)
    }

    func flush(_ key: SessionTranscriptKey) throws {
        guard var value = cached[key], !value.pending.isEmpty else { return }
        guard case .writable = value.access else {
            throw SessionTranscriptRepositoryError.locked(
                sessionID: key.sessionID,
                ownerPID: value.access.ownerPID
            )
        }
        value.flushTask?.cancel()
        value.flushTask = nil
        let pending = value.pending
        try store.append(pending, to: key)
        value.pending.removeAll(keepingCapacity: true)
        cached[key] = value
    }

    func evict(_ key: SessionTranscriptKey) throws {
        try flush(key)
        guard let value = cached.removeValue(forKey: key) else { return }
        value.flushTask?.cancel()
        if case .writable(let lock) = value.access {
            store.releaseWriteLock(lock)
        }
    }

    func shutdown() throws {
        for key in Array(cached.keys) {
            try evict(key)
        }
    }

    private func record(_ mutations: [TranscriptMutation],
                        for key: SessionTranscriptKey,
                        updatesIndex: Bool) throws {
        guard !mutations.isEmpty else { return }
        var value = try cachedTranscript(for: key)
        guard case .writable = value.access else {
            throw SessionTranscriptRepositoryError.locked(
                sessionID: key.sessionID,
                ownerPID: value.access.ownerPID
            )
        }
        var accepted: [TranscriptMutation] = []
        for mutation in mutations {
            guard value.transcript.apply(mutation) else { continue }
            appendBuffered(mutation, to: &value.pending)
            accepted.append(mutation)
        }
        guard !accepted.isEmpty else {
            cached[key] = value
            return
        }
        cached[key] = value
        if updatesIndex {
            try updateIndex(for: key,
                            transcript: value.transcript,
                            accepted: accepted)
        }
        if accepted.contains(where: \.flushesImmediately)
            || value.pending.count >= Self.mutationBatchSize {
            try flush(key)
        } else {
            scheduleFlush(for: key)
        }
    }

    private func cachedTranscript(for key: SessionTranscriptKey) throws -> CachedTranscript {
        if let value = cached[key] { return value }
        var transcript = SessionTranscript(key: key)
        for mutation in try store.loadMutations(for: key) {
            _ = transcript.apply(mutation)
        }
        let access = try acquireAccess(for: key)
        let value = CachedTranscript(transcript: transcript,
                                     pending: [],
                                     access: access,
                                     flushTask: nil)
        cached[key] = value
        return value
    }

    private func acquireAccess(for key: SessionTranscriptKey) throws -> TranscriptWriteAccess {
        do {
            return .writable(try store.acquireWriteLock(for: key, ownerPID: ownerPID))
        } catch FileSystemError.alreadyExists {
            let existingPID = try store.lockOwnerPID(for: key)
            guard let existingPID, !processIsRunning(existingPID) else {
                return .readOnly(ownerPID: existingPID)
            }
            store.releaseWriteLock(.init(url: ProjectPaths.transcriptLockURL(for: key)))
            return .writable(try store.acquireWriteLock(for: key, ownerPID: ownerPID))
        }
    }

    private func appendBuffered(_ mutation: TranscriptMutation,
                                to pending: inout [TranscriptMutation]) {
        guard case .appendThinking(let blockID, let delta, let recordedAt) = mutation,
              case .appendThinking(let previousID, let previousDelta, _) = pending.last,
              blockID == previousID else {
            pending.append(mutation)
            return
        }
        pending[pending.count - 1] = .appendThinking(
            blockID: blockID,
            delta: previousDelta + delta,
            recordedAt: recordedAt
        )
    }

    private func scheduleFlush(for key: SessionTranscriptKey) {
        guard var value = cached[key], value.flushTask == nil else { return }
        value.flushTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: Self.flushDebounce)
                try await self?.flush(key)
            } catch {
                await self?.clearFlushTask(for: key)
            }
        }
        cached[key] = value
    }

    private func clearFlushTask(for key: SessionTranscriptKey) {
        guard var value = cached[key] else { return }
        value.flushTask = nil
        cached[key] = value
    }
}

enum SessionTranscriptRepositoryError: Error, Sendable, Equatable {
    case locked(sessionID: String, ownerPID: Int32?)
}

private struct CachedTranscript {
    var transcript: SessionTranscript
    var pending: [TranscriptMutation]
    var access: TranscriptWriteAccess
    var flushTask: Task<Void, Never>?
}

private enum TranscriptWriteAccess {
    case writable(TranscriptWriteLock)
    case readOnly(ownerPID: Int32?)

    var ownerPID: Int32? {
        if case .readOnly(let ownerPID) = self { return ownerPID }
        return nil
    }
}
