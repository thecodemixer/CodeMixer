import Foundation
import AgentCore

/// Derives the chat workbench's turn / phase model from the flat `messages`
/// array. Nothing here is stored — `conversationTurns` is a computed
/// projection so it can never drift from the source of truth.
public extension EngineViewModel {

    /// One user prompt through its agent reply — the index rail's row unit.
    /// Spans every message from a `.user` bubble up to (excluding) the next
    /// one, so it covers thinking, prose, and tool-call markers for that turn.
    struct ConversationTurn: Sendable, Identifiable, Hashable {
        public enum Status: Sendable, Hashable {
            case running
            case done
            case failed
        }

        /// Sentinel for a leading turn with no user prompt yet (a cached or
        /// background session can open with assistant-only history).
        public static let leadingTurnID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

        /// The user bubble's id — stable across recomputation, and equal to
        /// the engine's `currentTurnID` for the live turn.
        public let id: UUID
        public let ordinal: Int
        public let promptText: String?
        /// Latest thinking text seen in this turn (live preview for the rail
        /// row; ignored once the turn is no longer live).
        public let thinkingPreview: String?
        /// True only while this is the live turn and its thinking is still streaming.
        public let isThinking: Bool
        public let toolCallIDs: [ToolCallID]
        public let status: Status
        /// File-level pipeline phase in effect when this turn started
        /// (Custom ACP only); `nil` until the first `sessionPhaseChanged`.
        /// Rail nesting uses phase message-index spans instead of this tag alone
        /// so a long-running turn can still appear under the live phase.
        public let phase: SessionPhase?
        /// Inclusive start / exclusive end into `messages` for this turn.
        public let messageRange: Range<Int>
        /// Message id to scroll the transcript lane to when this turn is selected.
        public let anchorMessageID: String

        public var toolCount: Int { toolCallIDs.count }
    }

    /// One concrete occurrence of a native phase marker in the rail. `phase.id`
    /// is the migration status (`reviewing`, `fixing`, …) and can repeat across
    /// rounds, so rail selection uses this occurrence id instead.
    struct RailPhaseOccurrence: Sendable, Identifiable, Hashable {
        public let id: String
        public let phase: SessionPhase
        public let markerIndex: Int
        public let round: Int
        public let isLive: Bool
    }

    /// Splits `messages` on `.user` boundaries. O(messages.count) per access:
    /// sessions stay in the hundreds of rows, well under a frame budget, so
    /// this trades a small, easily-verified linear scan for the complexity of
    /// tracking turn boundaries incrementally at every append site.
    var conversationTurns: [ConversationTurn] {
        guard !messages.isEmpty else { return [] }
        var turns: [ConversationTurn] = []
        var start = 0
        var ordinal = 0
        for (idx, message) in messages.enumerated() where idx > start {
            if case .user = message {
                turns.append(makeTurn(start: start, end: idx, ordinal: ordinal))
                ordinal += 1
                start = idx
            }
        }
        turns.append(makeTurn(start: start, end: messages.count, ordinal: ordinal))
        return turns
    }

    /// The newest turn — what the transcript/work lane show unless the user
    /// has pinned an older one via the rail.
    var liveTurnID: UUID? { conversationTurns.last?.id }

    /// `nil` `selectedTurnID` means "follow the live turn."
    var isFollowingLiveTurn: Bool { selectedTurnID == nil }

    /// The turn the transcript/work lane are scoped to right now.
    var effectiveSelectedTurn: ConversationTurn? {
        let turns = conversationTurns
        guard let selectedTurnID else { return turns.last }
        return turns.first { $0.id == selectedTurnID } ?? turns.last
    }

    func selectTurn(_ id: UUID) {
        selectedTurnID = (id == liveTurnID) ? nil : id
        // Phase-native sessions keep the expanded phase when a nested turn is
        // selected; clearing it would snap the rail back to the live phase.
        if !hasPhaseData {
            selectedPhaseID = nil
        }
    }

    func jumpToLiveTurn() {
        selectedTurnID = nil
        selectedPhaseID = nil
    }

    /// Pins a file-pipeline phase in the index rail (Custom ACP). Clears any
    /// turn pin so the transcript can jump to that phase's anchor message.
    /// Returns the message id the transcript should scroll to (including when
    /// selecting the live phase, which clears `selectedPhaseID`).
    @discardableResult
    func selectPhase(_ id: String) -> String? {
        let occurrenceID = railPhaseOccurrence(for: id)?.id ?? id
        // Selecting the live phase returns to follow-mode (same as selecting
        // the live turn). Older phases stay pinned until Jump-to-live.
        selectedPhaseID = (occurrenceID == livePhaseID) ? nil : occurrenceID
        selectedTurnID = nil
        return anchorMessageID(forPhaseID: occurrenceID)
    }

