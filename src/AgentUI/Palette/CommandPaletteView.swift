import SwiftUI

/// A single executable entry in the command palette.
public struct PaletteCommand: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let systemImage: String
    public let run: () -> Void

    public init(id: String,
                title: String,
                subtitle: String? = nil,
                systemImage: String,
                run: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.run = run
    }
}

/// Cmd+K command palette: a centered, type-to-filter list of navigation and
/// scene actions. Mirrors what mouse/keyboard already reach (new chat, open a
/// project, resume a loaded session, toggle the navigator, search) so the
/// keyboard path has parity with the rest of the surfaces (principle 1.11).
///
/// Transport-neutral: model actions route through `EngineViewModel` (and thus
/// wire `AgentCommand`s); scene actions are injected as closures.
public struct CommandPaletteView: View {
    @Bindable var model: EngineViewModel
    let sceneCommands: [PaletteCommand]
    let onDismiss: () -> Void

    @State private var query: String = ""
    @State private var selection: Int = 0
    @FocusState private var fieldFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: EngineViewModel,
                sceneCommands: [PaletteCommand],
                onDismiss: @escaping () -> Void) {
        self.model = model
        self.sceneCommands = sceneCommands
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(spacing: 0) {
            field
            Divider().overlay(Theme.surface.divider)
            results
        }
        .frame(width: Theme.layout.globalPaletteWidth)
        .frame(maxHeight: Theme.layout.globalPaletteMaxHeight)
        .floatingPanelStyle()
        .shadow(color: .black.opacity(Theme.opacity.muted), radius: 24, y: 12)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .accessibilityAddTraits(.isModal)
    }

    private var field: some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: "command")
                .foregroundStyle(Theme.text.tertiary)
            TextField("Search actions, projects, sessions…", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.typography.body)
                .focused($fieldFocused)
                .onSubmit(runSelection)
                .accessibilityLabel("Command palette search")
        }
        .padding(.horizontal, Theme.spacing.s16)
        .padding(.vertical, Theme.spacing.s12)
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.spacing.s4) {
                    let items = filtered
                    if items.isEmpty {
                        Text("No matching commands")
                            .font(Theme.typography.caption)
                            .foregroundStyle(Theme.text.tertiary)
                            .padding(Theme.spacing.s16)
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, command in
                            row(command, selected: idx == selection)
                                .id(idx)
                                .onTapGesture { run(command) }
                        }
                    }
                }
                .padding(Theme.spacing.s8)
            }
            .onChange(of: selection) { _, idx in
                let animation = Theme.motion.resolve(Theme.motion.tactile, reduceMotion: reduceMotion)
                if let animation {
                    withAnimation(animation) { proxy.scrollTo(idx, anchor: .center) }
                } else {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }

    private func row(_ command: PaletteCommand, selected: Bool) -> some View {
        HStack(spacing: Theme.spacing.s12) {
            Image(systemName: command.systemImage)
                .accessibilityHidden(true)
                .foregroundStyle(Theme.text.secondary)
                .frame(width: Theme.spacing.s16)
            VStack(alignment: .leading, spacing: 0) {
                Text(command.title)
                    .font(Theme.typography.body)
                    .foregroundStyle(Theme.text.primary)
                    .lineLimit(1)
                if let subtitle = command.subtitle {
                    Text(subtitle)
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.text.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.spacing.s12)
        .padding(.vertical, Theme.spacing.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner.small, style: .continuous)
                .fill(selected ? Theme.surface.bubbleUser : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(command.title)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Commands

    private var allCommands: [PaletteCommand] {
        var items: [PaletteCommand] = []

        if model.workspace != nil {
            items.append(PaletteCommand(id: "new-chat",
                                        title: "New Chat",
                                        subtitle: "Start a fresh session in the current project",
                                        systemImage: "square.and.pencil") {
                model.newChat(in: model.workspace?.path ?? "")
            })
        }

        for project in model.projects {
            items.append(PaletteCommand(id: "project-\(project.path)",
                                        title: "New chat in \(project.displayName)",
                                        subtitle: project.path,
                                        systemImage: "folder") {
                model.newChat(in: project.path)
            })
        }

        if model.supportsResumableSessions {
            for (path, sessions) in model.sessionsByProject {
                let name = model.projects.first(where: { $0.path == path })?.displayName
                    ?? URL(fileURLWithPath: path).lastPathComponent
                for session in sessions {
                    items.append(PaletteCommand(id: "session-\(path)-\(session.id)",
                                                title: session.title,
                                                subtitle: "Resume · \(name)",
                                                systemImage: "clock.arrow.circlepath") {
                        model.openSession(projectPath: path, id: session.id)
                    })
                }
            }
        }

        items.append(contentsOf: sceneCommands)
        return items
    }

    private var filtered: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return allCommands }
        return allCommands.filter {
            $0.title.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }

    private func move(_ delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    private func runSelection() {
        let items = filtered
        guard items.indices.contains(selection) else { return }
        run(items[selection])
    }

    private func run(_ command: PaletteCommand) {
        onDismiss()
        command.run()
    }
}

#if DEBUG
#Preview("Command palette – Light") {
    CommandPaletteView(model: .preview,
                       sceneCommands: PreviewFixtures.paletteCommands(for: .preview),
                       onDismiss: {})
        .frame(width: 520, height: 360)
        .preferredColorScheme(.light)
}

#Preview("Command palette – Dark") {
    CommandPaletteView(model: .preview,
                       sceneCommands: PreviewFixtures.paletteCommands(for: .preview),
                       onDismiss: {})
        .frame(width: 520, height: 360)
        .preferredColorScheme(.dark)
}
#endif
