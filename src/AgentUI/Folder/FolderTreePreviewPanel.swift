import SwiftUI
import AgentCore

/// Preview chrome for `FolderProjectKind.folderTree` — markdown/source, text,
/// binary, and error states. No log follow or TOC rail.
struct FolderTreePreviewPanel: View {
    @Bindable var model: FolderTreeViewModel
    var onClose: () -> Void
    var trailingActionTitle: String? = nil
    var onTrailingAction: (() -> Void)? = nil

    @State private var qlBridge: QuickLookBridge?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            previewBody
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
            Text(model.previewTitle.isEmpty ? "Preview" : model.previewTitle)
                .font(Theme.typography.label)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let entry = model.selectedEntry, FolderFileSupport.isMarkdownFile(entry),
               model.previewMode == .markdown || model.previewMode == .source {
                Picker(selection: Binding(
                    get: { model.docsShowSource },
                    set: { model.setDocsShowSource($0) }
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
                .accessibilityLabel("Markdown preview mode")
            }
            Toggle("Wrap", isOn: Binding(
                get: { model.lineWrap },
                set: { model.lineWrap = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel("Wrap lines")
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

    @ViewBuilder
    private var previewBody: some View {
        switch model.previewMode {
        case .none:
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
                    description: Text(model.previewText.isEmpty
                                       ? "Codemixer cannot read this file or folder."
                                       : model.previewText)
                )
                Button("Reveal in Finder") {
                    DesktopActions.revealInFinder(model.root)
                }
                .accessibilityLabel("Reveal project in Finder")
                Button("Retry") { model.refresh() }
                    .accessibilityLabel("Retry folder scan")
            }
        case .binary:
            VStack(spacing: Theme.spacing.s16) {
                ContentUnavailableView(
                    "Binary file",
                    systemImage: "doc.zipper",
                    description: Text("Open in the default app or use Quick Look.")
                )
                if let path = model.selectedRelativePath {
                    HStack(spacing: Theme.spacing.s12) {
                        Button("Open") { DesktopActions.openURL(model.absoluteURL(for: path)) }
                            .accessibilityLabel("Open selected file")
                        Button("Quick Look") { quickLook(url: model.absoluteURL(for: path)) }
                            .accessibilityLabel("Quick Look selected file")
                    }
                }
            }
        case .error:
            VStack(spacing: Theme.spacing.s16) {
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(model.previewText)
                )
                if let path = model.selectedRelativePath {
                    Button("Open in Default App") {
                        DesktopActions.openURL(model.absoluteURL(for: path))
                    }
                    .accessibilityLabel("Open unreadable file in default app")
                }
            }
        case .text, .source:
            ScrollView {
                Text(model.previewText)
                    .font(Theme.typography.monoSmall)
                    .fontDesign(.monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: model.lineWrap ? .infinity : nil, alignment: .leading)
                    .padding(Theme.spacing.s16)
            }
        case .markdown:
            LocalMarkdownPreviewView(
                markdown: model.previewText,
                projectRoot: model.root,
                documentDirectory: model.selectedRelativePath.map {
                    model.absoluteURL(for: $0).deletingLastPathComponent()
                } ?? model.root,
                fileSystem: model.fileSystem,
                scrollToAnchor: nil
            )
        }
    }

    private func quickLook(url: URL) {
        qlBridge = presentQuickLook(url: url)
    }
}

#if DEBUG
#Preview("Folder Tree Preview") {
    let model = FolderTreeViewModel(root: URL(fileURLWithPath: "/tmp"))
    model.previewTitle = "README.md"
    model.previewMode = .text
    model.previewText = "# Hello\n\nPreview body."
    return FolderTreePreviewPanel(model: model, onClose: {})
        .frame(width: 480, height: 360)
}
#endif
