import Foundation
import Testing
@testable import AgentProtocol

@Suite("Wire frames — JSON round-trip")
struct WireFrameRoundTripTests {

    @Test("Every AgentCommand case survives encode → decode inside a ClientFrame")
    func everyCommandRoundTrips() throws {
        let bubbleID = UUID()
        let permID = UUID()
        let snapshotID = UUID()
        let attachment = AttachmentRef(id: "a1",
                                       filename: "spec.md",
                                       byteCount: 12,
                                       mimeType: "text/markdown")
        let commands: [AgentCommand] = [
            .sendPrompt(text: "hello", attachments: [attachment]),
            .cancelCurrentTurn,
            .editAndResubmitLast(targetBubbleID: bubbleID, text: "fix", attachments: []),
            .newSession,
            .compact,
            .selectModel(id: "claude-sonnet-4-5"),
            .setPermissionMode(.acceptEdits),
            .toggleThinkMode(enabled: true),
            .toggleThinkMode(enabled: false),
            .toggleReviewMode(enabled: true),
            .runSlashCommand(name: "/review", args: []),
            .runCustomCommand(path: "/proj/review.md", args: ["arg1", "arg2"]),
            .respondToPermission(id: permID, decision: .allow),
            .respondToPermission(id: permID, decision: .allowAlways),
            .respondToPermission(id: permID, decision: .deny),
            .respondToInlinePrompt(id: permID, text: "answer"),
            .openProject(path: "/repo", resumeSessionID: nil),
            .openProject(path: "/repo", resumeSessionID: "sess1"),
            .closeSession,
            .speakAssistantBubble(eventID: bubbleID, action: .play),
            .speakAssistantBubble(eventID: bubbleID, action: .pause),
            .speakAssistantBubble(eventID: bubbleID, action: .stop),
            .revertFile(path: "src/foo.swift"),
            .revertHunk(path: "src/foo.swift", hunkID: bubbleID),
            .updateAutoApprovalRules([
                AutoApprovalRule(match: "Bash ls *", decision: .allow),
                AutoApprovalRule(match: "Bash rm *", decision: .deny),
            ]),
            .updateAppearancePref(key: .theme, value: .string("dark")),
            .updateAppearancePref(key: .reduceMotion, value: .bool(true)),
            .updateAppearancePref(key: .fontSizeScale, value: .double(1.25)),
            .requestSnapshot(.conversation),
            .requestSnapshot(.diff),
            .requestSnapshot(.sessions),
            .requestSnapshot(.workspaceTree),
            .requestSnapshot(.prefs),
        ]
        let frames = commands.map { ClientFrame.command(id: snapshotID, command: $0) }
        try assertRoundTrip(frames)
    }

    @Test("Every ClientFrame top-level shape survives encode → decode")
    func clientFrameRoundTrip() throws {
        let cases: [ClientFrame] = [
            .command(id: UUID(), command: .cancelCurrentTurn),
            .subscribe(streams: [.events, .diff, .status]),
            .snapshot(kind: .conversation),
            .ping(id: UUID()),
            .pair(pin: "123456", clientName: "iPhone"),
            .auth(token: "bearer-token"),
        ]
        try assertRoundTrip(cases)
    }

    @Test("Client frames require an explicit wire version")
    func clientFrameMissingVersionThrows() {
        let decoder = JSONDecoder()
        let missingVersion = Data(#"{"type":"ping","id":"00000000-0000-0000-0000-000000000000"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(ClientFrame.self, from: missingVersion)
        }
    }

    @Test("Every ServerFrame case survives encode → decode")
    func serverFrameRoundTrip() throws {
        let prompt = WirePermissionPrompt(id: UUID(),
                                          toolName: "Bash",
                                          summary: "Run: ls",
                                          argumentsSummary: "{}",
                                          requestedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let cases: [ServerFrame] = [
            .event(.userTurn(id: "u1", text: "hi")),
            .event(.permissionRequest(prompt: prompt)),
            .event(.bell),
            .result(for: UUID(), ok: true, error: nil),
            .result(for: UUID(), ok: false,
                    error: WireAgentError(code: "spawn_failed", message: "no binary")),
            .snapshot(kind: .diff, payload: Data([1, 2, 3])),
            .pong(for: UUID()),
            .paired(token: "abc"),
            .pairFailed(reason: .invalidPIN),
            .pairFailed(reason: .expiredPIN),
            .pairFailed(reason: .rateLimited),
            .pairFailed(reason: .lockedOut),
            .versionMismatch(supported: [.v1]),
            .subscribed(latestEventID: nil),
            .subscribed(latestEventID: UUID()),
        ]
        try assertRoundTrip(cases)
    }

    @Test("subscribe frame carries lastSeenEventID round-trip")
    func subscribeWithCheckpointRoundTrips() throws {
        let checkpoint = UUID()
        let frames: [ClientFrame] = [
            .subscribe(streams: [.events], lastSeenEventID: nil),
            .subscribe(streams: [.events], lastSeenEventID: checkpoint),
            .subscribe(streams: [.events, .diff], lastSeenEventID: checkpoint),
        ]
        try assertRoundTrip(frames)
    }

    @Test("subscribed frame with nil latestEventID round-trips")
    func subscribedNilRoundTrips() throws {
        try assertRoundTrip([ServerFrame.subscribed(latestEventID: nil)])
    }

    @Test("Malformed JSON throws DecodingError")
    func malformedJSONThrows() {
        let decoder = JSONDecoder()
        let garbage = Data("{ this is not json".utf8)
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(ClientFrame.self, from: garbage)
        }
    }

    @Test("Missing type tag throws DecodingError")
    func missingTagThrows() {
        let decoder = JSONDecoder()
        let noTag = Data(#"{"id":"00000000-0000-0000-0000-000000000000"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(ClientFrame.self, from: noTag)
        }
    }

    @Test("Wire version constants are stable")
    func wireVersionStable() {
        #expect(WireVersion.v1.rawValue == 1)
        #expect(WireVersion.current.rawValue == WireVersion.v1.rawValue)
    }

    /// Round-trip via re-encoding: encode → decode → encode, compare bytes.
    /// Doesn't require the frame type to be `Equatable`.
    private func assertRoundTrip<T: Codable>(_ values: [T]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for value in values {
            let first = try encoder.encode(value)
            let restored = try decoder.decode(T.self, from: first)
            let second = try encoder.encode(restored)
            #expect(first == second, "round-trip mismatch for \(value)")
        }
    }
}