    /// Message id to scroll to when a phase header is selected.
    ///
    /// Uses the phase's native message-index span. Never anchors on
    /// `messages[nextPhaseStart]` for an empty span — that index belongs to
    /// the *next* phase (common for completion statuses like `migrated` that
    /// share an index with `reviewing`).
    func anchorMessageID(forPhaseID id: String) -> String? {
        guard let span = phaseMessageSpan(forPhaseID: id) else { return nil }
        for idx in span {
            if case .toolCall = messages[idx] { continue }
            return messages[idx].id
        }
        // Empty span: show the last visible message *before* this marker so
        // clicking a completion status still lands in that phase's content.
        if span.lowerBound > 0 {
            for idx in stride(from: span.lowerBound - 1, through: 0, by: -1) {
                if case .toolCall = messages[idx] { continue }
                return messages[idx].id
            }
        }
        return messages.last?.id
    }

    /// Message indexes visible in the transcript for a selected/live phase.
    /// Tool rows are skipped here because the work lane owns their chrome.
    /// Empty completion phases fall back to the same in-phase anchor policy as
    /// `anchorMessageID(forPhaseID:)` so selecting a phase never paints a blank
    /// transcript when useful context exists adjacent to its marker.
    func messageIndices(forPhaseID id: String) -> [Int] {
        guard let span = phaseMessageSpan(forPhaseID: id) else {
            return Array(messages.indices)
        }
        let visible = span.compactMap { idx -> Int? in
            guard idx >= 0, idx < messages.count else { return nil }
            if case .toolCall = messages[idx] { return nil }
            return idx
        }
        if !visible.isEmpty { return visible }
        guard let anchor = anchorMessageID(forPhaseID: id),
              let idx = messages.firstIndex(where: { $0.id == anchor }) else { return [] }
        return [idx]
    }

    /// Message-index span owned by a phase: `[marker, nextMarker)` — or through
    /// `messages.endIndex` for the still-open live phase. Native phase markers
    /// are the source of truth; turns are filtered against this span.
    func phaseMessageSpan(forPhaseID id: String) -> Range<Int>? {
        guard let occurrence = railPhaseOccurrence(for: id) else { return nil }
        let index = occurrence.markerIndex
        let start = phaseMarkers[index].messageIndex
        let end: Int
        if let next = phaseMarkers[(index + 1)...].first(where: { $0.phase.id != occurrence.phase.id }) {
            end = next.messageIndex
        } else {
            end = messages.count
        }
        return start..<max(start, end)
    }

    /// True once at least one `sessionPhaseChanged` has tagged this session —
    /// the rail is phase-native (Custom ACP / migration tool). Content-driven:
    /// absent any phase event, this is `false` and the rail falls back to
    /// per-turn.
    var hasPhaseData: Bool {
        phaseMarkers.contains { $0.messageIndex <= messages.count }
    }

    /// Ordered, consecutive-deduped phases from native `sessionPhaseChanged`
    /// markers. The rail's primary rows when `hasPhaseData` — not a projection
    /// over user-turn boundaries.
    var railPhases: [SessionPhase] {
        railPhaseOccurrences.map(\.phase)
    }

    /// Concrete phase occurrences for the rail. Consecutive duplicate statuses
    /// are collapsed as one occurrence, but the same status later in the run
    /// remains a distinct selectable row.
    var railPhaseOccurrences: [RailPhaseOccurrence] {
        let liveMarkerIndex = phaseMarkers.indices.last
        var occurrences: [RailPhaseOccurrence] = []
        var groupCounts: [SessionPhase.Group: Int] = [:]
        var lastPhaseID: String?
        for index in phaseMarkers.indices {
            let marker = phaseMarkers[index]
            guard marker.messageIndex <= messages.count,
                  marker.phase.id != lastPhaseID else { continue }
            groupCounts[marker.phase.group, default: 0] += 1
            occurrences.append(RailPhaseOccurrence(
                id: phaseOccurrenceID(markerIndex: index, phaseID: marker.phase.id),
                phase: marker.phase,
                markerIndex: index,
                round: groupCounts[marker.phase.group] ?? 1,
                isLive: index == liveMarkerIndex
            ))
            lastPhaseID = marker.phase.id
        }
        return occurrences
    }

