/// Owns the durable, semantic conversation state for one session. The
/// repository serializes mutation; this value owns folding and projections.
import A2UICore
import AgentProtocol
import Foundation

struct SessionTranscript: Sendable {
    static let replayEntryLimit = 500

    let key: SessionTranscriptKey
    private(set) var entries: [TranscriptEntry]
    private(set) var changedFiles: [ChangedFile]
    /// Canonical, generation-keyed A2UI surfaces derived from the folded
    /// `.a2uiSurface` entries — the same shape `AgentEngine+A2UI` reads when
    /// resolving a trusted client action against the durable surface.
    private(set) var a2uiSurfaces: [String: A2UISurfaceState]
    /// Highest generation ever assigned per surfaceId, preserved across
    /// delete so recreate keeps bumping forward. Derived purely from
    /// surviving entries on rebuild — see note on `rebuildIndexes()`.
    private(set) var a2uiRetiredGenerations: [String: Int]
    private var userIndexesByID: [String: Int]
    private var assistantIndexesByBlockID: [String: Int]
    private var thinkingIndexesByID: [UUID: Int]
    private var toolIndexesByID: [String: Int]
    private var fileIndexesByPath: [String: Int]
    private var a2uiSurfaceIndexesByID: [String: Int]

    init(key: SessionTranscriptKey,
         entries: [TranscriptEntry] = [],
         changedFiles: [ChangedFile] = []) {
        self.key = key
        self.entries = entries
        self.changedFiles = changedFiles
        self.a2uiSurfaces = [:]
        self.a2uiRetiredGenerations = [:]
        self.userIndexesByID = [:]
        self.assistantIndexesByBlockID = [:]
        self.thinkingIndexesByID = [:]
        self.toolIndexesByID = [:]
        self.fileIndexesByPath = [:]
        self.a2uiSurfaceIndexesByID = [:]
        rebuildIndexes()
    }

    var truncatedEntryCount: Int {
        max(0, entries.count - Self.replayEntryLimit)
    }

    @discardableResult
    mutating func apply(_ mutation: TranscriptMutation) -> Bool {
        if applyConversation(mutation) { return true }
        if applyTool(mutation) { return true }
        return applyPeripheral(mutation)
    }

    private mutating func applyConversation(_ mutation: TranscriptMutation) -> Bool {
        switch mutation {
        case .appendUser(let id, let text, let recordedAt):
            return appendUser(id: id, text: text, recordedAt: recordedAt)
        case .replaceUser(let id, let text, _):
            return replaceUser(id: id, text: text)
        case .finalizeAssistant(let id, let blockID, let text, let recordedAt):
            return finalizeAssistant(id: id,
                                     blockID: blockID,
                                     text: text,
                                     recordedAt: recordedAt)
        case .appendThinking(let blockID, let delta, let recordedAt):
            return appendThinking(blockID: blockID, delta: delta, recordedAt: recordedAt)
        case .completeThinking(let blockID, let durationMS, _):
            return completeThinking(blockID: blockID, durationMS: durationMS)
        default:
            return false
        }
    }

    private mutating func applyTool(_ mutation: TranscriptMutation) -> Bool {
        switch mutation {
        case .startTool(let id, let name, let input, let startedAt):
            return startTool(id: id, name: name, input: input, startedAt: startedAt)
        case .updateTool(let id, let progress, _):
            return updateTool(id: id, progress: progress)
        case .finishTool(let id, let success, let output, let durationMS, _):
            return finishTool(id: id,
                              success: success,
                              output: output,
                              durationMS: durationMS)
        default:
            return false
        }
    }

    private mutating func applyPeripheral(_ mutation: TranscriptMutation) -> Bool {
        switch mutation {
        case .touchFile(let file, let kind, let recordedAt):
            return touchFile(file, kind: kind, recordedAt: recordedAt)
        case .removeChangedFile(let file, _):
            return removeChangedFile(file)
        case .reconcileChangedFiles(let files, _):
            return reconcileChangedFiles(with: files)
        case .changePhase(let sessionID, let phase, let recordedAt):
            return append(.phase(sessionID: sessionID, phase: phase),
                          id: "phase:\(sessionID):\(phase.id):\(entries.count)",
                          recordedAt: recordedAt)
        case .appendClientAction(let action, let recordedAt):
            return append(.clientAction(action),
                          id: "action:\(action.id.uuidString)",
                          recordedAt: recordedAt)
        case .truncateAfterUser(let id, _):
            return truncate(afterUserTurnID: id)
        case .applyA2UIBatch(let batch, let recordedAt):
            return applyA2UIBatch(batch, recordedAt: recordedAt)
        default:
            return false
        }
    }

