import SwiftUI
import AppKit
import AgentCore

/// Table-browser preview chrome for folder projects (docs / logs / modelhike).
/// Used beside the folder file list and as the standalone sidebar-pin surface.
struct FolderViewPreviewPanel: View {
    @Bindable var browser: FolderViewModel
    let kind: FolderProjectKind
    var onClose: () -> Void
    /// Optional trailing action (e.g. “Show files” when opened from a sidebar pin).
    var trailingActionTitle: String? = nil
    var onTrailingAction: (() -> Void)? = nil

    @FocusState private var logFindFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if kind == .logs {
                logFindBar
            }
            Divider()
            HStack(spacing: 0) {
                if kind.usesMarkdownPreview,
                   browser.previewMode == .markdown,
                   !browser.tocItems.isEmpty {
                    tocSidebar
                    Divider()
                }
                previewBody
            }
        }
        .frame(minWidth: Theme.layout.folderPreviewMinWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .background(Theme.surface.canvas)
        .background {
            Button("Close Preview") { onClose() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
    }

    private var header: some View {
        HStack(spacing: Theme.spacing.s8) {
            Text(browser.previewTitle.isEmpty ? "Preview" : browser.previewTitle)
                .font(Theme.typography.label)
                .lineLimit(1)
            Spacer(minLength: 0)
            if kind == .logs {
                Toggle("Follow", isOn: Binding(
                    get: { browser.followLogs },
                    set: { browser.setFollowLogs($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Follow log")
                Toggle("Wrap", isOn: Binding(
                    get: { browser.lineWrap },
                    set: { browser.lineWrap = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Wrap lines")
            }
            if showsSourceToggle {
                Picker(selection: Binding(
                    get: { browser.docsShowSource },
                    set: { browser.setDocsShowSource($0) }
                )) {
                    Text("Preview")
                        .font(Theme.typography.caption)
                        .tag(false)
                    Text("Source")
                        .font(Theme.typography.caption)
                        .tag(true)
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(maxWidth: 120)
                .accessibilityLabel("Document preview mode")
            }
            if browser.previewCapped {
                Text("Showing last \(byteCountString(FolderBrowserLimits.logPreviewTailBytes))")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
            }
            if let entry = browser.selectedEntry, kind == .logs {
                Text(byteCountString(entry.byteCount))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                Text(entry.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .accessibilityLabel("Last updated \(entry.modifiedAt.formatted())")
            }
            if let trailingActionTitle, let onTrailingAction {
                Button(trailingActionTitle, action: onTrailingAction)
                    .accessibilityLabel(trailingActionTitle)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .buttonStyle(.plain)
            .help("Close preview")
            .accessibilityLabel("Close preview")
            .onHover { DesktopActions.setPointingHandCursor($0) }
        }
        .panelHeaderChrome(verticalPadding: Theme.spacing.s8)
    }

    /// The toggle is offered whenever the panel is showing a rendered document
    /// that also has a source form — markdown anywhere, markup files, and every
    /// file in a docs-style project.
    private var showsSourceToggle: Bool {
        let rendersDocument = browser.previewMode == .markdown
            || browser.previewMode == .source
            || browser.previewMode == .web
        guard rendersDocument else { return false }
        guard let entry = browser.selectedEntry else { return false }
        return kind.usesMarkdownPreview || FolderFileSupport.hasRenderedAndSourceViews(entry)
    }

    private var logFindBar: some View {
        SearchFieldBar(
            systemImage: "text.magnifyingglass",
            placeholder: "Find in log",
            text: Binding(get: { browser.logFindText }, set: { browser.logFindText = $0 }),
            focus: $logFindFocused,
            showsClear: !browser.logFindText.isEmpty,
            clearAccessibilityLabel: "Clear log find",
            onClear: { browser.logFindText = "" }
        )
    }

    private var tocSidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text("Contents")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .padding(.bottom, Theme.spacing.s4)
                ForEach(Array(browser.tocItems.enumerated()), id: \.element.anchor) { _, item in
                    Button {
                        browser.scrollToTOC(item.anchor)
                    } label: {
                        Text(item.title)
                            .font(Theme.typography.caption)
                            .foregroundStyle(Theme.text.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, Theme.spacing.s8 * CGFloat(max(item.level - 1, 0)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to \(item.title)")
                    .onHover { DesktopActions.setPointingHandCursor($0) }
                }
            }
            .padding(Theme.spacing.s12)
        }
        .frame(width: Theme.layout.diffSidebarIdealWidth)
        .background(Theme.surface.panel)
        .accessibilityLabel("Table of contents")
    }

    private var previewBody: some View {
        FilePreviewPanel(
            mode: browser.previewMode,
            text: browser.previewText,
            entry: browser.selectedEntry,
            fileURL: browser.selectedRelativePath.map(browser.absoluteURL(for:)),
            projectRoot: browser.root,
            fileSystem: browser.fileSystem,
            textPresentation: textPresentation,
            markdownAnchor: browser.pendingTOCAnchor,
            onMarkdownAnchorHandled: { browser.pendingTOCAnchor = nil },
            onRetry: { browser.refresh() }
        )
    }

    private var textPresentation: FilePreviewPanel.TextPresentation {
        if kind == .logs {
            return .log(
                find: browser.logFindText,
                lineWrap: browser.lineWrap,
                onUserScroll: { browser.pauseFollowFromUserScroll() }
            )
        }
        return .source(
            language: browser.selectedEntry.flatMap(FolderFileSupport.syntaxLanguage(for:)),
            lineWrap: browser.lineWrap
        )
    }
}

/// Standalone host for a sidebar pin / shortcut: loads one file and shows
/// `FilePreviewPanel` without the folder file list.
struct FilePreviewPanelHost: View {
    @Bindable var model: EngineViewModel
    let project: WorkspaceProjectsStore.ProjectRef
    let kind: FolderProjectKind
    let relativePath: String

    @State private var browser: FolderViewModel?

    var body: some View {
        Group {
            if let browser {
                FolderViewPreviewPanel(
                    browser: browser,
                    kind: kind,
                    onClose: {
                        model.pendingFolderSelectionRelativePath = nil
                        model.setActiveFolderSelection(nil)
                    },
                    trailingActionTitle: "Show files",
                    onTrailingAction: {
                        if let path = model.activeFolderSelectionRelativePath {
                            model.pendingFolderSelectionRelativePath = path
                        }
                        model.exitFolderPreviewOnly()
                    }
                )
            } else {
                ProgressView("Loading preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading preview")
            }
        }
        .background(Theme.surface.canvas)
        .onAppear { ensureBrowser() }
        .onChange(of: relativePath) { _, _ in recreateBrowser() }
        .onChange(of: project.path) { _, _ in recreateBrowser() }
        .onDisappear { browser?.stop() }
    }

    private func ensureBrowser() {
        guard browser == nil else { return }
        recreateBrowser()
    }

    private func recreateBrowser() {
        browser?.stop()
        let created = FolderViewModel(
            root: URL(fileURLWithPath: project.path),
            kind: kind,
            initialRelativePath: relativePath
        )
        browser = created
        created.start(previewOnly: true)
        model.setActiveFolderSelection(relativePath)
    }
}
