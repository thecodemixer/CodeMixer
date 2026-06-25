import SwiftUI
import AppKit

/// Block-level markdown renderer for assistant answers (visual-style §15).
///
/// Replaces the previous inline-only `AttributedString(markdown:)` so headings,
/// lists, block quotes, and — most importantly for a coding agent — fenced code
/// blocks render with real structure: code lands in a mono, sunken, highlighted
/// `CodeBlockView` instead of serif prose.
///
/// Prose blocks stay selectable and are exposed to TTS as one combined string
/// (`plainText`) so Read-Aloud reads the words and skips code.
struct MarkdownProseView: View {
    let text: String

    private var blocks: [MarkdownBlock] { MarkdownBlock.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s12) {
            ForEach(blocks) { block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Prose-only rendering of the content for TTS (code blocks omitted).
    static func plainText(_ text: String) -> String {
        MarkdownBlock.parse(text).compactMap { block -> String? in
            switch block {
            case .heading(_, let t):     return t
            case .paragraph(let t):      return t
            case .blockQuote(let t):     return t
            case .unorderedList(let items): return items.joined(separator: ". ")
            case .orderedList(let items):   return items.joined(separator: ". ")
            case .code:                  return nil  // skip code in spoken output
            }
        }.joined(separator: "\n")
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(level: level))
                .foregroundStyle(Theme.text.primary)
                .textSelection(.enabled)

        case .paragraph(let text):
            Text(inline(text))
                .font(Theme.typography.prose)
                .foregroundStyle(Theme.text.primary)
                .textSelection(.enabled)

        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    listRow(marker: "•", content: inline(item))
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    listRow(marker: "\(idx + 1).", content: inline(item))
                }
            }

        case .blockQuote(let text):
            HStack(spacing: Theme.spacing.s8) {
                RoundedRectangle(cornerRadius: Theme.corner.hairline)
                    .fill(Theme.surface.divider)
                    .frame(width: Theme.stroke.focus)
                Text(inline(text))
                    .font(Theme.typography.prose)
                    .foregroundStyle(Theme.text.secondary)
                    .textSelection(.enabled)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let language, let code):
            CodeBlockView(code: code, language: language)
        }
    }

    @ViewBuilder
    private func listRow(marker: String, content: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.spacing.s8) {
            Text(marker)
                .font(Theme.typography.prose)
                .foregroundStyle(Theme.text.tertiary)
                .monospacedDigit()
            Text(content)
                .font(Theme.typography.prose)
                .foregroundStyle(Theme.text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1, 2: return Theme.typography.title
        default:   return Theme.typography.label
        }
    }

    /// Inline emphasis (bold/italic/inline-code/links) within a block.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Fenced code block: mono text in a sunken well with a language chip and
/// hover/focus-revealed Copy + Open-in-editor actions (IntentReveal).
struct CodeBlockView: View {
    let code: String
    var language: String?

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .padding(.horizontal, Theme.spacing.s12)
                    .padding(.top, Theme.spacing.s8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeSyntaxHighlighter.highlight(code, language: language))
                    .font(Theme.typography.monoSmall)
                    .textSelection(.enabled)
                    .padding(Theme.spacing.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.surface.sunken,
                    in: RoundedRectangle(cornerRadius: Theme.corner.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.corner.medium, style: .continuous)
                .stroke(Theme.surface.divider, lineWidth: Theme.stroke.hairline)
        )
        .revealOnIntent(.hover) { actions }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.map { "Code block, \($0)" } ?? "Code block")
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Theme.spacing.s4) {
            Button {
                copy()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help(copied ? "Copied" : "Copy code")
            .accessibilityLabel(copied ? "Copied" : "Copy code")

            Button {
                openInEditor()
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help("Open in editor")
            .accessibilityLabel("Open in editor")
        }
        .foregroundStyle(Theme.text.secondary)
        .padding(Theme.spacing.s8)
    }

    private func copy() {
        DesktopActions.copyToPasteboard(code)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func openInEditor() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer-snippets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ext = Self.fileExtension(for: language)
        let file = dir.appendingPathComponent("snippet-\(UUID().uuidString).\(ext)")
        try? code.write(to: file, atomically: true, encoding: .utf8)
        DesktopActions.openURL(file)
    }

    private static func fileExtension(for language: String?) -> String {
        switch language?.lowercased() {
        case "swift":                   return "swift"
        case "python", "py":            return "py"
        case "javascript", "js":        return "js"
        case "typescript", "ts":        return "ts"
        case "json":                    return "json"
        case "bash", "sh", "shell", "zsh": return "sh"
        case "rust", "rs":              return "rs"
        case "go":                      return "go"
        case "c":                       return "c"
        case "cpp", "c++":              return "cpp"
        case "java":                    return "java"
        case "html":                    return "html"
        case "css":                     return "css"
        case "markdown", "md":          return "md"
        default:                        return "txt"
        }
    }
}
