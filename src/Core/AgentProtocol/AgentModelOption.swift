import Foundation

/// One selectable model exposed by an adapter for composer / toolbar menus.
///
/// Adapters own discovery (CLI output, cache files, protocol payloads). The UI
/// binds to `code` / `name`; `thinkingEffort` stays a separate field so agents
/// that parameterize reasoning independently of the model slug can round-trip
/// both without baking effort into the display name.
public struct AgentModelOption: Sendable, Hashable, Codable, Identifiable {
    /// Wire / adapter model code (e.g. `gpt-5.6-sol`, `sonnet`).
    public let code: String
    /// Human-facing model name (e.g. `GPT-5.6 Sol`, `Sonnet`).
    public let name: String
    /// Default or currently selected thinking-effort code, when applicable.
    public let thinkingEffort: String?
    /// Thinking efforts this model supports (empty when the agent has none).
    public let supportedThinkingEfforts: [ThinkingEffort]

    public struct ThinkingEffort: Sendable, Hashable, Codable {
        public let code: String
        public let summary: String

        public init(code: String, summary: String = "") {
            self.code = code
            self.summary = summary
        }
    }

    public var id: String { code }
    public var label: String { name }

    public init(code: String,
                name: String,
                thinkingEffort: String? = nil,
                supportedThinkingEfforts: [ThinkingEffort] = []) {
        self.code = code
        self.name = name
        self.thinkingEffort = thinkingEffort
        self.supportedThinkingEfforts = supportedThinkingEfforts
    }

    /// Convenience for adapters that only expose a code and display name.
    public init(id: String, label: String) {
        self.init(code: id, name: label)
    }
}
