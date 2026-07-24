import SwiftUI

/// Sheet content for `SessionSidebarView`'s "Rename…" project context-menu
/// action. Self-contained: takes only the text binding and its two outcomes.
struct RenameProjectSheet: View {
    @Binding var name: String

    let onCancel: () -> Void
    let onRename: () -> Void

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s24) {
            VStack(alignment: .leading, spacing: Theme.spacing.s8) {
                Text("Rename Project")
                    .font(Theme.typography.title)
                Text("Renames the project folder on disk.")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text("Display name")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                TextField("Display name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.typography.body)
                    .accessibilityLabel("Project display name")
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel rename project")
                Button("Rename", action: onRename)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
                    .accessibilityLabel("Rename project")
            }
        }
        .padding(Theme.spacing.s24)
        .frame(minWidth: Theme.layout.agentPickerMinWidth,
               maxWidth: Theme.layout.agentPickerMaxWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.surface.canvas)
    }
}