    /// Runs `batch` through `A2UISurfaceReducer` against the transcript's own
    /// canonical surface set, then folds every touched surface into its
    /// single durable `.a2uiSurface` entry (create/update in place; delete
    /// removes the entry — see `TranscriptBlock.a2uiSurface`).
    private mutating func applyA2UIBatch(_ batch: A2UIServerBatch, recordedAt: Date) -> Bool {
        let result = A2UISurfaceReducer.apply(batch,
                                              to: a2uiSurfaces,
                                              retiredGenerations: a2uiRetiredGenerations,
                                              at: recordedAt)
        a2uiRetiredGenerations = result.retiredGenerations
        let appliedIndexes = Set(result.outcomes.filter(\.applied).map(\.index))
        guard !appliedIndexes.isEmpty else { return false }

        var deletedIDs: Set<String> = []
        var touchedIDs: [String] = []
        for item in batch.items where appliedIndexes.contains(item.index) {
            guard let message = item.message else { continue }
            if case .deleteSurface(let surfaceID) = message {
                deletedIDs.insert(surfaceID)
            } else {
                touchedIDs.append(message.surfaceID)
            }
        }

        a2uiSurfaces = result.surfaces
        if !deletedIDs.isEmpty {
            entries.removeAll { entry in
                if case .a2uiSurface(let state) = entry.block { return deletedIDs.contains(state.surfaceID) }
                return false
            }
        }
        for surfaceID in touchedIDs where !deletedIDs.contains(surfaceID) {
            guard let state = a2uiSurfaces[surfaceID] else { continue }
            if let index = a2uiSurfaceIndexesByID[surfaceID], index < entries.count,
               case .a2uiSurface(let existing) = entries[index].block, existing.surfaceID == surfaceID {
                entries[index].block = .a2uiSurface(state)
            } else {
                entries.append(.init(id: .init(rawValue: "a2ui:\(surfaceID)"),
                                     recordedAt: recordedAt,
                                     block: .a2uiSurface(state)))
            }
        }
        rebuildIndexes()
        return true
    }

    @discardableResult
    mutating func truncate(afterUserTurnID id: String) -> Bool {
        guard let index = entries.lastIndex(where: {
            if case .user(let entryID, _) = $0.block { return entryID == id }
            return false
        }), index < entries.index(before: entries.endIndex) else { return false }
        entries.removeSubrange(entries.index(after: index)...)
        rebuildIndexes()
        return true
    }

    @discardableResult
    mutating func reconcileChangedFiles(with gitPaths: [ChangedFile]) -> Bool {
        let reconciled = ChangedFilesReconciler.reconcile(
            current: changedFiles,
            gitPaths: gitPaths
        ).next
        guard reconciled != changedFiles else { return false }
        changedFiles = reconciled
        return true
    }

    func replayEvents() -> [AgentEvent] {
        entries.suffix(Self.replayEntryLimit).flatMap { entry in
            events(for: entry.block)
        }
    }

    func snapshotMessages() -> [SnapshotService.SnapshotMessage] {
        entries.suffix(Self.replayEntryLimit).compactMap { entry in
            switch entry.block {
            case .user(_, let text):
                return .init(role: .user, text: text, timestamp: entry.recordedAt)
            case .assistant(_, _, let text):
                return .init(role: .assistant, text: text, timestamp: entry.recordedAt)
            case .clientAction(let action):
                let detail = action.detail.map { " — \($0)" } ?? ""
                return .init(role: .action,
                             text: action.title + detail,
                             timestamp: entry.recordedAt)
            case .a2uiSurface(let state):
                guard state.isRenderable else { return nil }
                return .init(role: .assistant,
                             text: A2UITextSummary.summary(for: state),
                             timestamp: entry.recordedAt)
            default:
                return nil
            }
        }
    }

    private mutating func appendUser(id: String, text: String, recordedAt: Date) -> Bool {
        let hasID = userIndexesByID[id] != nil
        let repeatsLastUser = entries.last.map {
            if case .user(_, let existingText) = $0.block { return existingText == text }
            return false
        } ?? false
        guard !hasID, !repeatsLastUser else { return false }
        return append(.user(id: id, text: text),
                      id: "user:\(id)",
                      recordedAt: recordedAt)
    }

    private mutating func replaceUser(id: String, text: String) -> Bool {
        guard let index = userIndexesByID[id],
              entries[index].block != .user(id: id, text: text) else { return false }
        entries[index].block = .user(id: id, text: text)
        return true
    }

