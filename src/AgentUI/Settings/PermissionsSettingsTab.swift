import SwiftUI
import AgentCore
import AgentProtocol

/// Permissions tab: the editable auto-approval rule list (glob match against
/// `ToolName ArgumentsSummary`, first match wins).
struct PermissionsSettingsTab: View {
    @Bindable var model: EngineViewModel
    @State private var rules: [AutoApprovalRule] = []
    @State private var draftMatch: String = ""
    @State private var draftDecision: PermissionDecision = .allow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            Text("Auto-approval rules")
                .font(Theme.typography.label)
            Text("Glob pattern matched against `ToolName ArgumentsSummary`. First match wins.")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)

            List {
                ForEach($rules) { $rule in
                    HStack {
                        Toggle("", isOn: $rule.enabled).labelsHidden()
                        TextField("Pattern", text: $rule.match)
                            .font(Theme.typography.monoSmall)
                            .fontDesign(.monospaced)
                        Picker("", selection: $rule.decision) {
                            Text("Allow").tag(PermissionDecision.allow)
                            Text("Allow Always").tag(PermissionDecision.allowAlways)
                            Text("Deny").tag(PermissionDecision.deny)
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        Button(action: { rules.removeAll { $0.id == rule.id } }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove rule")
                    }
                }
            }
            .frame(minHeight: Theme.layout.remoteSettingsMinHeight)

            HStack {
                TextField("New pattern…", text: $draftMatch)
                    .font(Theme.typography.monoSmall)
                    .fontDesign(.monospaced)
                Picker("", selection: $draftDecision) {
                    Text("Allow").tag(PermissionDecision.allow)
                    Text("Deny").tag(PermissionDecision.deny)
                }
                .labelsHidden()
                .frame(width: 120)
                Button("Add") {
                    rules.append(AutoApprovalRule(match: draftMatch, decision: draftDecision))
                    draftMatch = ""
                }
                .disabled(draftMatch.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button("Save") {
                model.updateAutoApprovalRules(rules)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .task { rules = model.autoApprovalRules }
    }
}
