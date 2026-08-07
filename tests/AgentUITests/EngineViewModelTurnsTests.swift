import Foundation
import Testing
@testable import AgentUI
@testable import AgentCore
@testable import AgentTestSupport
import AgentProtocol

/// Chat workbench: `conversationTurns` projection, `sessionPhaseChanged`
/// reduction, rail badges (round/ETA/attention), turn selection, and the
/// while-you-were-away recap.
@Suite("EngineViewModel — turns and phases")
@MainActor
struct EngineViewModelTurnsTests {

    @Test("conversationTurns splits messages on .user boundaries")
    func turnsSplitOnUserBoundaries() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "first"))
        await bus.publish(.assistantText(id: UUID().uuidString, blockID: UUID().uuidString, text: "reply one", isFinal: true))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "second"))
        await drain()

        let turns = vm.conversationTurns
        #expect(turns.count == 2)
        #expect(turns[0].promptText == "first")
        #expect(turns[0].ordinal == 0)
        #expect(turns[1].promptText == "second")
        #expect(turns[1].ordinal == 1)

        await bus.shutdown()
    }

    @Test("the live turn is running; earlier turns are done")
    func liveTurnStatus() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "first"))
        await bus.publish(.assistantText(id: UUID().uuidString, blockID: UUID().uuidString, text: "done", isFinal: true))
        await bus.publish(.activityStateChanged(.idle))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "second"))
        await bus.publish(.activityStateChanged(.streamingText))
        await drain()

        let turns = vm.conversationTurns
        #expect(turns[0].status == .done)
        #expect(turns[1].status == .running)
        #expect(vm.liveTurnID == turns[1].id)

        await bus.shutdown()
    }

    @Test("selectTurn pins an older turn; jumpToLiveTurn restores following")
    func selectionAndJumpToLive() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "first"))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "second"))
        await drain()

        #expect(vm.isFollowingLiveTurn)
        let firstTurn = vm.conversationTurns[0]
        vm.selectTurn(firstTurn.id)
        #expect(!vm.isFollowingLiveTurn)
        #expect(vm.effectiveSelectedTurn?.id == firstTurn.id)

        vm.jumpToLiveTurn()
        #expect(vm.isFollowingLiveTurn)
        #expect(vm.effectiveSelectedTurn?.id == vm.liveTurnID)

        await bus.shutdown()
    }

    @Test("sessionPhaseChanged tags subsequent turns and powers hasPhaseData")
    func phaseReductionTagsTurns() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "file-1", model: nil, cwd: TestPaths.underTemporary("proj")))
        #expect(!vm.hasPhaseData)

        await bus.publish(.sessionPhaseChanged(sessionID: "file-1", phase: .fixture("migrating", "Migrate", 2, .migrate)))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "migrate orders.ts"))
        await drain()

        #expect(vm.hasPhaseData)
        #expect(vm.conversationTurns.last?.phase?.id == "migrating")

        await bus.shutdown()
    }

    @Test("phase markers without user turns still expose distinct pipeline phases")
    func phaseMarkersWithoutUserTurnsRemainDistinct() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "file-1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("planned", "Plan", 0, .plan)))
        await bus.publish(.assistantText(id: UUID().uuidString, blockID: "a",
                                         text: #"{"plan":"x"}"#, isFinal: true))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("migrating", "Migrate", 1, .migrate)))
        await bus.publish(.assistantText(id: UUID().uuidString, blockID: "b",
                                         text: "export const migrated = true;", isFinal: true))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("reviewing", "Review", 2, .review)))
        await bus.publish(.assistantText(id: UUID().uuidString, blockID: "c",
                                         text: "review notes", isFinal: true))
        await drain()

        let phaseIDs = vm.phaseMarkers.map(\.phase.id)
        #expect(phaseIDs == ["planned", "migrating", "reviewing"])
        #expect(vm.hasPhaseData)
        // Rail is phase-native from markers — not a turn-grouping projection.
        #expect(vm.railPhases.map(\.id) == ["planned", "migrating", "reviewing"])
        #expect(vm.railPhaseOccurrences.map(\.phase.id) == ["planned", "migrating", "reviewing"])
        #expect(vm.railPhaseOccurrence(for: vm.effectiveSelectedPhaseID ?? "")?.phase.id == "reviewing")
        // Assistant-only spans still expose a phase-local row when expanded.
        #expect(!vm.turnsForEffectivePhase.isEmpty)
        #expect(vm.turnsForEffectivePhase.first?.promptText?.contains("review") == true)
        #expect(Set(vm.phaseMarkers.map(\.phase.label)) == ["Plan", "Migrate", "Review"])

        vm.selectPhase("migrating")
        #expect(vm.railPhaseOccurrence(for: vm.effectiveSelectedPhaseID ?? "")?.phase.id == "migrating")
        #expect(vm.turnsForEffectivePhase.first?.promptText?.contains("migrated") == true)
        let migratingMessageText = vm.messageIndices(forPhaseID: vm.effectiveSelectedPhaseID ?? "")
            .compactMap { vm.messages[$0].textContent }
        #expect(migratingMessageText == ["export const migrated = true;"])

        await bus.shutdown()
    }

    @Test("rail expands turns for the effective phase only")
    func railExpandsTurnsForEffectivePhaseOnly() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "file-1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("planned", "Plan", 0, .plan)))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "plan the migration"))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("migrating", "Migrate", 1, .migrate)))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "migrate orders.ts"))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("reviewing", "Review", 2, .review)))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "review the diff"))
        await drain()

        #expect(vm.railPhases.map(\.id) == ["planned", "migrating", "reviewing"])
        #expect(vm.railPhaseOccurrence(for: vm.effectiveSelectedPhaseID ?? "")?.phase.id == "reviewing")
        #expect(vm.turnsForEffectivePhase.map(\.promptText) == ["review the diff"])
        #expect(vm.turns(forPhaseID: "planned").map(\.promptText) == ["plan the migration"])
        #expect(vm.turns(forPhaseID: "migrating").map(\.promptText) == ["migrate orders.ts"])

        vm.selectPhase("planned")
        #expect(vm.railPhaseOccurrence(for: vm.effectiveSelectedPhaseID ?? "")?.phase.id == "planned")
        #expect(vm.turnsForEffectivePhase.map(\.promptText) == ["plan the migration"])

        let liveAnchor = vm.selectPhase("reviewing")
        #expect(vm.isFollowingLivePhase)
        #expect(vm.railPhaseOccurrence(for: vm.effectiveSelectedPhaseID ?? "")?.phase.id == "reviewing")
        #expect(vm.turnsForEffectivePhase.map(\.promptText) == ["review the diff"])
        #expect(liveAnchor != nil)

        await bus.shutdown()
    }

    @Test("phase spans own turns by message index; live phase keeps a running earlier turn")
    func phaseSpansOwnTurnsByMessageIndex() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "file-1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("planned", "Plan", 0, .plan)))
        let turnID = UUID()
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: turnID.uuidString), text: "run the pipeline"))
        await bus.publish(.activityStateChanged(.streamingText))
        await bus.publish(.assistantText(id: UUID().uuidString, blockID: "a",
                                         text: "planning…", isFinal: false))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("migrating", "Migrate", 1, .migrate)))
        await bus.publish(.assistantText(id: UUID().uuidString, blockID: "a",
                                         text: "planning… migrating…", isFinal: false))
        await drain()

        #expect(vm.phaseMessageSpan(forPhaseID: "planned") != nil)
        #expect(vm.phaseMessageSpan(forPhaseID: "migrating") != nil)
        // Prompt started in Plan.
        #expect(vm.turns(forPhaseID: "planned").map(\.promptText) == ["run the pipeline"])
        // Same running turn still appears under the live Migrate phase.
        #expect(vm.railPhaseOccurrence(for: vm.livePhaseID ?? "")?.phase.id == "migrating")
        #expect(vm.turns(forPhaseID: "migrating").map(\.id) == [turnID])
        #expect(vm.turnsForEffectivePhase.map(\.id) == [turnID])

        await bus.shutdown()
    }

    @Test("phase scroll anchor stays inside the selected phase, not the next one")
    func phaseScrollAnchorStaysInsideSelectedPhase() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "file-1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("migrating", "Migrating", 2, .migrate)))
        let migrateBubble = UUID()
        await bus.publish(.assistantText(id: migrateBubble.uuidString, blockID: "m",
                                         text: "migrated code", isFinal: true))
        // Completion status shares the next phase's start index when no messages
        // land between `migrated` and `reviewing` — classic off-by-one scroll.
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("migrated", "Migrated", 3, .migrate)))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("reviewing", "Reviewing", 4, .review)))
        let reviewBubble = UUID()
        await bus.publish(.assistantText(id: reviewBubble.uuidString, blockID: "r",
                                         text: "reviewer verdict", isFinal: true))
        await drain()

        let migratedAnchor = vm.anchorMessageID(forPhaseID: "migrated")
        let reviewingAnchor = vm.anchorMessageID(forPhaseID: "reviewing")
        let migratingAnchor = vm.anchorMessageID(forPhaseID: "migrating")

        #expect(migratingAnchor == "asst-\(migrateBubble)")
        #expect(migratedAnchor == "asst-\(migrateBubble)")
        #expect(reviewingAnchor == "asst-\(reviewBubble)")
        #expect(migratedAnchor != reviewingAnchor)

        await bus.shutdown()
    }

    @Test("replayed phase prefix after background promotion is ignored")
    func replayedPhasePrefixAfterPromotionIsIgnored() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "file-1", model: nil, cwd: TestPaths.underTemporary("proj")))
        let planned = SessionPhase.fixture("planned", "Plan", 0, .plan)
        let migrating = SessionPhase.fixture("migrating", "Migrate", 1, .migrate)
        let reviewing = SessionPhase.fixture("reviewing", "Review", 2, .review)
        let fixing = SessionPhase.fixture("fixing", "Fix", 3, .fix)

        for phase in [planned, migrating, reviewing] {
            await bus.publish(.sessionPhaseChanged(sessionID: "file-1", phase: phase))
        }
        await drain()
        #expect(vm.phaseMarkers.map(\.phase.id) == ["planned", "migrating", "reviewing"])

        for phase in [planned, migrating, reviewing] {
            await bus.publish(.sessionPhaseChanged(sessionID: "file-1", phase: phase))
        }
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1", phase: fixing))
        await drain()

        #expect(vm.phaseMarkers.map(\.phase.id) == ["planned", "migrating", "reviewing", "fixing"])

        await bus.shutdown()
    }

    @Test("a phase marker for a background session is promoted when that session opens")
    func phasePromotedForBackgroundSession() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let cwd = TestPaths.underTemporary("proj")
        await bus.publish(.sessionStarted(sessionID: "file-1", model: nil, cwd: cwd))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-other", phase: .fixture("migrating", "Migrate", 2, .migrate)))
        await drain()

        #expect(!vm.hasPhaseData)
        let pendingKey = vm.pendingPhaseKey(sessionID: "file-other", projectPath: cwd.path)
        #expect(vm.pendingPhaseMarkersBySession[pendingKey]?.last?.phase.id == "migrating")

        vm.beginSessionSwitch(projectPath: cwd.path, sessionID: "file-other")
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "migrate orders.ts"))
        await drain()

        #expect(vm.hasPhaseData)
        #expect(vm.pendingPhaseMarkersBySession[pendingKey] == nil)
        #expect(vm.conversationTurns.last?.phase?.id == "migrating")

        await bus.shutdown()
    }

    @Test("phaseGroupOccurrence counts same-group phases up to and including the given one")
    func phaseGroupOccurrenceCountsRounds() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "file-1", model: nil, cwd: TestPaths.underTemporary("proj")))
        let fixRound1 = SessionPhase.fixture("fixing-1", "Fix", 5, .fix)
        let fixRound2 = SessionPhase.fixture("fixing-2", "Fix", 5, .fix)
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1", phase: fixRound1))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1", phase: .fixture("reviewing", "Review", 4, .review)))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1", phase: fixRound2))
        await drain()

        #expect(vm.phaseGroupOccurrence(of: fixRound1) == 1)
        #expect(vm.phaseGroupOccurrence(of: fixRound2) == 2)

        await bus.shutdown()
    }

    @Test("repeated phase statuses are distinct rail occurrences")
    func repeatedPhaseStatusesHaveDistinctOccurrenceIDs() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "file-1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("reviewing", "Review", 4, .review)))
        await bus.publish(.assistantText(id: UUID().uuidString, blockID: "r1",
                                         text: "first review", isFinal: true))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("fixing", "Fix", 5, .fix)))
        await bus.publish(.assistantText(id: UUID().uuidString, blockID: "f",
                                         text: "fix applied", isFinal: true))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("reviewing", "Review", 4, .review)))
        await bus.publish(.assistantText(id: UUID().uuidString, blockID: "r2",
                                         text: "second review", isFinal: true))
        await drain()

        let reviewOccurrences = vm.railPhaseOccurrences.filter { $0.phase.id == "reviewing" }
        #expect(reviewOccurrences.count == 2)
        guard reviewOccurrences.count == 2 else {
            await bus.shutdown()
            return
        }
        #expect(reviewOccurrences[0].id != reviewOccurrences[1].id)
        #expect(reviewOccurrences[0].round == 1)
        #expect(reviewOccurrences[1].round == 2)

        vm.selectPhase(reviewOccurrences[0].id)
        #expect(vm.turnsForEffectivePhase.first?.promptText?.contains("first review") == true)

        vm.selectPhase(reviewOccurrences[1].id)
        #expect(vm.turnsForEffectivePhase.first?.promptText?.contains("second review") == true)
        #expect(vm.anchorMessageID(forPhaseID: reviewOccurrences[0].id)
                != vm.anchorMessageID(forPhaseID: reviewOccurrences[1].id))

        await bus.shutdown()
    }

    @Test("currentPhaseETA averages same-group durations from prior rounds")
    func etaAveragesPriorRounds() async {
        let clock = FakeClock()
        let (vm, bus) = makeTurnsModel(clock: clock)
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "file-1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await drain()
        #expect(vm.currentPhaseETA == nil)

        await bus.publish(.sessionPhaseChanged(sessionID: "file-1", phase: .fixture("fixing-1", "Fix", 5, .fix)))
        await drain()
        clock.advance(by: .seconds(60))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1", phase: .fixture("verifying", "Verify", 6, .verify)))
        await drain()

        // The just-completed Fix round has no prior same-group round yet.
        #expect(vm.currentPhaseETA == nil)

        clock.advance(by: .seconds(30))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1", phase: .fixture("fixing-2", "Fix", 5, .fix)))
        await drain()

        // Now in a second Fix round with one completed Fix round (60s) behind it.
        #expect(vm.currentPhaseETA == 60)

        await bus.shutdown()
    }

    @Test("phaseGroupNeedsAttention is true only while a permission is pending on a needs-human-review phase")
    func attentionBadgeTracksPendingPermission() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "file-1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                                phase: .fixture("needs-human-review", "Review", 4, .review)))
        await drain()

        #expect(!vm.phaseGroupNeedsAttention(.review))

        vm.pendingPermissionsBySession[vm.permissionOwnerKey(for: vm.sessionID)] = PermissionPrompt(
            toolName: "edit_file", summary: "Review retry parameter", argumentsSummary: "", requestedAt: vm.clock.now()
        )
        #expect(vm.phaseGroupNeedsAttention(.review))
        #expect(!vm.phaseGroupNeedsAttention(.fix))

        await bus.shutdown()
    }

    @Test("markSessionSeenNow then new turns land produces a recap; dismissing clears it")
    func awayRecapDelta() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "first"))
        await drain()

        vm.markSessionSeenNow()
        #expect(vm.recapSinceLastSeen == nil)

        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "second"))
        await bus.publish(.assistantText(id: UUID().uuidString, blockID: UUID().uuidString, text: "done", isFinal: true))
        await drain()

        let recap = vm.recapSinceLastSeen
        #expect(recap?.turnsCompleted == 1)

        vm.markSessionSeenNow()
        #expect(vm.recapSinceLastSeen == nil)

        await bus.shutdown()
    }

    @Test("selecting a phase scopes work-lane tool calls to that phase's message span")
    func selectingPhaseScopesWorkLaneToolCalls() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "file-1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("planned", "Plan", 0, .plan)))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "plan the migration"))
        await bus.publish(.toolStart(id: "plan-tool", name: "read_file",
                                     input: ToolInput(summary: "orders.ts"), startedAt: Date()))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("migrating", "Migrate", 1, .migrate)))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "migrate orders.ts"))
        await bus.publish(.toolStart(id: "migrate-tool", name: "edit_file",
                                     input: ToolInput(summary: "orders.ts"), startedAt: Date()))
        await bus.publish(.sessionPhaseChanged(sessionID: "file-1",
                                               phase: .fixture("reviewing", "Review", 2, .review)))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "review the diff"))
        await drain()

        // Live phase has no tools yet.
        #expect(vm.effectiveWorkToolCalls.map(\.id) == [])
        #expect(vm.toolCalls(forPhaseID: "planned").map(\.id) == ["plan-tool"])
        #expect(vm.toolCalls(forPhaseID: "migrating").map(\.id) == ["migrate-tool"])

        vm.selectPhase("planned")
        #expect(vm.effectiveWorkToolCalls.map(\.id) == ["plan-tool"])
        #expect(vm.effectiveWorkToolCalls.map(\.name) == ["read_file"])

        vm.selectPhase("migrating")
        #expect(vm.effectiveWorkToolCalls.map(\.id) == ["migrate-tool"])
        #expect(WorkLaneView.hasContent(model: vm))

        await bus.shutdown()
    }

    @Test("previewCustomACPPhases fixture scopes transcript and tools per selected phase")
    func previewFixturePhaseSelectionSmoke() {
        let vm = EngineViewModel.previewCustomACPPhases

        #expect(vm.hasPhaseData)
        #expect(vm.railPhases.map(\.id) == ["migrating", "reviewing", "fixing"])
        #expect(WorkLaneView.hasContent(model: vm))

        vm.selectPhase("migrating")
        #expect(vm.railPhaseOccurrence(for: vm.effectiveSelectedPhaseID ?? "")?.phase.id == "migrating")
        #expect(vm.effectiveWorkToolCalls.map(\.id) == ["tool-1"])
        #expect(vm.effectiveWorkToolCalls.map(\.name) == ["edit_file"])
        let migratingText = vm.messageIndices(forPhaseID: vm.effectiveSelectedPhaseID ?? "")
            .compactMap { vm.messages[$0].textContent }
        #expect(migratingText.contains { $0.contains("Replaced 4 call sites") })
        #expect(!migratingText.contains { $0.contains("retry parameter") })

        vm.selectPhase("reviewing")
        #expect(vm.effectiveWorkToolCalls.isEmpty)
        let reviewingText = vm.messageIndices(forPhaseID: vm.effectiveSelectedPhaseID ?? "")
            .compactMap { vm.messages[$0].textContent }
        #expect(reviewingText.contains { $0.contains("retry parameter") })
        #expect(!reviewingText.contains { $0.contains("Replaced 4 call sites") })

        vm.selectPhase("fixing")
        #expect(vm.effectiveWorkToolCalls.isEmpty)
        let fixingText = vm.messageIndices(forPhaseID: vm.effectiveSelectedPhaseID ?? "")
            .compactMap { vm.messages[$0].textContent }
        #expect(fixingText.contains { $0.contains("Re-adding the retry parameter") })

        let liveAnchor = vm.selectPhase("fixing")
        #expect(vm.isFollowingLivePhase)
        #expect(liveAnchor != nil)
    }

    @Test("currentPhaseNavigationSubtitle and currentPhaseProgressFraction are nil without phase data")
    func peripheralProgressIsContentDriven() async {
        let (vm, bus) = makeTurnsModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await drain()

        #expect(vm.currentPhaseNavigationSubtitle == nil)
        #expect(vm.currentPhaseProgressFraction == nil)

        await bus.publish(.sessionPhaseChanged(sessionID: "s1", phase: .fixture("reviewing", "Review", 4, .review)))
        await drain()

        #expect(vm.currentPhaseNavigationSubtitle == "Review")
        #expect(vm.currentPhaseProgressFraction != nil)

        await bus.shutdown()
    }
}

// MARK: - Helpers

@MainActor
private func makeTurnsModel(clock: any AgentClock = SystemClock()) -> (EngineViewModel, MulticastEventBus) {
    let bus = MulticastEventBus()
    let vm = EngineViewModel(engine: StubTurnsCommandPort(), bus: bus, clock: clock)
    return (vm, bus)
}

/// Allow the event bus to deliver events to the subscriber task.
@MainActor
private func drain() async {
    try? await Task.sleep(for: .milliseconds(40))
}

private final class StubTurnsCommandPort: AgentEngineCommandPort, @unchecked Sendable {
    func send(_ command: AgentCommand) async throws {}
}

private extension SessionPhase {
    static func fixture(_ id: String, _ label: String, _ ordinal: Int, _ group: Group) -> SessionPhase {
        SessionPhase(id: id, label: label, ordinal: ordinal, group: group)
    }
}
