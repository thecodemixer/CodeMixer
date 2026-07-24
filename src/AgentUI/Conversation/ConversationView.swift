import SwiftUI

/// Prose column: a clean, single-thread scroll of user prompts, assistant
/// answers, thinking traces, and tool-call cards.
///
/// Embeds an in-conversation search bar (Cmd+F) that highlights matching
/// messages and navigates between them via ScrollViewReader.
public struct ConversationView: View {
    @Bindable public var model: EngineViewModel
    public var tts: TTSService?
    /// Driven externally (Cmd+F from `WorkspaceScene`).
    @Binding public var searchVisible: Bool

    @State private var searchQuery: String = ""
    @State private var matchIndices: [Int] = []
    @State private var currentMatchIndex: Int = 0

    /// Explicit follow gate — user scroll pauses; Resume (or send / session
    /// switch) restores. No proximity-based re-engage.
    @State private var autoScroll = ConversationAutoScrollController()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: EngineViewModel,
                tts: TTSService? = nil,
                searchVisible: Binding<Bool> = .constant(false)) {
        self.model = model
        self.tts = tts
        _searchVisible = searchVisible
    }

    public var body: some View {
        VStack(spacing: 0) {
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

            if showsLoadedTranscriptBanner {
                loadedTranscriptBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if autoScroll.showsPausedBanner, !isConversationEmpty {
                pausedScrollBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if isConversationEmpty {
                ConversationEmptyState(workspace: model.workspace,
                                       isSwitchingSession: model.isSwitchingSession
                                           || model.isComposerLockedForSessionResume)
                    .background(Theme.surface.canvas)
                    .transition(.opacity)
            } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { idx, message in
                            view(for: message,
                                 isLastUser: isLastUser(at: idx),
                                 isCurrentThinking: isCurrentThinking(at: idx))
                                // Turn spine: a 1px leading rule on agent-side rows so a
                                // multi-bubble turn (thinking + prose + tool) reads as one
                                // continuous thought. Adjacent rows share the gutter, so the
                                // rule visually fuses into a single line. User rows omit it.
                                .turnSpine(isAgentSide(message))
                                .id(message.id)
                                .padding(.horizontal, Theme.spacing.s16)
                                .background(matchIndices.contains(idx) && idx == safeCurrentMatchIdx
                                            ? Theme.signal.info.opacity(Theme.opacity.quiet) : Color.clear)
                                .transition(reduceMotion ? .opacity : .arriving)
                                .padding(.bottom, spacing(after: idx))
                        }
                        Color.clear
                            .frame(height: Theme.spacing.s48)
                            .accessibilityHidden(true)
                            .id(ConversationScrollTarget.bottom)
                    }
                    .padding(.vertical, Theme.spacing.s24)
                    // Send→turn lift: new rows arrive with a single motion token; the
                    // list animates on count change so an appended bubble eases in
                    // rather than popping. Honors reduced motion (opacity-only).
                    .animation(Theme.motion.resolve(Theme.motion.arriving, reduceMotion: reduceMotion),
                               value: model.messages.count)
                    // Clamp to a centered reading column (visual-style §12): the
                    // inner frame caps the width, the outer frame fills the pane
                    // and centers the column when it is wider.
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
                    // Sending a prompt is deliberate engagement with the live
                    // turn — restore follow so the new message is visible.
                    if isLastMessageFromUser {
                        resumeFollowing(proxy: proxy)
                        return
                    }
                    guard autoScroll.isFollowing else { return }
                    scrollToConversationEnd(proxy: proxy, animated: true)
                }
                // Follow growing prose/thoughts while the ForEach id stays stable.
                .onChange(of: model.messages.last?.textContent) { _, _ in
                    guard !searchVisible,
                          model.messages.last?.id != nil,
                          autoScroll.isFollowing else { return }
                    // Unanimated: streaming tokens arrive often; animating each
                    // jump floods live-scroll notifications and fights the user.
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
                    // Resume button (and any other deliberate restore) lands at
                    // the live end once follow flips back on.
                    guard !wasFollowing, isFollowing, !searchVisible else { return }
                    scrollToConversationEnd(proxy: proxy, animated: true)
                }
            }
            }
        }
        .background(Theme.surface.canvas)
        .animation(Theme.motion.resolve(Theme.motion.changing, reduceMotion: reduceMotion),
                   value: isConversationEmpty)
        .animation(Theme.motion.resolve(Theme.motion.changing, reduceMotion: reduceMotion),
                   value: autoScroll.isFollowing)
        // Switching sessions unmounts the scroll view — reset follow on the
        // always-mounted parent so the new session lands at the bottom.
        .onChange(of: model.sessionID) { _, _ in
            autoScroll.resetForNewSession()
        }
        .onKeyPress(.escape) {
            if searchVisible { searchVisible = false; searchQuery = "" }
            return .handled
        }
    }

    // MARK: - View builder

    private var showsLoadedTranscriptBanner: Bool {
        guard let sessionID = model.sessionID else { return false }
        return model.cachedTranscriptLoadedSessionID == sessionID
    }

    private var loadedTranscriptBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.spacing.s8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(Theme.signal.info)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text("Loaded transcript")
                    .font(Theme.typography.label)
                    .foregroundStyle(Theme.text.primary)
                Text("The ACP agent no longer has this live session; showing Codemixer's cached history.")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            Spacer(minLength: 0)
        }
        .infoBannerChrome()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loaded transcript. Showing Codemixer cached history because the ACP agent no longer has this live session.")
    }

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

    @ViewBuilder
    private func view(for message: EngineViewModel.Message,
                      isLastUser: Bool,
                      isCurrentThinking: Bool) -> some View {
        switch message {
        case .user(_, let text):
            UserBubbleView(
                text: text,
                isLast: isLastUser,
                onEdit: isLastUser ? { editText in model.editDraft = editText } : nil
            )
        case .assistant(let bubbleID, let text):
            AssistantTextView(text: text,
                              isStreaming: false,
                              bubbleID: bubbleID,
                              tts: tts,
                              onTTSAction: { id, action in
                                  model.requestAssistantBubbleSpeech(eventID: id, action: action)
                              })
        case .assistantStreaming(let bubbleID, let text):
            AssistantTextView(text: text,
                              isStreaming: true,
                              bubbleID: bubbleID,
                              tts: nil,
                              tokenRate: model.tokenRatePerSecond)
        case .thinkingChunk(_, let delta):
            ThinkingBlockView(text: delta, duration: nil, isCurrent: isCurrentThinking)
        case .thinkingComplete(_, let text, let duration):
            ThinkingBlockView(text: text, duration: duration, isCurrent: isCurrentThinking)
        case .toolCall(let callID):
            // Read the live entry by id so progress + completion keep updating
            // while the card holds its place in the turn.
            if let entry = model.activeToolCalls.first(where: { $0.id == callID }) {
                ToolCallCardView(entry: entry)
            }
        case .clientAction(let action):
            ClientActionRowView(action: action)
        }
    }

    private func spacing(after index: Int) -> CGFloat {
        guard model.messages.indices.contains(index + 1) else { return 0 }
        let current = model.messages[index]
        let next = model.messages[index + 1]
        if isToolCall(current), isToolCall(next) {
            return .zero
        }
        if isToolCall(current) || isToolCall(next) {
            return Theme.spacing.s16
        }
        return Theme.spacing.s16
    }

    private func isToolCall(_ message: EngineViewModel.Message) -> Bool {
        if case .toolCall = message { return true }
        return false
    }

    private func isCurrentThinking(at index: Int) -> Bool {
        guard isThinking(model.messages[index]) else { return false }
        return model.messages[(index + 1)...].allSatisfy { !isThinking($0) }
    }

    private func isThinking(_ message: EngineViewModel.Message) -> Bool {
        switch message {
        case .thinkingChunk, .thinkingComplete:
            return true
        default:
            return false
        }
    }

    private func isLastUser(at index: Int) -> Bool {
        guard case .user = model.messages[index] else { return false }
        return !model.messages[(index + 1)...].contains {
            if case .user = $0 { return true }; return false
        }
    }

    /// Agent-side rows (assistant prose, streaming, thinking, tools) carry the
    /// turn spine; user prompts and Codemixer action markers do not.
    private func isAgentSide(_ message: EngineViewModel.Message) -> Bool {
        switch message {
        case .user, .clientAction:
            return false
        default:
            return true
        }
    }

    /// The conversation has nothing to show yet — drives the first-impression
    /// hero in place of an empty scroll view.
    private var isConversationEmpty: Bool {
        model.messages.isEmpty && model.activeToolCalls.isEmpty
    }

    // MARK: - Search

    private var safeCurrentMatchIdx: Int {
        guard !matchIndices.isEmpty else { return -1 }
        return matchIndices[min(currentMatchIndex, matchIndices.count - 1)]
    }

    private func runSearch(_ query: String) {
        guard !query.isEmpty else { matchIndices = []; return }
        matchIndices = model.messages.enumerated().compactMap { idx, msg in
            guard let text = msg.textContent else { return nil }
            return text.localizedCaseInsensitiveContains(query) ? idx : nil
        }
        currentMatchIndex = 0
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

    private var isLastMessageFromUser: Bool {
        if case .user = model.messages.last { return true }
        return false
    }
}

private enum ConversationScrollTarget: Hashable {
    case bottom
}

#if DEBUG
#Preview("Conversation – Light") {
    ConversationView(model: .previewConversation)
        .frame(width: 560, height: 480)
        .preferredColorScheme(.light)
}

#Preview("Conversation – Dark") {
    ConversationView(model: .previewConversation)
        .frame(width: 560, height: 480)
        .preferredColorScheme(.dark)
}
#endif
