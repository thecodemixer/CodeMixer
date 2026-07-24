import SwiftUI

/// Claude tab: read-only paths/status reference. Codemixer never edits
/// Claude's settings outside the managed hook block, so there is nothing
/// here to configure yet.
struct ClaudeSettingsTab: View {
    var body: some View {
        Form {
            Section("Claude Code") {
                LabeledContent("Binary", value: "claude (auto-located)")
                LabeledContent("Settings file", value: "~/.claude/settings.json")
                LabeledContent("Transcript dir", value: "~/.claude/projects/")
            }
            Section("Status") {
                Text("Codemixer never edits Claude's settings outside the managed hook block.")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
