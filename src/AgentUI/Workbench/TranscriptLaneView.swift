import A2UICore
import SwiftUI

/// The reading column: user prompts, prominent live thinking, and assistant
/// prose. Tool cards live in `WorkLaneView` instead — dropping them from this
/// scroll is the workbench's primary fix for "too much scrolling."
///
/// Lifts `ConversationView`'s proven scroll machinery (`ScrollViewReader` +
/// `LazyVStack`, `ConversationAutoScrollController`, Cmd+F search, banners,
/// empty-state hero) intact. Two behavioral changes: dropping `.toolCall`
/// from the switch (its grouping job — `turnSpine` — moves to the index
/// rail, which groups by turn/phase natively) and routing the live turn's
/// latest thinking block through `ThinkingFocusView`.
struct TranscriptLaneView: View {
    @Bindable var model: EngineViewModel
    var tts: TTSService?
    @Binding var searchVisible: Bool
    @Binding var selectedCodePreview: WorkbenchCodePreview?

    @State private var searchQuery: String = ""
    @State private var matchIndices: [Int] = []
    @State private var currentMatchIndex: Int = 0
    @State private var autoScroll = ConversationAutoScrollController()
    @State private var lastAutoScrolledTextLength = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let fraction = model.currentPhaseProgressFraction {
                PeripheralProgressHairline(fraction: fraction)
            }

            if searchVisible {
                ConversationSearchBar(
                    query: $searchQuery,
                    matchCount: matchIndices.count,
                    currentIndex: currentMatchIndex,
                    onNext: searchNext,
                    onPrev: searchPrev,
                    onDismiss: { searchVisible = false; searchQuery = "" }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let recap = model.recapSinceLastSeen {
                AwayRecapBanner(recap: recap) { model.markSessionSeenNow() }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if autoScroll.showsPausedBanner, !isConversationEmpty {
                pausedScrollBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if isConversationEmpty {
                ConversationEmptyState(workspace: model.workspace,
                                       hasWorkspaceProjects: !model.projects.isEmpty,
                                       sessionActivation: model.sessionActivation,
                                       historyUnavailable: importedHistoryIsUnavailable)
                    .background(Theme.surface.canvas)
                    .transition(.opacity)
            } else {
                transcriptScroll
            }
        }
        .background(Theme.surface.canvas)
        .overlay(alignment: .topTrailing) {
            StatusPill(status: model.status,
                       substate: model.activity,
                       onCancel: { model.cancelCurrentTurn() })
                .padding(.top, Theme.spacing.s12)
                .padding(.trailing, Theme.spacing.s16)
        }
        .animation(Theme.motion.resolve(Theme.motion.changing, reduceMotion: reduceMotion),
                   value: isConversationEmpty)
        .animation(Theme.motion.resolve(Theme.motion.changing, reduceMotion: reduceMotion),
                   value: autoScroll.isFollowing)
        .onChange(of: model.sessionID) { _, _ in
            autoScroll.resetForNewSession()
            lastAutoScrolledTextLength = 0
            model.markSessionSeenNow()
        }
        .onAppear { model.markSessionSeenNow() }
        .onKeyPress(.escape) {
            if searchVisible {
                searchVisible = false
                searchQuery = ""
                return .handled
            }
            if selectedCodePreview != nil {
                selectedCodePreview = nil
                return .handled
            }
            return .ignored
        }
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let focusThinkingIndex = focusThinkingRowIndex
                    let lastUserIndex = lastUserMessageIndex
                    ForEach(transcriptMessageIndices, id: \.self) { idx in
                        let message = model.messages[idx]
                        // Tool-call markers carry zero chrome here — they render
                        // in the work lane instead, and skipping their padding
                        // avoids a phantom gap where a card used to sit.
                        if !isToolCall(message) {
                            rowView(for: message,
                                    idx: idx,
                                    focusThinkingIndex: focusThinkingIndex,
                                    lastUserIndex: lastUserIndex)
                                .id(message.id)
                                .padding(.horizontal, Theme.spacing.s16)
                                .background(matchIndices.contains(idx) && idx == safeCurrentMatchIdx
                                            ? Theme.signal.info.opacity(Theme.opacity.quiet) : Color.clear)
                                .padding(.bottom, Theme.spacing.s16)
                        }
                    }
                    Color.clear
                        .frame(height: Theme.spacing.s48)
                        .accessibilityHidden(true)
                        .id(ConversationScrollTarget.bottom)
                }
                // Keep the transcript's first content close to the rail's
                // phase list. A large top inset made the second lane sit
                // visibly lower than the phase rail and hid early phase text
                // under the top chrome when auto-scroll was paused.
                .padding(.top, Theme.spacing.s8)
                .padding(.bottom, Theme.spacing.s24)
                .frame(maxWidth: Theme.layout.messageMaxWidth)
                .frame(maxWidth: .infinity, alignment: .center)
                .background {
                    ScrollActivityObserver(controller: autoScroll)
                        .accessibilityHidden(true)
                }
            }
            .background(Theme.surface.canvas)
            .onChange(of: model.messages.last?.id) { _, latest in
                guard latest != nil, !searchVisible else { return }
                lastAutoScrolledTextLength = model.messages.last?.textContent?.count ?? 0
                guard shouldFollowLivePhase else { return }
                if isLastMessageFromUser {
                    resumeFollowing(proxy: proxy)
                    return
                }
                guard autoScroll.isFollowing else { return }
                scrollToConversationEnd(proxy: proxy, animated: true)
            }
            .onChange(of: model.messages.last?.textContent) { _, text in
                guard !searchVisible,
                      model.messages.last?.id != nil,
                      autoScroll.isFollowing,
                      shouldFollowLivePhase else { return }
                let length = text?.count ?? 0
                guard shouldScrollForStreamingText(length: length, text: text) else { return }
                lastAutoScrolledTextLength = length
                scrollToConversationEnd(proxy: proxy, animated: false)
            }
            .onChange(of: searchQuery) { _, q in
                runSearch(q)
                scrollToCurrentMatch(proxy: proxy)
            }
            .onChange(of: currentMatchIndex) { _, _ in
                scrollToCurrentMatch(proxy: proxy)
            }
            .onChange(of: autoScroll.isFollowing) { wasFollowing, isFollowing in
                guard !wasFollowing, isFollowing, !searchVisible else { return }
                scrollToConversationEnd(proxy: proxy, animated: true)
            }
            .onChange(of: model.selectedTurnID) { _, turnID in
                // Only scroll when pinning a turn. Clearing the pin (nil) happens
                // inside selectPhase / jumpToLive and must not yank the transcript
                // to the live turn — that looked like "clicked phase N, landed on N+1".
                guard let turnID,
                      let turn = model.turn(forID: turnID) else { return }
                autoScroll.beginProgrammaticScroll()
                withAnimation(Theme.motion.gentle) {
                    proxy.scrollTo(turn.anchorMessageID, anchor: .top)
                }
            }
            .onChange(of: model.effectiveSelectedPhaseID) { _, phaseID in
                // Follow effective phase (pinned or live). Watching selectedPhaseID
                // alone misses Jump-to-live / re-selecting the live phase, which
                // clears the pin to nil without changing which phase is expanded.
                selectedCodePreview = nil
                guard let phaseID,
                      let anchor = model.anchorMessageID(forPhaseID: phaseID) else { return }
                autoScroll.beginProgrammaticScroll()
                withAnimation(Theme.motion.gentle) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
        }
    }

