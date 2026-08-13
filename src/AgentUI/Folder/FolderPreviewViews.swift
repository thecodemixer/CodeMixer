import AppKit
import AgentCore
import SwiftUI

/// Rendering states shared by both folder browser models.
enum FilePreviewMode: String {
    case none
    case empty
    case text
    case markdown
    case source
    case image
    case pdf
    case web
    case media
    case binary
    case error
    case permissionDenied
}

/// Reusable file-content renderer shared by the table and tree folder browsers.
///
/// The parent owns chrome such as the title, markdown toggle, TOC, and log find
/// bar. This view owns every content state so files render identically wherever
/// they were selected.
struct FilePreviewPanel: View {
    enum TextPresentation {
        case source(language: String?, lineWrap: Bool)
        case log(find: String, lineWrap: Bool, onUserScroll: () -> Void)
    }

    let mode: FilePreviewMode
    let text: String
    let entry: FolderFileEntry?
    let fileURL: URL?
    let projectRoot: URL
    let fileSystem: any FileSystem
    let textPresentation: TextPresentation
    var markdownAnchor: String?
    var onMarkdownAnchorHandled: () -> Void
    var onRetry: () -> Void

    @State private var qlBridge: QuickLookBridge?

    @ViewBuilder
    var body: some View {
        switch mode {
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
                    description: Text(text.isEmpty
                        ? "Codemixer cannot read this file or folder."
                        : text)
                )
                Button("Reveal in Finder") {
                    DesktopActions.revealInFinder(projectRoot)
                }
                .accessibilityLabel("Reveal project in Finder")
                Button("Retry", action: onRetry)
                    .accessibilityLabel("Retry folder scan")
            }
        case .binary:
            VStack(spacing: Theme.spacing.s16) {
                ContentUnavailableView(
                    "Binary file",
                    systemImage: "doc.zipper",
                    description: Text("Open in the default app or use Quick Look.")
                )
                fileActions
            }
        case .error:
            VStack(spacing: Theme.spacing.s16) {
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(text)
                )
                if let fileURL {
                    Button("Open in Default App") {
                        DesktopActions.openURL(fileURL)
                    }
                    .accessibilityLabel("Open unreadable file in default app")
                }
            }
        case .image:
            if let fileURL {
                FolderImagePreview(
                    url: fileURL,
                    byteCount: entry?.byteCount ?? 0,
                    onOpen: { DesktopActions.openURL(fileURL) },
                    onQuickLook: { quickLook(fileURL) }
                )
            }
        case .pdf:
            if let fileURL {
                FolderPDFPreview(url: fileURL)
            }
        case .web:
            if let fileURL {
                FolderLocalFileWebView(url: fileURL, projectRoot: projectRoot)
            }
        case .media:
            VStack(spacing: Theme.spacing.s16) {
                ContentUnavailableView(
                    "Media file",
                    systemImage: "play.rectangle",
                    description: Text("Play with Quick Look or open in the default app.")
                )
                fileActions
            }
        case .text, .source:
            textBody
        case .markdown:
            LocalMarkdownPreviewView(
                markdown: text,
                projectRoot: projectRoot,
                documentDirectory: fileURL?.deletingLastPathComponent() ?? projectRoot,
                fileSystem: fileSystem,
                scrollToAnchor: markdownAnchor
            )
            .onChange(of: markdownAnchor) { _, anchor in
                if anchor != nil {
                    onMarkdownAnchorHandled()
                }
            }
        }
    }

    @ViewBuilder
    private var textBody: some View {
        switch textPresentation {
        case .source(let language, let lineWrap):
            FolderSourcePreview(text: text, language: language, lineWrap: lineWrap)
        case .log(let find, let lineWrap, let onUserScroll):
            ZStack {
                ScrollView(FolderTextScrollAxes.resolve(lineWrap: lineWrap)) {
                    Text(highlightedLogText(text, find: find))
                        .font(Theme.typography.monoSmall)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: lineWrap ? .infinity : nil, alignment: .leading)
                        .padding(Theme.spacing.s16)
                }
                FolderLogScrollObserver(onUserScroll: onUserScroll)
                    .frame(width: 0, height: 0)
            }
        }
    }

    @ViewBuilder
    private var fileActions: some View {
        if let fileURL {
            HStack(spacing: Theme.spacing.s12) {
                Button("Open") { DesktopActions.openURL(fileURL) }
                    .accessibilityLabel("Open selected file")
                Button("Quick Look") { quickLook(fileURL) }
                    .accessibilityLabel("Quick Look selected file")
            }
        }
    }

    private func quickLook(_ url: URL) {
        qlBridge = presentQuickLook(url: url)
    }

    private func highlightedLogText(_ text: String, find: String) -> AttributedString {
        var attributed = AttributedString(text)
        let lower = text.lowercased()
        for token in ["error", "warning", "info", "debug"] {
            tint(token, in: lower, attributed: &attributed)
        }
        if !find.isEmpty {
            tint(find.lowercased(), in: lower, background: .yellow.opacity(0.35), attributed: &attributed)
        }
        return attributed
    }

    private func tint(_ token: String,
                      in text: String,
                      background: Color? = nil,
                      attributed: inout AttributedString) {
        var searchStart = text.startIndex
        while let range = text.range(of: token, range: searchStart..<text.endIndex) {
            if let attributedRange = Range(range, in: attributed) {
                if let background {
                    attributed[attributedRange].backgroundColor = background
                } else {
                    attributed[attributedRange].foregroundColor = logColor(for: token)
                }
            }
            searchStart = range.upperBound
        }
    }

    private func logColor(for token: String) -> Color {
        switch token {
        case "error": return Theme.signal.danger
        case "warning": return Theme.signal.warning
        case "info": return Theme.signal.info
        default: return Theme.text.secondary
        }
    }
}