    /// The newest phase marker — what the rail expands while following live.
    var livePhaseID: String? { railPhaseOccurrences.last?.id }

    /// `nil` `selectedPhaseID` means "follow the live phase."
    var isFollowingLivePhase: Bool { selectedPhaseID == nil }

    /// Phase the rail expands right now: pinned selection, else the live phase.
    var effectiveSelectedPhaseID: String? {
        selectedPhaseID ?? livePhaseID
    }

    /// Turns that belong to a phase by native message-index span.
    ///
    /// A real user turn appears under every phase its message range overlaps
    /// (so clicking Migrating still shows a pipeline turn that started in Plan).
    /// Migration-tool sessions often have only a synthetic leading turn — those
    /// are clipped into a phase-local row from the messages inside the span so
    /// expanding a phase is never empty when that phase produced work.
    func turns(forPhaseID id: String) -> [ConversationTurn] {
        guard let span = phaseMessageSpan(forPhaseID: id), !span.isEmpty else { return [] }
        let occurrence = railPhaseOccurrence(for: id)
        let phase = occurrence?.phase
        var seen = Set<UUID>()
        var result: [ConversationTurn] = []

        for turn in conversationTurns {
            guard turn.messageRange.overlaps(span) else { continue }
            if turn.id == ConversationTurn.leadingTurnID, turn.promptText == nil {
                if let local = makePhaseLocalTurn(phaseID: occurrence?.id ?? id, phase: phase, span: span),
                   seen.insert(local.id).inserted {
                    result.append(local)
                }
                continue
            }
            guard seen.insert(turn.id).inserted else { continue }
            result.append(turn)
        }

        if result.isEmpty,
           let local = makePhaseLocalTurn(phaseID: occurrence?.id ?? id, phase: phase, span: span) {
            result.append(local)
        }
        return result
    }

    /// Turns nested under the rail's expanded phase only.
    var turnsForEffectivePhase: [ConversationTurn] {
        guard let id = effectiveSelectedPhaseID else { return [] }
        return turns(forPhaseID: id)
    }

    /// Resolved tool-call entries for the transcript's effective phase (or
    /// the effective turn when the session has no phase data). Powers the
    /// work lane so clicking a phase refreshes tools on the right, not just
    /// prose.
    var effectiveWorkToolCalls: [ToolCallEntry] {
        if hasPhaseData, let id = effectiveSelectedPhaseID {
            return toolCalls(forPhaseID: id)
        }
        return toolCalls(for: effectiveSelectedTurn)
    }

    /// Tool calls whose markers fall inside a phase's message-index span.
    func toolCalls(forPhaseID id: String) -> [ToolCallEntry] {
        guard let span = phaseMessageSpan(forPhaseID: id) else { return [] }
        return resolveToolCalls(in: span)
    }

    private func toolCalls(for turn: ConversationTurn?) -> [ToolCallEntry] {
        guard let turn else { return [] }
        return turn.toolCallIDs.compactMap { callID in
            activeToolCalls.first { $0.id == callID }
        }
    }

    private func resolveToolCalls(in span: Range<Int>) -> [ToolCallEntry] {
        var entries: [ToolCallEntry] = []
        for idx in span where idx < messages.count {
            guard case .toolCall(let callID) = messages[idx],
                  let entry = activeToolCalls.first(where: { $0.id == callID }) else { continue }
            entries.append(entry)
        }
        return entries
    }

    func railPhaseOccurrence(for id: String) -> RailPhaseOccurrence? {
        railPhaseOccurrences.first { $0.id == id }
            ?? railPhaseOccurrences.first { $0.phase.id == id }
    }

    /// Resolves a rail turn id from either the global turn list or the
    /// currently expanded phase's (possibly phase-local) rows.
    func turn(forID id: UUID) -> ConversationTurn? {
        if let turn = conversationTurns.first(where: { $0.id == id }) {
            return turn
        }
        return turnsForEffectivePhase.first(where: { $0.id == id })
    }

    /// `(phase, wall-clock duration)` for every completed phase this session,
    /// oldest first. The last marker is still open — it is not included here.
    var completedPhaseDurations: [(phase: SessionPhase, duration: TimeInterval)] {
        guard phaseMarkers.count > 1 else { return [] }
        return (0..<(phaseMarkers.count - 1)).map { i in
            let start = phaseMarkers[i]
            let end = phaseMarkers[i + 1]
            return (start.phase, end.at.timeIntervalSince(start.at))
        }
    }