    // MARK: - Row rendering

    private var transcriptMessageIndices: [Int] {
        guard model.hasPhaseData,
              let phaseID = model.effectiveSelectedPhaseID else {
            return Array(model.messages.indices)
        }
        return model.messageIndices(forPhaseID: phaseID)
    }

    private var shouldFollowLivePhase: Bool {
        !model.hasPhaseData || model.isFollowingLivePhase
    }

    @ViewBuilder
    private func rowView(for message: EngineViewModel.Message,
                         idx: Int,
                         focusThinkingIndex: Int?,
                         lastUserIndex: Int?) -> some View {
        switch message {
        case .user(_, let text):
            UserBubbleView(
                text: text,
                isLast: idx == lastUserIndex,
                onEdit: idx == lastUserIndex ? { editText in model.editDraft = editText } : nil
            )
        case .assistant(let bubbleID, let text):
            AssistantTextView(text: text,
                              isStreaming: false,
                              bubbleID: bubbleID,
                              tts: tts,
                              onTTSAction: { id, action in
                                  model.requestAssistantBubbleSpeech(eventID: id, action: action)
                              },
                              codePresentation: .collapsed,
                              onCollapsedCodeSelected: selectCodePreview)
        case .assistantStreaming(let bubbleID, let text):
            AssistantTextView(text: text,
                              isStreaming: true,
                              bubbleID: bubbleID,
                              tts: nil,
                              tokenRate: model.tokenRatePerSecond,
                              codePresentation: .collapsed,
                              onCollapsedCodeSelected: selectCodePreview)
        case .thinkingChunk(_, let delta):
            thinkingRow(text: delta, duration: nil, isFocus: idx == focusThinkingIndex)
        case .thinkingComplete(_, let text, let duration):
            thinkingRow(text: text, duration: duration, isFocus: idx == focusThinkingIndex)
        case .toolCall:
            // Filtered out by the caller before this switch runs; tool
            // cards render in the work lane instead.
            EmptyView()
        case .clientAction(let action):
            ClientActionRowView(action: action)
        case .a2uiSurface(let surfaceID):
            if let surface = model.a2uiSurfaces[surfaceID] {
                A2UISurfaceView(state: surface,
                                onInteract: { componentID, scopePaths, overlay in
                                    model.submitA2UIInteraction(surfaceID: surfaceID,
                                                                sourceComponentID: componentID,
                                                                repeatedListScopePaths: scopePaths,
                                                                localOverlay: overlay)
                                },
                                now: model.clock.now())
            }
        }
    }

