import SwiftUI
import AppKit
import AgentCore

/// Shared file preview chrome for folder projects (docs / logs / modelhike).
/// Used beside the folder file list and as the standalone sidebar-pin surface.
struct FilePreviewPanel: View {
    @Bindable var browser: FolderProjectBrowserModel
    let kind: FolderProjectKind
    var onClose: () -> Void
    /// Optional trailing action (e.g. “Show files” when opened from a sidebar pin).
    var trailingActionTitle: String? = nil
    var onTrailingAction: (() -> Void)? = nil

    @State private var qlBridge: QuickLookBridge?
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
            if kind.usesMarkdownPreview,
               browser.previewMode == .markdown || browser.previewMode == .source {
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
                .accessibilityLabel("Docs preview mode")
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

    @ViewBuilder
    private var previewBody: some View {
        switch browser.previewMode {
        case .none:
            // Preview panel is only mounted with a selection; `.none` means loading.
            ProgressView("Loading preview…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading preview")
        case .empty:
            ContentUnavailableView(
                "No files yet",
                systemImage: "folder",
                description: Text("This folder has no files to show.")
            )
        case .permissionDenied:
            VStack(spacing: Theme.spacing.s16) {
                ContentUnavailableView(
                    "Permission denied",
                    systemImage: "lock",
                    description: Text(browser.previewText.isEmpty
                                       ? "Codemixer cannot read this file or folder."
                                       : browser.previewText)
                )
                Button("Reveal in Finder") {
                    DesktopActions.revealInFinder(browser.root)
                }
                .accessibilityLabel("Reveal project in Finder")
                Button("Retry") { browser.refresh() }
                    .accessibilityLabel("Retry folder scan")
            }
        case .binary:
            VStack(spacing: Theme.spacing.s16) {
                ContentUnavailableView(
                    "Binary file",
                    systemImage: "doc.zipper",
                    description: Text("Open in the default app or use Quick Look.")
                )
                if let path = browser.selectedRelativePath {
                    HStack(spacing: Theme.spacing.s12) {
                        Button("Open") { DesktopActions.openURL(browser.absoluteURL(for: path)) }
                            .accessibilityLabel("Open selected file")
                        Button("Quick Look") { quickLook(url: browser.absoluteURL(for: path)) }
                            .accessibilityLabel("Quick Look selected file")
                    }
                }
            }
        case .error:
            VStack(spacing: Theme.spacing.s16) {
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(browser.previewText)
                )
                if let path = browser.selectedRelativePath {
                    Button("Open in Default App") {
                        DesktopActions.openURL(browser.absoluteURL(for: path))
                    }
                    .accessibilityLabel("Open unreadable file in default app")
                }
            }
        case .text:
            ZStack {
                ScrollView {
                    Text(highlightedLogText(browser.previewText, find: browser.logFindText))
                        .font(Theme.typography.monoSmall)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: browser.lineWrap ? .infinity : nil, alignment: .leading)
                        .padding(Theme.spacing.s16)
                }
                FolderLogScrollObserver {
                    browser.pauseFollowFromUserScroll()
                }
                .frame(width: 0, height: 0)
            }
        case .source:
            ScrollView {
                Text(browser.previewText)
                    .font(Theme.typography.monoSmall)
                    .fontDesign(.monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.spacing.s16)
            }
        case .markdown:
            LocalMarkdownPreviewView(
                markdown: browser.previewText,
                projectRoot: browser.root,
                documentDirectory: browser.selectedRelativePath.map {
                    browser.absoluteURL(for: $0).deletingLastPathComponent()
                } ?? browser.root,
                fileSystem: browser.fileSystem,
                scrollToAnchor: browser.pendingTOCAnchor
            )
            .onChange(of: browser.pendingTOCAnchor) { _, anchor in
                if anchor != nil {
                    DispatchQueue.main.async {
                        browser.pendingTOCAnchor = nil
                    }
                }
            }
        }
    }

    private func quickLook(url: URL) {
        qlBridge = presentQuickLook(url: url)
    }

    private func highlightedLogText(_ text: String, find: String) -> AttributedString {
        var attributed = AttributedString(text)
        let lower = text.lowercased()
        for token in ["error", "warning", "info", "debug"] {
            var searchStart = lower.startIndex
            while let range = lower.range(of: token, range: searchStart..<lower.endIndex) {
                if let attrRange = Range(range, in: attributed) {
                    switch token {
                    case "error":
                        attributed[attrRange].foregroundColor = Theme.signal.danger
                    case "warning":
                        attributed[attrRange].foregroundColor = Theme.signal.warning
                    case "info":
                        attributed[attrRange].foregroundColor = Theme.signal.info
                    default:
                        attributed[attrRange].foregroundColor = Theme.text.secondary
                    }
                }
                searchStart = range.upperBound
            }
        }
        if !find.isEmpty {
            var searchStart = lower.startIndex
            let needle = find.lowercased()
            while let range = lower.range(of: needle, range: searchStart..<lower.endIndex) {
                if let attrRange = Range(range, in: attributed) {
                    attributed[attrRange].backgroundColor = .yellow.opacity(0.35)
                }
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}

/// Standalone host for a sidebar pin / shortcut: loads one file and shows
/// `FilePreviewPanel` without the folder file list.
struct FilePreviewPanelHost: View {
    @Bindable var model: EngineViewModel
    let project: WorkspaceProjectsStore.ProjectRef
    let kind: FolderProjectKind
    let relativePath: String

    @State private var browser: FolderProjectBrowserModel?

    var body: some View {
        Group {
            if let browser {
                FilePreviewPanel(
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
        let created = FolderProjectBrowserModel(
            root: URL(fileURLWithPath: project.path),
            kind: kind,
            initialRelativePath: relativePath
        )
        browser = created
        created.start(previewOnly: true)
        model.setActiveFolderSelection(relativePath)
    }
}