    /// Rough ETA for the current phase, averaged from this session's prior
    /// phases in the same group (e.g. earlier "Review" rounds). `nil` until a
    /// prior same-group phase has completed — no fabricated precision.
    var currentPhaseETA: TimeInterval? {
        guard let current = phaseMarkers.last else { return nil }
        let sameGroup = completedPhaseDurations
            .filter { $0.phase.group == current.phase.group }
            .map(\.duration)
        guard !sameGroup.isEmpty else { return nil }
        return sameGroup.reduce(0, +) / Double(sameGroup.count)
    }

    /// How many times a phase in `group` has occurred this session, up to and
    /// including `phase` — the rail's "Fix round 2" / "Review 2" badge.
    func phaseGroupOccurrence(of phase: SessionPhase) -> Int {
        var count = 0
        for marker in phaseMarkers {
            if marker.phase.group == phase.group { count += 1 }
            if marker.phase.id == phase.id { break }
        }
        return max(count, 1)
    }

    // MARK: - Peripheral progress (title-bar readout + rail hairline)

    /// `.navigationSubtitle` text next to the project name — the "glanceable
    /// across apps" peripheral progress readout. `nil` for non-ACP sessions
    /// (content-driven: no phase data, no readout).
    var currentPhaseNavigationSubtitle: String? {
        guard let occurrence = railPhaseOccurrences.last else { return nil }
        let phase = occurrence.phase
        let round = occurrence.round
        return round > 1 ? "\(phase.label) · Round \(round)" : phase.label
    }

    /// 0...1 fill fraction for the rail's edge hairline, positioned by the
    /// current phase's *group* (Plan/Migrate/Review/Fix/Verify) rather than
    /// the vendor's finer-grained status — keeps the hairline agent-agnostic
    /// instead of overfitting to one migration tool's status count.
    var currentPhaseProgressFraction: Double? {
        guard let group = phaseMarkers.last?.phase.group else { return nil }
        let order: [SessionPhase.Group] = [.plan, .migrate, .review, .fix, .verify]
        guard let idx = order.firstIndex(of: group) else { return nil }
        return Double(idx) / Double(order.count - 1)
    }

    /// True when the given phase group currently has a live, unresolved
    /// permission prompt parked against it — the rail header's attention
    /// badge (reuses the same signal as the sidebar's attention dot rather
    /// than a second bookkeeping map).
    func phaseGroupNeedsAttention(_ group: SessionPhase.Group) -> Bool {
        guard activePendingPermission != nil else { return false }
        guard let latest = phaseMarkers.last?.phase else { return false }
        return latest.group == group && latest.id == "needs-human-review"
    }

    // MARK: - While-you-were-away recap

    /// Turns/messages that landed since this session was last foregrounded,
    /// or `nil` if there is nothing to recap (first open, or no new activity).
    struct AwayRecap: Sendable, Equatable {
        public let turnsCompleted: Int
        public let filesChanged: Int
        public let latestPhase: SessionPhase?
    }

    /// Captures "now" as the last-seen point for `sessionID`. Call when a
    /// session is foregrounded (selected, or the app returns to `.active`)
    /// after computing `recapSinceLastSeen`.
    func markSessionSeenNow() {
        guard let sessionID else { return }
        lastSeenMarkerBySession[sessionID] = (messages.count, clock.now())
    }

    /// Non-nil only when returning to a session that already had a last-seen
    /// marker and has grown since. Auto-fades in the UI; never blocks.
    var recapSinceLastSeen: AwayRecap? {
        guard let sessionID, let marker = lastSeenMarkerBySession[sessionID],
              messages.count > marker.messageCount else { return nil }
        let newMessages = messages[marker.messageCount...]
        let newTurns = newMessages.reduce(into: 0) { count, message in
            if case .user = message { count += 1 }
        }
        guard newTurns > 0 else { return nil }
        return AwayRecap(
            turnsCompleted: newTurns,
            filesChanged: changedFiles.count,
            latestPhase: phaseMarkers.last?.phase
        )
    }

    // MARK: - Private