    @ViewBuilder
    private func thinkingRow(text: String, duration: Duration?, isFocus: Bool) -> some View {
        if isFocus {
            ThinkingFocusView(text: text, duration: duration)
        } else {
            ThinkingBlockView(text: text, duration: duration, isCurrent: false)
        }
    }

    // MARK: - Banners

    private var pausedScrollBanner: some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: "hand.raised")
                .foregroundStyle(Theme.signal.info)
                .accessibilityHidden(true)
            Text("Auto-scroll paused")
                .font(Theme.typography.label)
                .foregroundStyle(Theme.text.primary)
            Spacer(minLength: 0)
            Button("Resume scrolling") {
                autoScroll.resume()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityLabel("Resume scrolling")
            .accessibilityHint("Jump to the latest message and follow new replies")
        }
        .infoBannerChrome()
        .accessibilityElement(children: .contain)
    }

    // MARK: - Turn / thinking lookups

    /// Latest thinking row inside the currently visible transcript slice
    /// (phase span when phase data exists; otherwise the effective turn).
    private var focusThinkingRowIndex: Int? {
        let candidates = visibleThinkingCandidates
        for idx in candidates.reversed() {
            if isThinking(model.messages[idx]) { return idx }
        }
        return nil
    }

    /// Indexes considered for focus thinking — phase-scoped when phases exist.
    private var visibleThinkingCandidates: [Int] {
        if model.hasPhaseData {
            return transcriptMessageIndices
        }
        guard let turn = model.effectiveSelectedTurn,
              let start = model.messages.firstIndex(where: { $0.id == turn.anchorMessageID }) else {
            return []
        }
        let end = turnRangeEnd(startingAt: start)
        guard start < end else { return [] }
        return Array(start..<end)
    }

    /// Index one-past-the-end of the turn starting at `start` (the next `.user`
    /// row, or the end of `messages`).
    private func turnRangeEnd(startingAt start: Int) -> Int {
        for idx in (start + 1)..<model.messages.count {
            if case .user = model.messages[idx] { return idx }
        }
        return model.messages.count
    }

    private func isToolCall(_ message: EngineViewModel.Message) -> Bool {
        if case .toolCall = message { return true }
        return false
    }

    private func isThinking(_ message: EngineViewModel.Message) -> Bool {
        switch message {
        case .thinkingChunk, .thinkingComplete: return true
        default: return false
        }
    }

    private var lastUserMessageIndex: Int? {
        let indices = transcriptMessageIndices
        for idx in indices.reversed() {
            if case .user = model.messages[idx] { return idx }
        }
        return nil
    }

    private var isConversationEmpty: Bool {
        model.messages.isEmpty && model.activeToolCalls.isEmpty
    }

    private var importedHistoryIsUnavailable: Bool {
        guard let sessionID = model.sessionID,
              let projectPath = model.workspace?.standardizedFileURL.path,
              let sessions = model.sessionsByProject[projectPath] else {
            return false
        }
        guard let session = sessions.first(where: { $0.id == sessionID }) else {
            return false
        }
        switch session.historyImportState {
        case .imported:
            return true
        case .notNeeded, .importFailed:
            return false
        }
    }

    // MARK: - Search (unchanged from ConversationView)

    private var safeCurrentMatchIdx: Int {
        guard !matchIndices.isEmpty else { return -1 }
        return matchIndices[min(currentMatchIndex, matchIndices.count - 1)]
    }

    private func runSearch(_ query: String) {
        guard !query.isEmpty else { matchIndices = []; return }
        let visible = Set(transcriptMessageIndices)
        matchIndices = model.messages.enumerated().compactMap { idx, msg in
            guard visible.contains(idx) else { return nil }
            let text = searchableText(for: msg)
            guard let text else { return nil }
            return text.localizedCaseInsensitiveContains(query) ? idx : nil
        }
        currentMatchIndex = 0
    }

    /// `.a2uiSurface` markers carry no inline text (like `.toolCall`); their
    /// redacted host-generated summary lives in `model.a2uiSurfaces`.
    private func searchableText(for message: EngineViewModel.Message) -> String? {
        if case .a2uiSurface(let surfaceID) = message {
            guard let surface = model.a2uiSurfaces[surfaceID] else { return nil }
            return A2UITextSummary.summary(for: surface)
        }
        return message.textContent
    }

    private func searchNext() {
        guard !matchIndices.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matchIndices.count
    }

    private func searchPrev() {
        guard !matchIndices.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matchIndices.count) % matchIndices.count
    }

    private func scrollToCurrentMatch(proxy: ScrollViewProxy) {
        guard !matchIndices.isEmpty else { return }
        let msgIdx = matchIndices[min(currentMatchIndex, matchIndices.count - 1)]
        let id = model.messages[msgIdx].id
        autoScroll.beginProgrammaticScroll()
        withAnimation(Theme.motion.gentle) { proxy.scrollTo(id, anchor: .center) }
    }

    // MARK: - Scroll-follow

    private func scrollToConversationEnd(proxy: ScrollViewProxy, animated: Bool) {
        autoScroll.beginProgrammaticScroll()
        if animated,
           let motion = Theme.motion.resolve(Theme.motion.gentle, reduceMotion: reduceMotion) {
            withAnimation(motion) {
                proxy.scrollTo(ConversationScrollTarget.bottom, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(ConversationScrollTarget.bottom, anchor: .bottom)
        }
    }

    private func resumeFollowing(proxy: ScrollViewProxy) {
        autoScroll.resume()
        scrollToConversationEnd(proxy: proxy, animated: true)
    }

    /// Token streams can publish many tiny text deltas; scrolling on every one
    /// causes more layout work than the eye can perceive. Follow at paragraph
    /// boundaries or every small chunk of growth instead.
    private func shouldScrollForStreamingText(length: Int, text: String?) -> Bool {
        guard length > 0 else { return false }
        if length < lastAutoScrolledTextLength { return true }
        if length - lastAutoScrolledTextLength >= TranscriptPerformance.streamingScrollCharacterStride {
            return true
        }
        return text?.last == "\n"
    }

    private func selectCodePreview(code: String, language: String?) {
        selectedCodePreview = WorkbenchCodePreview(code: code, language: language)
    }

    private var isLastMessageFromUser: Bool {
        if case .user = model.messages.last { return true }
        return false
    }
}

private enum ConversationScrollTarget: Hashable {
    case bottom
}

private enum TranscriptPerformance {
    static let streamingScrollCharacterStride = 240
}

/// Thin top-edge fill that advances with the active file session's phase
/// ordinal — the "peripheral progress" replacement for a flow ribbon.
/// Animates only on phase change (a real state change), never per-render.
private struct PeripheralProgressHairline: View {
    let fraction: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Avoid a bare GeometryReader row — it can expand and fight the
        // work-lane width reservation. Measure only inside a fixed-height
        // overlay so the hairline never participates in horizontal layout.
        Rectangle()
            .fill(Theme.surface.divider)
            .frame(height: Theme.stroke.standard)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(Theme.signal.info)
                        .frame(width: proxy.size.width * max(0, min(1, fraction)))
                }
            }
            .animation(Theme.motion.resolve(Theme.motion.considered, reduceMotion: reduceMotion), value: fraction)
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Transcript Lane – Light") {
    TranscriptLaneView(model: .previewConversation,
                       searchVisible: .constant(false),
                       selectedCodePreview: .constant(nil))
        .frame(width: 640, height: 480)
        .preferredColorScheme(.light)
}

#Preview("Transcript Lane – Dark") {
    TranscriptLaneView(model: .previewConversation,
                       searchVisible: .constant(false),
                       selectedCodePreview: .constant(nil))
        .frame(width: 640, height: 480)
        .preferredColorScheme(.dark)
}
#endif
