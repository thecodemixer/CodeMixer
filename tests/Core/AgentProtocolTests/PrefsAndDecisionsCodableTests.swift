import Foundation
import Testing
@testable import AgentProtocol

@Suite("Prefs + Decisions — Codable round-trip")
struct PrefsAndDecisionsCodableTests {

    @Test("PermissionDecision raw values are stable + Codable")
    func permissionDecision() throws {
        for decision in [PermissionDecision.allow, .allowAlways, .deny] {
            try roundTrip(decision)
        }
    }

    @Test("PermissionMode raw values are stable + Codable")
    func permissionMode() throws {
        for mode in [PermissionMode.default, .acceptEdits, .bypassPermissions, .plan] {
            try roundTrip(mode)
        }
    }

    @Test("TTSAction round-trips")
    func ttsAction() throws {
        for action in [TTSAction.play, .pause, .stop] { try roundTrip(action) }
    }

    @Test("StopReason round-trips")
    func stopReason() throws {
        for reason in [StopReason.userCancel, .naturalExit, .spawnFailed, .crashed, .authExpired] {
            try roundTrip(reason)
        }
    }

    @Test("FileChangeKind round-trips")
    func fileChangeKind() throws {
        for kind in [FileChangeKind.hookReported, .fsObserved, .tuiScraped] {
            try roundTrip(kind)
        }
    }

    @Test("StatusPhraseSource is Comparable and round-trips")
    func statusPhraseSource() throws {
        let ordered: [StatusPhraseSource] = [.heuristic, .tuiScrape, .hookHint, .adapterPinned]
        for (i, source) in ordered.enumerated() {
            #expect(source.rawValue == i)
            try roundTrip(source)
        }
        #expect(StatusPhraseSource.heuristic < .adapterPinned)
        #expect(StatusPhraseSource.adapterPinned > .hookHint)
    }

    @Test("ActivitySubstate round-trips for every case")
    func activitySubstate() throws {
        let cases: [ActivitySubstate] = [
            .idle, .awaitingFirstChunk, .streamingText, .thinking, .runningTool,
            .waitingPermission, .stillWorking, .probablyStuck,
        ]
        for c in cases { try roundTrip(c) }
    }

    @Test("AppearancePrefKey round-trips for every case")
    func appearancePrefKey() throws {
        let cases: [AppearancePrefKey] = [
            .theme, .codeTheme, .fontFamily, .floatingCornerStyle, .fontSizeScale, .showUsageChip, .reduceMotion, .densityMode,
        ]
        for c in cases { try roundTrip(c) }
    }

    @Test("AppearancePrefValue round-trips every arm")
    func appearancePrefValue() throws {
        try roundTrip(AppearancePrefValue.string("dark"))
        try roundTrip(AppearancePrefValue.bool(true))
        try roundTrip(AppearancePrefValue.double(1.25))
    }

    @Test("AutoApprovalRule preserves every field")
    func autoApprovalRule() throws {
        let rule = AutoApprovalRule(id: UUID(),
                                    enabled: false,
                                    match: "Bash echo *",
                                    decision: .deny,
                                    note: "loud")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let decoder = JSONDecoder()
        let data = try encoder.encode(rule)
        let restored = try decoder.decode(AutoApprovalRule.self, from: data)
        #expect(restored == rule)
    }

    @Test("AttachmentRef preserves every field")
    func attachmentRef() throws {
        let ref = AttachmentRef(id: "abc",
                                filename: "file.png",
                                byteCount: 4_096,
                                mimeType: "image/png")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let decoder = JSONDecoder()
        let data = try encoder.encode(ref)
        let restored = try decoder.decode(AttachmentRef.self, from: data)
        #expect(restored == ref)
    }

    @Test("SnapshotKind round-trips for every case")
    func snapshotKind() throws {
        for kind in [SnapshotKind.conversation, .diff, .sessions, .prefs] {
            try roundTrip(kind)
        }
    }

    @Test("SubscribeReplayOutcome round-trips for every case")
    func subscribeReplayOutcome() throws {
        for outcome in [SubscribeReplayOutcome.fresh, .resumed, .checkpointExpired] {
            try roundTrip(outcome)
        }
    }

    @Test("PairFailureReason round-trips for every case")
    func pairFailureReason() throws {
        for reason in [PairFailureReason.invalidPIN, .expiredPIN, .rateLimited, .lockedOut] {
            try roundTrip(reason)
        }
    }

    @Test("AppearancePrefValue rejects unknown kind tag")
    func appearancePrefValueRejectsUnknownKind() {
        let bogus = Data(#"{"kind":"vector","value":[1,2,3]}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(AppearancePrefValue.self, from: bogus)
        }
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let decoder = JSONDecoder()
        let data = try encoder.encode(value)
        let restored = try decoder.decode(T.self, from: data)
        #expect(restored == value)
    }
}
