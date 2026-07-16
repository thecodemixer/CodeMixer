import Foundation
import Testing
@testable import AgentCore
@testable import AgentProtocol

@Suite("AgentError")
struct AgentErrorTests {

    private func allCases() -> [AgentError] {
        [
            .binaryNotFound(agentID: .claudeCode, hint: "Install Claude Code"),
            .spawnFailed(errno: 22, detail: "EINVAL"),
            .hookSocketFailed(detail: "EADDRINUSE"),
            .transcriptDecodeFailed(path: "/x.jsonl", detail: "JSON error"),
            .workspaceInvalid(path: "/x", detail: "not a dir"),
            .authenticationRequired(agentID: .claudeCode),
            .staleEditTarget(targetID: UUID()),
            .unsupportedCommand(name: "/wat"),
            .engineRestartLimitReached,
            .permissionTimeout(promptID: UUID(), action: .deny),
            .internalInvariant(detail: "logic bug"),
            .unsupportedOperation(detail: "revertHunk"),
        ]
    }

    @Test("Every AgentError case has a non-empty code")
    func everyCodeIsNonEmpty() {
        for error in allCases() {
            #expect(!error.code.isEmpty, "empty code for \(error)")
        }
    }

    @Test("Every AgentError case has a non-empty userMessage")
    func everyMessageIsNonEmpty() {
        for error in allCases() {
            #expect(!error.userMessage.isEmpty, "empty message for \(error)")
        }
    }

    @Test("Codes are unique across cases")
    func codesAreUnique() {
        let codes = Set(allCases().map(\.code))
        #expect(codes.count == allCases().count)
    }

    @Test("Codes are stable identifiers, not localised strings")
    func codesAreStable() {
        #expect(AgentError.binaryNotFound(agentID: .claudeCode, hint: "").wireCode == .binaryNotFound)
        #expect(AgentError.spawnFailed(errno: 0, detail: "").wireCode == .spawnFailed)
        #expect(AgentError.unsupportedOperation(detail: "").wireCode == .unsupportedOperation)
    }

    @Test(".error event survives wire round-trip preserving the typed case")
    func errorEventPreservesCode() {
        for error in allCases() {
            let event = AgentEvent.error(error)
            let restored = WireCodec.decode(WireCodec.encode(event))
            guard case .error(let restoredErr) = restored else {
                Issue.record("not .error after round-trip: \(restored)"); continue
            }
            #expect(restoredErr == error, "round-trip mismatch for \(error)")
        }
    }

    @Test("AgentError is Equatable for matching arms")
    func equalityHolds() {
        let a = AgentError.staleEditTarget(targetID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let b = AgentError.staleEditTarget(targetID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let c = AgentError.staleEditTarget(targetID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        #expect(a == b)
        #expect(a != c)
    }
}
