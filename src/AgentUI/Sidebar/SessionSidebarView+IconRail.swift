import SwiftUI

/// The collapsed "focus mode" rail: New Chat, one icon button per project
/// (with an attention dot), and the expand toggle. Self-contained — it reads
/// only `model`/`focusMode` from the owning view, no rename/search/hover
/// state, so it lives beside `SessionSidebarView.swift` as its own concern.
extension SessionSidebarView {
    var iconRail: some View {
        VStack(spacing: Theme.spacing.s12) {
            Button {
                model.newChatInCurrentProject()
            } label: {
                Image(systemName: "square.and.pencil").imageScale(.medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text.secondary)
            .help("New chat in current project")
            .accessibilityLabel("New chat in current project")
            .disabled(model.workspace == nil || model.showsFolderBrowser)

            Divider().overlay(Theme.surface.divider).padding(.horizontal, Theme.spacing.s8)

            ScrollView {
                VStack(spacing: Theme.spacing.s8) {
                    ForEach(model.projects) { project in
                        railProjectButton(project)
                    }
                }
                .padding(.top, Theme.spacing.s4)
            }
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)

            Button { focusMode = false } label: {
                Image(systemName: "arrow.left.to.line.compact").imageScale(.medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text.secondary)
            .help("Expand navigator")
            .accessibilityLabel("Expand navigator")
        }
        .padding(.vertical, Theme.spacing.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func railProjectButton(_ project: WorkspaceProjectsStore.ProjectRef) -> some View {
        let isCurrent = model.workspace?.path == project.path
        let attention = attentionSessionCount(for: project.path)
        return Button { model.selectProject(path: project.path) } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "folder")
                    .accessibilityHidden(true)
                    .imageScale(.medium)
                    .foregroundStyle(isCurrent ? Theme.text.primary : Theme.text.tertiary)
                    .frame(width: Theme.spacing.s32, height: Theme.spacing.s32)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.corner.small, style: .continuous)
                            .fill(isCurrent ? Theme.surface.bubbleUser : Color.clear)
                    )
                if attention > 0 {
                    Circle()
                        .fill(Theme.signal.warning)
                        .frame(width: Theme.spacing.s8, height: Theme.spacing.s8)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Select \(project.displayName)")
        .accessibilityLabel(
            attention > 0
                ? "Select project \(project.displayName), \(attention) sessions need attention"
                : "Select project \(project.displayName)"
        )
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}
