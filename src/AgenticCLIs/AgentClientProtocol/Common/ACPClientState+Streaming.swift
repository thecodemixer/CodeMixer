import Foundation

import AgentCore
import AgentProtocol

/// Live-turn bookkeeping: synthetic item/thinking-block ids, the assistant
/// delta accumulator, tool-call metadata, and coalesced background-session
/// (foreign) stream text.
extension ACPClientState {
    func itemUUID(for itemID: String, random: any RandomSource) -> UUID {
        withLock {
            if let existing = itemIDs[itemID] { return existing }
            let id = random.uuid()
            itemIDs[itemID] = id
            return id
        }
    }

    func appendAssistantDelta(_ delta: String, itemID: String) -> String {
        withLock {
            let next = (assistantTextByItemID[itemID] ?? "") + delta
            assistantTextByItemID[itemID] = next
            return next
        }
    }

    func clearAssistantText(itemID: String) {
        withLock { _ = assistantTextByItemID.removeValue(forKey: itemID) }
    }

    func finalizedAssistantMessage(itemID: String = "agent-message") -> (id: UUID, text: String)? {
        withLock {
            guard let text = assistantTextByItemID[itemID], !text.isEmpty,
                  let id = itemIDs[itemID] else { return nil }
            assistantTextByItemID.removeValue(forKey: itemID)
            itemIDs.removeValue(forKey: itemID)
            return (id, text)
        }
    }

    /// Drop turn-scoped synthetic ids so the next prompt allocates fresh
    /// assistant / thinking identities (avoids SwiftUI row collisions).
    func resetTurnScopedIDs() {
        withLock { thinkingBlockIDs.removeAll() }
    }

    func thinkingBlockID(for key: String, random: any RandomSource) -> UUID {
        withLock {
            if let existing = thinkingBlockIDs[key] { return existing }
            let id = random.uuid()
            thinkingBlockIDs[key] = id
            return id
        }
    }

    func rememberToolStart(id: String, name: String, inputJSON: String?) {
        withLock { toolMetaByID[id] = (name, inputJSON) }
    }

    func takeToolMeta(id: String) -> (name: String, inputJSON: String?)? {
        withLock { toolMetaByID.removeValue(forKey: id) }
    }

    func appendThoughtDelta(_ delta: String) {
        withLock { thoughtText += delta }
    }

    /// Thought text accumulated this turn (for local session-index persistence).
    func takeThoughtText() -> String? {
        withLock {
            let text = thoughtText
            thoughtText = ""
            return text.isEmpty ? nil : text
        }
    }

    /// Close an open live thinking block (first assistant chunk or prompt finalize).
    func takeOpenThinkingBlockID() -> UUID? {
        withLock { thinkingBlockIDs.removeValue(forKey: "thought") }
    }

    /// Accumulate a background-session text chunk. Returns a completed turn when
    /// the role changes for that session (or when `flushForeignBuffer` is used).
    func appendForeignChunk(sessionID: String,
                            role: String,
                            delta: String) -> (role: String, text: String)? {
        withLock {
            guard !delta.isEmpty else { return nil }
            if let existing = foreignBuffers[sessionID], existing.role != role {
                foreignBuffers[sessionID] = (role, delta)
                return existing.text.isEmpty ? nil : existing
            }
            if let existing = foreignBuffers[sessionID] {
                foreignBuffers[sessionID] = (role, existing.text + delta)
            } else {
                foreignBuffers[sessionID] = (role, delta)
            }
            return nil
        }
    }

    func flushForeignBuffer(sessionID: String) -> (role: String, text: String)? {
        withLock {
            guard let existing = foreignBuffers.removeValue(forKey: sessionID),
                  !existing.text.isEmpty else { return nil }
            return existing
        }
    }
}
