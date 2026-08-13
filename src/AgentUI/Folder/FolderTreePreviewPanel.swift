import SwiftUI
import AgentCore

/// Preview chrome for tree folder surfaces — markdown/source, text, binary,
/// and error states. No log follow or TOC rail.
struct FolderTreePreviewPanel: View {
    @Bindable var model: FolderTreeViewModel
    var onClose: () -> Void
    var trailingActionTitle: String? = nil
    var onTrailingAction: (() -> Void)? = nil
    /// Optional root folder name shown beside the file title (dual trees).
    var rootContextTitle: String? = nil
    var minWidth: CGFloat = Theme.layout.folderPreviewMinWidth
    /// When false, the parent owns Escape (dual trees clear both sides).
    var bindsEscapeShortcut: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            previewBody
        }
        .frame(minWidth: minWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .background(Theme.surface.canvas)
        .background {
            if bindsEscapeShortcut {
                Button("Close Preview") { onClose() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .hidden()
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.spacing.s8) {
            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                if let rootContextTitle, !rootContextTitle.isEmpty {
                    Text(rootContextTitle)
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.text.tertiary)
                        .lineLimit(1)
                }
                Text(model.previewTitle.isEmpty ? "Preview" : model.previewTitle)
                    .font(Theme.typography.label)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if showsSourceToggle {
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
                .accessibilityLabel("Document preview mode")
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

    /// Offered only for files that have both a rendered and a source form
    /// (markdown, HTML, SVG) — plain source files have nothing to toggle to.
    private var showsSourceToggle: Bool {
        guard let entry = model.previewedEntry,
              FolderFileSupport.hasRenderedAndSourceViews(entry) else { return false }
        return model.previewMode == .markdown
            || model.previewMode == .source
            || model.previewMode == .web
    }

    private var previewBody: some View {
        FilePreviewPanel(
            mode: model.previewMode,
            text: model.previewText,
            entry: model.previewedEntry,
            fileURL: model.previewedRelativePath.map(model.absoluteURL(for:)),
            projectRoot: model.root,
            fileSystem: model.fileSystem,
            textPresentation: .source(
                language: model.previewedEntry.flatMap(FolderFileSupport.syntaxLanguage(for:)),
                lineWrap: model.lineWrap
            ),
            markdownAnchor: nil,
            onMarkdownAnchorHandled: {},
            onRetry: { model.refresh() }
        )
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
