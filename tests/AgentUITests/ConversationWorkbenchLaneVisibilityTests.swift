import Foundation
import Testing
@testable import AgentUI
@testable import AgentCore
@testable import AgentTestSupport
import AgentProtocol

/// The chat workbench's content-driven lane rules: which lanes claim a slot
/// per density preset, and whether the work lane has anything to show at
/// all. Kept as pure/static functions on the views themselves precisely so
/// this behavior is testable without SwiftUI view inspection.
@Suite("Chat workbench — lane visibility")
@MainActor
struct ConversationWorkbenchLaneVisibilityTests {

    @Test("the index rail is inline at every density except .focus")
    func railInlineExceptFocus() {
        #expect(ConversationWorkbenchView.railFitsInline(density: .comfortable))
        #expect(ConversationWorkbenchView.railFitsInline(density: .compact))
        #expect(!ConversationWorkbenchView.railFitsInline(density: .focus))
    }

    @Test("the work lane is requested outside .focus for work content, diffs, or code previews")
    func workLaneRequestedTracksDensityAndBinding() {
        #expect(ConversationWorkbenchView.workLaneRequested(density: .comfortable, diffPanelVisible: true))
        #expect(!ConversationWorkbenchView.workLaneRequested(density: .comfortable, diffPanelVisible: false))
        #expect(ConversationWorkbenchView.workLaneRequested(density: .comfortable,
                                                            diffPanelVisible: false,
                                                            hasWorkContent: true))
        #expect(ConversationWorkbenchView.workLaneRequested(density: .comfortable,
                                                            diffPanelVisible: false,
                                                            hasCodePreview: true))
        #expect(ConversationWorkbenchView.workLaneRequested(density: .compact, diffPanelVisible: true))
        // .focus always suppresses it — the zen density collapses to a pure transcript
        // regardless of the diffPanelVisible binding.
        #expect(!ConversationWorkbenchView.workLaneRequested(density: .focus, diffPanelVisible: true))
        #expect(!ConversationWorkbenchView.workLaneRequested(density: .focus,
                                                             diffPanelVisible: false,
                                                             hasCodePreview: true,
                                                             hasWorkContent: true))
    }

    @Test("session scrubber stays hidden until there are multiple phase segments")
    func scrubberHiddenForSinglePhase() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.sessionPhaseChanged(sessionID: "s1",
                                               phase: SessionPhase(id: "planned",
                                                                   label: "Plan",
                                                                   ordinal: 0,
                                                                   group: .plan)))
        await drain()

        #expect(SessionScrubber.segmentCount(for: vm) == 1)
        #expect(!SessionScrubber.shouldShow(for: vm))

        await bus.publish(.sessionPhaseChanged(sessionID: "s1",
                                               phase: SessionPhase(id: "migrating",
                                                                   label: "Migrate",
                                                                   ordinal: 1,
                                                                   group: .migrate)))
        await drain()

        #expect(SessionScrubber.segmentCount(for: vm) >= 2)
        #expect(SessionScrubber.shouldShow(for: vm))

        await bus.shutdown()
    }

    @Test("WorkLaneView has no content for a bare conversation")
    func hasContentFalseWhenEmpty() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "hello"))
        await drain()

        #expect(!WorkLaneView.hasContent(model: vm))

        await bus.shutdown()
    }

    @Test("WorkLaneView has content once the selected turn ran a tool")
    func hasContentTrueForToolCall() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "migrate orders.ts"))
        await bus.publish(.toolStart(id: "call-1", name: "edit_file", input: ToolInput(summary: "orders.ts"), startedAt: Date()))
        await drain()

        #expect(WorkLaneView.hasContent(model: vm))

        await bus.shutdown()
    }

    @Test("restored history projects every visible block into a workbench lane")
    func restoredHistoryProjectsEveryVisibleBlock() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let cwd = TestPaths.underTemporary("restored-workbench")
        let thinkingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        await bus.publish(.sessionStarted(sessionID: "restored", model: nil, cwd: cwd))
        await bus.publish(.sessionPhaseChanged(
            sessionID: "restored",
            phase: SessionPhase(id: "verify", label: "Verify", ordinal: 4, group: .verify)
        ))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: "user-1"), text: "Run the checks"))
        await bus.publish(.thinkingChunk(blockID: thinkingID, delta: "Inspecting failures"))
        await bus.publish(.thinkingComplete(blockID: thinkingID, duration: .seconds(2)))
        await bus.publish(.toolStart(
            id: "tool-1",
            name: "Tests",
            input: ToolInput(summary: "swift test"),
            startedAt: Date(timeIntervalSince1970: 1)
        ))
        await bus.publish(.toolEnd(
            id: "tool-1",
            success: true,
            output: ToolOutput(summary: "Passed"),
            durationMS: 10
        ))
        await bus.publish(.assistantText(
            id: "assistant-1",
            blockID: "answer-1",
            text: "All checks pass.",
            isFinal: true
        ))
        await bus.publish(.sessionHistoryRestored(sessionID: "restored"))
        await drain()

        #expect(vm.messages.contains { if case .user = $0 { true } else { false } })
        #expect(vm.messages.contains { if case .thinkingComplete = $0 { true } else { false } })
        #expect(vm.messages.contains { if case .assistant = $0 { true } else { false } })
        #expect(WorkLaneView.hasContent(model: vm))
        #expect(SessionScrubber.segmentCount(for: vm) == 1)

        await bus.shutdown()
    }

    @Test("WorkLaneView has content when there are changed files, even with no tools this turn")
    func hasContentTrueForChangedFiles() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        let cwd = TestPaths.underTemporary("proj")
        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: cwd))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "hello"))
        await bus.publish(.fileTouched(cwd.appendingPathComponent("src/main.swift"), kind: .fsObserved))
        await drain()

        #expect(WorkLaneView.hasContent(model: vm))

        await bus.shutdown()
    }

    @Test("WorkLaneView has content when a transcript code preview is selected")
    func hasContentTrueForCodePreview() async {
        let (vm, bus) = makeModel()
        vm.subscribe()
        defer { vm.unsubscribe() }

        await bus.publish(.sessionStarted(sessionID: "s1", model: nil, cwd: TestPaths.underTemporary("proj")))
        await bus.publish(.userTurn(id: AdapterTurnID(rawValue: UUID().uuidString), text: "hello"))
        await drain()

        #expect(WorkLaneView.hasContent(
            model: vm,
            selectedCodePreview: WorkbenchCodePreview(code: "print(\"hi\")", language: "swift")
        ))

        await bus.shutdown()
    }

    @Test("workbench lane mins leave room for the index rail in a typical detail column")
    func workbenchLaneMinsDoNotOverflowDetail() {
        // A 1200pt window with the ideal ~260pt sidebar leaves ~940pt for detail.
        // Rail + transcript min + work min must fit so the Turns rail is
        // never clipped under the NavigationSplitView sidebar.
        let typicalDetailWidth: CGFloat = 1200 - Theme.layout.sessionSidebarIdealWidth
        let occupied = Theme.layout.indexRailWidth
            + Theme.layout.transcriptMinWidth
            + Theme.layout.workLaneMinWidth
        #expect(occupied <= typicalDetailWidth)
        #expect(Theme.layout.transcriptMinWidth < Theme.layout.workspaceSidebarMinWidth)
    }
}

// MARK: - Helpers

@MainActor
private func makeModel() -> (EngineViewModel, MulticastEventBus) {
    let bus = MulticastEventBus()
    let vm = EngineViewModel(engine: StubLaneVisibilityCommandPort(), bus: bus)
    return (vm, bus)
}

/// Allow the event bus to deliver events to the subscriber task.
@MainActor
private func drain() async {
    try? await Task.sleep(for: .milliseconds(40))
}

private final class StubLaneVisibilityCommandPort: AgentEngineCommandPort, @unchecked Sendable {
    func send(_ command: AgentCommand) async throws {}
}
