import Foundation
import Testing

import AgentCore
import AgentProtocol
import ClaudeCode

@Suite("Claude model catalog")
struct ClaudeModelCatalogTests {
    @Test("Parses Available list from print-mode /model text")
    func parsesAvailableList() {
        let text = """
        Current model: Haiku 4.5
        Usage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opusplan, default, or a full model ID.
        """
        let efforts = [
            AgentModelOption.ThinkingEffort(code: "low"),
            AgentModelOption.ThinkingEffort(code: "medium"),
            AgentModelOption.ThinkingEffort(code: "high"),
        ]
        let models = ClaudeModelCatalog.parsePrintModelOutput(text, thinkingEfforts: efforts)
        #expect(models.map(\.code) == [
            "sonnet", "opus", "haiku", "fable", "best", "sonnet[1m]", "opusplan", "default",
        ])
        #expect(models.map(\.name) == [
            "Sonnet", "Opus", "Haiku", "Fable", "Best", "Sonnet (1M)", "Opus Plan", "Default",
        ])
        #expect(models.first?.thinkingEffort == "medium")
        #expect(models.first?.supportedThinkingEfforts.map(\.code) == ["low", "medium", "high"])
    }

    @Test("Parses JSON envelope result field")
    func parsesJSONEnvelope() {
        let json = #"""
        {"type":"result","result":"Usage: /model <name>. Available: sonnet, opus, haiku, or a full model ID."}
        """#
        let models = ClaudeModelCatalog.parsePrintModelOutput(json)
        #expect(models.map(\.code) == ["sonnet", "opus", "haiku"])
    }

    @Test("Parses /effort levels and skips auto")
    func parsesEffortLevels() {
        let text = "Usage: /effort <low|medium|high|xhigh|max|auto>"
        let efforts = ClaudeModelCatalog.parseEffortOutput(text)
        #expect(efforts.map(\.code) == ["low", "medium", "high", "xhigh", "max"])
    }

    @Test("Adapter reports manual refresh kind")
    func manualRefreshKind() {
        let adapter = ClaudeAdapter()
        guard case .manual(let detail) = adapter.modelCatalogRefreshKind() else {
            Issue.record("Expected manual refresh kind")
            return
        }
        #expect(detail.contains("print mode"))
        #expect(adapter.availableModels().isEmpty)
        adapter.seedModelCatalog([AgentModelOption(code: "sonnet", name: "Sonnet")])
        #expect(adapter.availableModels().map(\.code) == ["sonnet"])
    }
}
