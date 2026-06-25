import Testing
@testable import AgentUI

@Suite("Interaction coverage — AgentCommand affordances")
struct InteractionCoverageTests {

    @Test("Every AgentCommand shape is covered by Mac UI or documented remote-only")
    func everyCommandShapeIsAccountedFor() {
        let accountedFor = InteractionCoverage.macUI.union(InteractionCoverage.remoteOnly)
        #expect(accountedFor == Set(InteractionCoverage.CommandShape.allCases))
    }

    @Test("Remote-only exceptions stay explicit and narrow")
    func remoteOnlyExceptionsAreNarrow() {
        #expect(InteractionCoverage.remoteOnly == [.respondToInlinePrompt])
    }
}