    private mutating func finalizeAssistant(id: String,
                                            blockID: String,
                                            text: String,
                                            recordedAt: Date) -> Bool {
        let block = TranscriptBlock.assistant(id: id, blockID: blockID, text: text)
        if let index = assistantIndexesByBlockID[blockID] {
            guard entries[index].block != block else { return false }
            entries[index].block = block
            return true
        }
        return append(block,
                      id: "assistant:\(blockID)",
                      recordedAt: recordedAt)
    }

    private mutating func appendThinking(blockID: UUID,
                                         delta: String,
                                         recordedAt: Date) -> Bool {
        if let index = thinkingIndex(blockID) {
            guard case .thinking(_, let text, let durationMS) = entries[index].block else {
                return false
            }
            guard !delta.isEmpty else { return false }
            let block = TranscriptBlock.thinking(
                blockID: blockID,
                text: text + delta,
                durationMS: durationMS
            )
            entries[index].block = block
            return true
        }
        return append(.thinking(blockID: blockID, text: delta, durationMS: nil),
                      id: "thinking:\(blockID.uuidString)",
                      recordedAt: recordedAt)
    }

    private mutating func completeThinking(blockID: UUID, durationMS: Int) -> Bool {
        guard let index = thinkingIndex(blockID),
              case .thinking(_, let text, let existingDuration) = entries[index].block,
              existingDuration != durationMS else { return false }
        let block = TranscriptBlock.thinking(
            blockID: blockID,
            text: text,
            durationMS: durationMS
        )
        entries[index].block = block
        return true
    }

    private mutating func startTool(id: String,
                                    name: String,
                                    input: ToolInput,
                                    startedAt: Date) -> Bool {
        let tool = ToolTranscript(id: id,
                                  name: name,
                                  input: input,
                                  startedAt: startedAt,
                                  progress: nil,
                                  success: nil,
                                  output: nil,
                                  durationMS: nil)
        if let index = toolIndex(id) {
            guard entries[index].block != .tool(tool) else { return false }
            entries[index].block = .tool(tool)
            return true
        } else {
            return append(.tool(tool), id: "tool:\(id)", recordedAt: startedAt)
        }
    }

    private mutating func updateTool(id: String, progress: ToolProgress) -> Bool {
        guard let index = toolIndex(id),
              case .tool(var tool) = entries[index].block,
              tool.progress != progress else { return false }
        tool.progress = progress
        entries[index].block = .tool(tool)
        return true
    }

    private mutating func finishTool(id: String,
                                     success: Bool,
                                     output: ToolOutput,
                                     durationMS: Int) -> Bool {
        guard let index = toolIndex(id),
              case .tool(var tool) = entries[index].block else { return false }
        let previous = tool
        tool.success = success
        tool.output = output
        tool.durationMS = durationMS
        guard tool != previous else { return false }
        entries[index].block = .tool(tool)
        return true
    }

    private mutating func touchFile(_ file: ChangedFile,
                                    kind: FileChangeKind,
                                    recordedAt: Date) -> Bool {
        let addedFile = !changedFiles.contains(file)
        if addedFile {
            changedFiles.append(file)
        }
        guard fileIndexesByPath[file.relativePath] == nil else { return addedFile }
        return append(.file(relativePath: file.relativePath, kind: kind),
                      id: "file:\(file.relativePath)",
                      recordedAt: recordedAt)
    }

    private mutating func removeChangedFile(_ file: ChangedFile) -> Bool {
        let previousFileCount = changedFiles.count
        let previousEntryCount = entries.count
        changedFiles.removeAll { $0 == file }
        entries.removeAll {
            if case .file(let path, _) = $0.block { return path == file.relativePath }
            return false
        }
        let changed = changedFiles.count != previousFileCount || entries.count != previousEntryCount
        if entries.count != previousEntryCount {
            rebuildIndexes()
        }
        return changed
    }

    private mutating func append(_ block: TranscriptBlock,
                                 id: String,
                                 recordedAt: Date) -> Bool {
        entries.append(.init(id: .init(rawValue: id),
                             recordedAt: recordedAt,
                             block: block))
        index(block, at: entries.index(before: entries.endIndex))
        return true
    }

    private func thinkingIndex(_ id: UUID) -> Int? {
        thinkingIndexesByID[id]
    }

    private func toolIndex(_ id: String) -> Int? {
        toolIndexesByID[id]
    }

