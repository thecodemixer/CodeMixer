import Foundation
import AgentProtocol

/// Picks the user-visible "what is the agent doing?" phrase from competing
/// sources and emits a single authoritative `statusPhraseChanged` event when
/// the winner changes.
///
/// Priority order, highest wins: `.adapterPinned > .hookHint > .tuiScrape >
/// `.heuristic`. When every source is cleared the resolver falls back to the
/// heuristic phrase (`ActivityTiming.thinkingPhrase`).
public actor StatusPhraseResolver {

    /// Current best phrase, exposed for log lines and remote snapshot.
    public private(set) var current: String = ActivityTiming.idlePhrase
    public private(set) var currentSource: StatusPhraseSource = .heuristic

    private var byPriority: [StatusPhraseSource: String] = [:]

    public init() {}

    /// Update the phrase asserted by `source`. Returns the new (source, phrase)
    /// if it changed, or nil if the assertion didn't change the winner.
    public func update(_ source: StatusPhraseSource,
                       phrase: String?) -> (StatusPhraseSource, String)? {
        if let phrase {
            byPriority[source] = phrase
        } else {
            byPriority.removeValue(forKey: source)
        }
        return recomputeWinner()
    }

    /// Drop every source — used on session end.
    public func reset() {
        byPriority.removeAll()
        current = ActivityTiming.idlePhrase
        currentSource = .heuristic
    }

    // MARK: - Private

    private func recomputeWinner() -> (StatusPhraseSource, String)? {
        let candidate = byPriority
            .max(by: { $0.key < $1.key })
            .map { (source: $0.key, phrase: $0.value) }

        let (winnerSource, winnerPhrase) = candidate ?? (.heuristic, ActivityTiming.thinkingPhrase)
        if winnerSource == currentSource && winnerPhrase == current {
            return nil
        }
        current = winnerPhrase
        currentSource = winnerSource
        return (winnerSource, winnerPhrase)
    }
}
