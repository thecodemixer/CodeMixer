import AgentProtocol

/// Stable fallback model catalog used before live `model/list` integration.
public enum CodexModelCatalog {
    public static let builtIn: [AgentModelOption] = [
        AgentModelOption(id: "gpt-5.4", label: "GPT-5.4"),
        AgentModelOption(id: "gpt-5.3-codex", label: "GPT-5.3 Codex"),
        AgentModelOption(id: "gpt-5.2-codex", label: "GPT-5.2 Codex"),
    ]
}