    /// Re-derives every index dict, including `a2uiSurfaces`, purely from the
    /// surviving `entries`. Because each `.a2uiSurface` entry already holds
    /// the fully-folded state at that point, this is exact — with one
    /// accepted limitation: `a2uiRetiredGenerations` for a surfaceId whose
    /// only entry was truncated away resets to whatever surviving entries
    /// show (0 if none survive), so a rare post-truncate recreate of that
    /// exact id could reuse a generation number. Truncation already discards
    /// that surface's history, so this is consistent with treating it as
    /// a clean slate rather than a correctness bug.
    private mutating func rebuildIndexes() {
        userIndexesByID.removeAll(keepingCapacity: true)
        assistantIndexesByBlockID.removeAll(keepingCapacity: true)
        thinkingIndexesByID.removeAll(keepingCapacity: true)
        toolIndexesByID.removeAll(keepingCapacity: true)
        fileIndexesByPath.removeAll(keepingCapacity: true)
        a2uiSurfaceIndexesByID.removeAll(keepingCapacity: true)
        a2uiSurfaces.removeAll(keepingCapacity: true)
        a2uiRetiredGenerations.removeAll(keepingCapacity: true)
        for (index, entry) in entries.enumerated() {
            self.index(entry.block, at: index)
        }
    }

    private mutating func index(_ block: TranscriptBlock, at index: Int) {
        switch block {
        case .user(let id, _):
            userIndexesByID[id] = index
        case .assistant(_, let blockID, _):
            assistantIndexesByBlockID[blockID] = index
        case .thinking(let blockID, _, _):
            thinkingIndexesByID[blockID] = index
        case .tool(let tool):
            toolIndexesByID[tool.id] = index
        case .file(let relativePath, _):
            fileIndexesByPath[relativePath] = index
        case .a2uiSurface(let state):
            a2uiSurfaceIndexesByID[state.surfaceID] = index
            a2uiSurfaces[state.surfaceID] = state
            a2uiRetiredGenerations[state.surfaceID] = max(a2uiRetiredGenerations[state.surfaceID] ?? 0,
                                                          state.generation)
        case .phase, .clientAction:
            break
        }
    }

    private func events(for block: TranscriptBlock) -> [AgentEvent] {
        switch block {
        case .user(let id, let text):
            return [.userTurn(id: id, text: text)]
        case .assistant(let id, let blockID, let text):
            return [.assistantText(id: id, blockID: blockID, text: text, isFinal: true)]
        case .thinking(let blockID, let text, let durationMS):
            var events: [AgentEvent] = [.thinkingChunk(blockID: blockID, delta: text)]
            if let durationMS {
                events.append(.thinkingComplete(blockID: blockID,
                                                duration: .milliseconds(durationMS)))
            }
            return events
        case .tool(let tool):
            var events: [AgentEvent] = [
                .toolStart(id: tool.id,
                           name: tool.name,
                           input: tool.input,
                           startedAt: tool.startedAt)
            ]
            if let progress = tool.progress {
                let id = UUID(uuidString: tool.id) ?? StableID.uuid(from: tool.id)
                events.append(.toolProgress(callID: id, progress: progress))
            }
            if let success = tool.success,
               let output = tool.output,
               let durationMS = tool.durationMS {
                events.append(.toolEnd(id: tool.id,
                                       success: success,
                                       output: output,
                                       durationMS: durationMS))
            }
            return events
        case .file(let relativePath, let kind):
            let url = relativePath.hasPrefix("/")
                ? URL(fileURLWithPath: relativePath)
                : key.projectRoot.appendingPathComponent(relativePath)
            return [.fileTouched(url, kind: kind)]
        case .phase(let sessionID, let phase):
            return [.sessionPhaseChanged(sessionID: sessionID, phase: phase)]
        case .clientAction(let action):
            return [.clientAction(action)]
        case .a2uiSurface(let state):
            // Synthesizes a full create/components/data sequence rather than
            // replaying original deltas, so a late-joining client reconstructs
            // this surface correctly even when its deltas fell outside
            // `replayEntryLimit` (plan §4).
            let items = state.synthesizedReplayMessages().enumerated().map {
                A2UIServerBatch.Item(index: $0.offset, message: $0.element)
            }
            return [.a2uiBatch(A2UIServerBatch(
                agentID: state.agentID,
                transcriptKey: .init(projectRootPath: key.projectRoot.path,
                                     namespace: key.namespace,
                                     sessionID: key.sessionID),
                resourceURI: "a2ui://replay/\(state.surfaceID)",
                items: items,
                recordedAt: state.updatedAt
            ))]
        }
    }
}