    /// Clips messages inside a phase span into one rail row when the session
    /// has no per-phase user prompts (Custom ACP / migration tool).
    private func makePhaseLocalTurn(phaseID: String,
                                    phase: SessionPhase?,
                                    span: Range<Int>) -> ConversationTurn? {
        guard !span.isEmpty, span.lowerBound < messages.count else { return nil }
        let end = min(span.upperBound, messages.count)
        let slice = messages[span.lowerBound..<end]

        var promptText: String?
        var thinkingPreview: String?
        var isThinking = false
        var toolCallIDs: [ToolCallID] = []
        var anyToolFailed = false
        var hasContent = false
        var anchorMessageID: String?

        for message in slice {
            if case .toolCall = message {
                // Keep scanning; tools count but are not scroll anchors.
            } else if anchorMessageID == nil {
                anchorMessageID = message.id
            }
            switch message {
            case .user(_, let text):
                if promptText == nil { promptText = text }
                hasContent = true
            case .assistant(_, let text), .assistantStreaming(_, let text):
                if promptText == nil {
                    promptText = Self.railPreview(text)
                }
                hasContent = true
            case .thinkingChunk(_, let text):
                thinkingPreview = text
                isThinking = true
                if promptText == nil { promptText = Self.railPreview(text) }
                hasContent = true
            case .thinkingComplete(_, let text, _):
                thinkingPreview = text
                isThinking = false
                if promptText == nil { promptText = Self.railPreview(text) }
                hasContent = true
            case .toolCall(let callID):
                toolCallIDs.append(callID)
                hasContent = true
                if let entry = activeToolCalls.first(where: { $0.id == callID }),
                   entry.finished, !entry.success {
                    anyToolFailed = true
                }
            case .a2uiSurface:
                hasContent = true
            case .clientAction:
                break
            }
        }
        guard hasContent else { return nil }

        let isLive = end == messages.count && activity != .idle
        let status: ConversationTurn.Status = anyToolFailed ? .failed : (isLive ? .running : .done)
        return ConversationTurn(
            id: Self.phaseScopedTurnID(phaseID),
            ordinal: 0,
            promptText: promptText,
            thinkingPreview: thinkingPreview,
            isThinking: isThinking && isLive,
            toolCallIDs: toolCallIDs,
            status: status,
            phase: phase,
            messageRange: span.lowerBound..<end,
            anchorMessageID: anchorMessageID
                ?? messages[span.lowerBound].id
        )
    }

    private static func railPreview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 72 else { return trimmed }
        return String(trimmed.prefix(72)) + "…"
    }

    /// Stable id so phase-local rows survive recomputation and ForEach identity.
    private static func phaseScopedTurnID(_ phaseID: String) -> UUID {
        var bytes = [UInt8](repeating: 0xA1, count: 16)
        let payload = Array(phaseID.utf8)
        for (offset, byte) in payload.enumerated() {
            bytes[offset % 16] ^= byte
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func phaseOccurrenceID(markerIndex: Int, phaseID: String) -> String {
        "phase-\(markerIndex)-\(phaseID)"
    }

    private func makeTurn(start: Int, end: Int, ordinal: Int) -> ConversationTurn {
        let slice = messages[start..<end]
        var promptText: String?
        var thinkingPreview: String?
        var isThinking = false
        var toolCallIDs: [ToolCallID] = []
        var anyToolFailed = false

        for message in slice {
            switch message {
            case .user(_, let text):
                if promptText == nil { promptText = text }
            case .thinkingChunk(_, let text):
                thinkingPreview = text
                isThinking = true
            case .thinkingComplete(_, let text, _):
                thinkingPreview = text
                isThinking = false
            case .toolCall(let callID):
                toolCallIDs.append(callID)
                if let entry = activeToolCalls.first(where: { $0.id == callID }),
                   entry.finished, !entry.success {
                    anyToolFailed = true
                }
            case .assistant, .assistantStreaming, .clientAction, .a2uiSurface:
                break
            }
        }

        let id: UUID
        if let first = slice.first, case .user(let bubbleID, _) = first {
            id = bubbleID
        } else {
            id = ConversationTurn.leadingTurnID
        }

        let isLive = end == messages.count && activity != .idle
        let status: ConversationTurn.Status = anyToolFailed ? .failed : (isLive ? .running : .done)

        return ConversationTurn(
            id: id,
            ordinal: ordinal,
            promptText: promptText,
            thinkingPreview: thinkingPreview,
            isThinking: isThinking && isLive,
            toolCallIDs: toolCallIDs,
            status: status,
            phase: phaseTag(atOrBefore: start),
            messageRange: start..<end,
            anchorMessageID: slice.first?.id ?? ConversationTurn.leadingTurnID.uuidString
        )
    }

    private func phaseTag(atOrBefore messageIndex: Int) -> SessionPhase? {
        var latest: SessionPhase?
        for marker in phaseMarkers where marker.messageIndex <= messageIndex {
            latest = marker.phase
        }
        return latest
    }
}
