import SwiftUI
import AgentCore

/// Workspace picker shown when no workspace is open, or via File → Open Workspace.
///
/// The user picks a folder from disk; the engine resolves the workspace or
/// project type after selection and presents configuration only when needed.
public struct WorkspacePickerView: View {
    public let onOpen: (URL, _ resumeSessionID: String?) -> Void
    public let onCancel: () -> Void

    public init(onCancel: @escaping () -> Void = {},
                onOpen: @escaping (URL, _ resumeSessionID: String?) -> Void) {
        self.onCancel = onCancel
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(spacing: Theme.spacing.s24) {
            VStack(spacing: Theme.spacing.s8) {
                Image(systemName: "folder.fill.badge.gearshape")
                    .accessibilityHidden(true)
                    .font(Theme.typography.heroIcon)
                    .foregroundStyle(Theme.text.tertiary)
                Text("Open a workspace")
                    .font(Theme.typography.title)
                Text("Choose a folder from disk.")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .padding(.top, Theme.spacing.s32)

            Button("Choose Folder…") { chooseFolder() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return)
                .accessibilityLabel("Choose workspace folder")

            HStack(spacing: Theme.spacing.s12) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel open workspace")
            }
            .padding(.bottom, Theme.spacing.s24)
        }
        .frame(width: Theme.layout.projectPickerWidth)
        .fixedSize(horizontal: true, vertical: true)
        .background(Theme.surface.canvas)
    }

    private func chooseFolder() {
        if let url = DesktopActions.chooseDirectoryPanel() {
            open(url, resumeSessionID: nil)
        }
    }

    private func open(_ url: URL, resumeSessionID: String?) {
        onOpen(url, resumeSessionID)
    }
}

#if DEBUG
#Preview("Workspace picker – Light") {
    WorkspacePickerView { _, _ in }
        .frame(width: 360, height: 220)
        .preferredColorScheme(.light)
}

#Preview("Workspace picker – Dark") {
    WorkspacePickerView { _, _ in }
        .frame(width: 360, height: 220)
        .preferredColorScheme(.dark)
}
#endif
