import SwiftUI
import AppKit
import AgentCore

/// Right-pane diff panel. Lists the changed files; selecting one loads the
/// per-file diff lazily through the bound `GitDiffEngine`.
///
/// Supports:
/// - Per-file context menus: Open, Reveal in Finder, Revert, Quick Look.
/// - Quick Look via `QLPreviewPanel.shared()`. A strong `qlBridge` reference
///   prevents the unowned-unsafe data source from being deallocated immediately.
/// - Revert button revealed on hover via `.revealOnIntent`.
public struct DiffPanelView: View {
    @Bindable public var model: EngineViewModel
    public let workspace: URL?

    @State private var selected: String?
    @State private var hunks: [DiffHunk] = []
    @State private var loadingPath: String?
    @State private var hoveredFullPath: String?
    // Keeps the QLPreviewPanelDataSource alive (panel holds an unowned ref).
    @State private var qlBridge: QuickLookBridge?

    public init(model: EngineViewModel, workspace: URL?) {
        self.model = model
        self.workspace = workspace
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                fileList
                Divider()
                hunkView
            }
        }
        .background(Theme.surface.panel)
        .frame(minWidth: Theme.layout.diffPanelMinWidth)
        .onChange(of: selected) { _, new in load(path: new) }
        .overlay(alignment: .topLeading) {
            if let hoveredFullPath {
                Text(hoveredFullPath)
                    .font(Theme.typography.monoSmall)
                    .fontDesign(.monospaced)
                    .foregroundStyle(Theme.text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, Theme.spacing.s8)
                    .padding(.vertical, Theme.spacing.s4)
                    .background(Theme.surface.card,
                                in: RoundedRectangle(cornerRadius: Theme.corner.small))
                    .overlay(RoundedRectangle(cornerRadius: Theme.corner.small)
                        .stroke(Theme.surface.divider, lineWidth: Theme.stroke.hairline))
                    .padding(.top, Theme.spacing.s48)
                    .padding(.leading, Theme.spacing.s16)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "doc.text.magnifyingglass")
                .accessibilityLabel("Changed files")
                .foregroundStyle(Theme.text.secondary)
            Text("Changes")
                .font(Theme.typography.label)
            Spacer()
            Text("\(model.changedFiles.count) file\(model.changedFiles.count == 1 ? "" : "s")")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.tertiary)
        }
        .panelHeaderChrome()
    }

    private var fileList: some View {
        List(selection: $selected) {
            ForEach(model.changedFiles, id: \.self) { path in
                let filename = displayName(for: path)
                let absolutePath = absolutePath(for: path)
                HStack {
                    Text(filename)
                        .font(Theme.typography.monoSmall)
                        .fontDesign(.monospaced)
                        .lineLimit(1)
                        .accessibilityLabel("Changed file \(path)")
                    Spacer()
                }
                .help(absolutePath)
                .onHover { hovering in
                    hoveredFullPath = hovering ? absolutePath : nil
                }
                .tag(path)
                .revealOnIntent {
                    Button {
                        model.revertFile(path: path)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .foregroundStyle(Theme.signal.danger)
                            .imageScale(.small)
                    }
                    .buttonStyle(.plain)
                    .help("Revert \(path) to HEAD")
                    .accessibilityLabel("Revert \(path) to HEAD")
                }
                .contextMenu {
                    Button("Open in Default App") { openInDefaultApp(path) }
                        .accessibilityLabel("Open \(path) in default app")
                    Button("Reveal in Finder") { revealInFinder(path) }
                        .accessibilityLabel("Reveal \(path) in Finder")
                    Button("Quick Look") { quickLook(path) }
                        .accessibilityLabel("Quick Look \(path)")
                    Divider()
                    Button("Revert to HEAD", role: .destructive) {
                        model.revertFile(path: path)
                    }
                    .accessibilityLabel("Revert \(path) to HEAD")
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: Theme.layout.diffSidebarMinWidth, idealWidth: Theme.layout.diffSidebarIdealWidth, maxWidth: Theme.layout.diffSidebarMaxWidth)
    }

    private var hunkView: some View {
        Group {
            if selected == nil {
                ContentUnavailableView("Select a file",
                                       systemImage: "rectangle.split.2x1",
                                       description: Text("Pick a changed file to see its diff."))
            } else if loadingPath == selected {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hunks.isEmpty {
                ContentUnavailableView("No diff",
                                       systemImage: "checkmark.circle",
                                       description: Text("File matches HEAD."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                        ForEach(hunks) { hunk in
                            HunkView(hunk: hunk) {
                                guard let selected else { return }
                                model.revertHunk(path: selected, hunkID: hunk.id)
                            }
                        }
                    }
                    .padding(Theme.spacing.s16)
                }
                .background(Theme.surface.canvas)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func load(path: String?) {
        guard let path, let workspace else { return }
        loadingPath = path
        Task {
            let engine = GitDiffEngine(workspace: workspace)
            let diff = (try? await engine.diff(for: path)) ?? FileDiff(relativePath: path, hunks: [])
            await MainActor.run {
                self.hunks = diff.hunks
                self.loadingPath = nil
            }
        }
    }

    private func openInDefaultApp(_ path: String) {
        DesktopActions.openURL(fileURL(for: path))
    }

    private func revealInFinder(_ path: String) {
        DesktopActions.revealInFinder(fileURL(for: path))
    }

    private func quickLook(_ path: String) {
        qlBridge = presentQuickLook(url: fileURL(for: path)) // retain until the panel is dismissed
    }

    private func fileURL(for path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return workspace?.appendingPathComponent(path) ?? URL(fileURLWithPath: path)
    }

    private func absolutePath(for path: String) -> String {
        fileURL(for: path).path
    }

    private func displayName(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - Hunk view

private struct HunkView: View {
    let hunk: DiffHunk
    let onRevert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.spacing.s8) {
                Text(hunk.header)
                    .font(Theme.typography.monoSmall)
                    .fontDesign(.monospaced)
                    .foregroundStyle(Theme.text.tertiary)
                Spacer()
                Button(action: onRevert) {
                    Image(systemName: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.signal.danger)
                .help("Revert this hunk")
                .accessibilityLabel("Revert this hunk")
            }
            .padding(.vertical, Theme.spacing.s4)
            .contextMenu {
                Button("Revert Hunk", role: .destructive, action: onRevert)
                    .accessibilityLabel("Revert this hunk")
            }
            ForEach(hunk.lines) { line in
                HStack(spacing: Theme.spacing.s8) {
                    Text(linePrefix(line.kind))
                        .frame(width: 12)
                        .foregroundStyle(prefixTint(line.kind))
                    Text(line.text.isEmpty ? " " : line.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(Theme.typography.monoSmall)
                .fontDesign(.monospaced)
                .padding(.horizontal, Theme.spacing.s4)
                .background(backgroundTint(line.kind))
                .contextMenu {
                    Button("Copy Line") {
                        DesktopActions.copyToPasteboard(line.text)
                    }
                    .accessibilityLabel("Copy this diff line to clipboard")
                }
            }
        }
        .padding(.bottom, Theme.spacing.s12)
    }

    private func linePrefix(_ kind: DiffLine.Kind) -> String {
        switch kind { case .addition: "+"; case .deletion: "-"; case .context: " " }
    }
    private func prefixTint(_ kind: DiffLine.Kind) -> Color {
        switch kind { case .addition: Theme.signal.success; case .deletion: Theme.signal.danger; case .context: Theme.text.tertiary }
    }
    private func backgroundTint(_ kind: DiffLine.Kind) -> Color {
        switch kind { case .addition: Theme.diff.addition; case .deletion: Theme.diff.deletion; case .context: Theme.diff.context }
    }
}

#if DEBUG
#Preview("Diff panel – Light") {
    DiffPanelView(model: .previewConversation, workspace: PreviewFixtures.workspace)
        .frame(width: 720, height: 420)
        .preferredColorScheme(.light)
}

#Preview("Diff panel – Dark") {
    DiffPanelView(model: .previewConversation, workspace: PreviewFixtures.workspace)
        .frame(width: 720, height: 420)
        .preferredColorScheme(.dark)
}
#endif