/// Scroll axes for a monospaced text body, derived from the Wrap toggle.
///
/// This is the whole mechanism behind Wrap, and it is easy to get wrong in both
/// directions: allowing horizontal scrolling proposes unbounded width, so the
/// text keeps its ideal width and never wraps; forbidding it leaves an unwrapped
/// body with no way to reach the end of a long line.
enum FolderTextScrollAxes {
    static func resolve(lineWrap: Bool) -> Axis.Set {
        lineWrap ? .vertical : [.vertical, .horizontal]
    }
}

/// Monospaced source/text body with approximate syntax highlighting.
///
/// Highlighting is skipped above `FolderBrowserLimits.syntaxHighlightMaxBytes`:
/// the tokenizer is O(characters) on the main thread, and a large file would
/// stall scrolling for a cosmetic gain.
struct FolderSourcePreview: View {
    let text: String
    let language: String?
    let lineWrap: Bool

    /// Identity for the highlight job: recompute when either input changes.
    private struct HighlightRequest: Equatable {
        let text: String
        let language: String?
    }

    @State private var highlighted: AttributedString?

    private var isHighlightable: Bool {
        language != nil && text.utf8.count <= FolderBrowserLimits.syntaxHighlightMaxBytes
    }

    var body: some View {
        ScrollView(FolderTextScrollAxes.resolve(lineWrap: lineWrap)) {
            content
                .font(Theme.typography.monoSmall)
                .fontDesign(.monospaced)
                .textSelection(.enabled)
                .frame(maxWidth: lineWrap ? .infinity : nil, alignment: .leading)
                .padding(Theme.spacing.s16)
        }
        .accessibilityLabel(language.map { "Source preview, \($0)" } ?? "Text preview")
        .task(id: HighlightRequest(text: text, language: language)) {
            await highlight()
        }
    }

    @ViewBuilder
    private var content: some View {
        // Plain text shows immediately and is replaced once tinting lands, so a
        // large file never holds up the first frame.
        if let highlighted {
            Text(highlighted)
        } else {
            Text(text)
        }
    }

    private func highlight() async {
        highlighted = nil
        guard isHighlightable else { return }
        let source = text
        let language = language
        // The tokenizer walks every character; on the main thread that is felt
        // as a stutter when stepping quickly through files.
        let result = await Task.detached(priority: .userInitiated) {
            CodeSyntaxHighlighter.highlight(source, language: language)
        }.value
        guard source == text else { return }
        highlighted = result
    }
}

/// Inline image body. Decoding happens off the main actor because a large
/// bitmap otherwise blocks the first frame of the preview.
struct FolderImagePreview: View {
    let url: URL
    let byteCount: Int
    var onOpen: () -> Void
    var onQuickLook: () -> Void

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                VStack(spacing: Theme.spacing.s8) {
                    ScrollView([.vertical, .horizontal]) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(Theme.spacing.s16)
                            .accessibilityLabel("Image preview of \(url.lastPathComponent)")
                    }
                    caption(for: image)
                }
            } else if failed {
                VStack(spacing: Theme.spacing.s16) {
                    ContentUnavailableView(
                        "Cannot display image",
                        systemImage: "photo",
                        description: Text("The file could not be decoded as an image.")
                    )
                    HStack(spacing: Theme.spacing.s12) {
                        Button("Open", action: onOpen)
                            .accessibilityLabel("Open image in default app")
                        Button("Quick Look", action: onQuickLook)
                            .accessibilityLabel("Quick Look image")
                    }
                }
            } else {
                ProgressView("Loading image…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading image")
            }
        }
        .task(id: url) { await load() }
    }

    private func caption(for image: NSImage) -> some View {
        HStack(spacing: Theme.spacing.s8) {
            Text("\(Int(image.size.width)) × \(Int(image.size.height))")
            Text(byteCountString(byteCount))
            Spacer(minLength: 0)
            Button("Open", action: onOpen)
                .buttonStyle(.plain)
                .accessibilityLabel("Open image in default app")
            Button("Quick Look", action: onQuickLook)
                .buttonStyle(.plain)
                .accessibilityLabel("Quick Look image")
        }
        .font(Theme.typography.caption)
        .foregroundStyle(Theme.text.tertiary)
        .padding(.horizontal, Theme.spacing.s16)
        .padding(.bottom, Theme.spacing.s8)
    }

    private func load() async {
        image = nil
        failed = false
        let target = url
        let decoded = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: target)
        }.value
        guard target == url else { return }
        if let decoded {
            image = decoded
        } else {
            failed = true
        }
    }
}

#if DEBUG
#Preview("Source preview") {
    FolderSourcePreview(
        text: """
        // A comment
        struct Sample {
            let value = 42
            func greet() -> String { "hello" }
        }
        """,
        language: "swift",
        lineWrap: true
    )
    .frame(width: 420, height: 240)
}
#endif
