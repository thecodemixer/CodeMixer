import SwiftUI
import AgentCore

/// Dialog shown via File → Open Project.
///
/// Unlike the workspace recents picker, this is a focused "add a folder" prompt.
/// Recents are not shown because the project is being added to an existing
/// workspace rather than loaded as one. The user picks a folder; the engine
/// then resolves the project type (auto-detect → configure sheet if unknown).
public struct OpenProjectView: View {
    public let onCancel: () -> Void
    public let onOpen: (URL) -> Void

    public init(onCancel: @escaping () -> Void,
                onOpen: @escaping (URL) -> Void) {
        self.onCancel = onCancel
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(spacing: Theme.spacing.s24) {
            VStack(spacing: Theme.spacing.s8) {
                Image(systemName: "folder.badge.plus")
                    .accessibilityHidden(true)
                    .font(Theme.typography.heroIcon)
                    .foregroundStyle(Theme.text.tertiary)
                Text("Open a project")
                    .font(Theme.typography.title)
                Text("Choose a folder to add to the current workspace.")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, Theme.spacing.s32)

            Button("Choose Folder…") { pickFolder() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return)
                .accessibilityLabel("Choose project folder")

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel open project")
            }
            .padding(.bottom, Theme.spacing.s24)
        }
        .padding(.horizontal, Theme.spacing.s32)
        .frame(width: Theme.layout.openProjectWidth)
        .fixedSize(horizontal: true, vertical: true)
        .background(Theme.surface.canvas)
    }

    // MARK: - Private

    private func pickFolder() {
        guard let url = DesktopActions.chooseDirectoryPanel(prompt: "Add Project") else { return }
        onOpen(url)
    }
}
