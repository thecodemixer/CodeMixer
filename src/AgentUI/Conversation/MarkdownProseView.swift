import Foundation
import SwiftUI

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
    enum CodePresentation: Equatable {
        case expanded
        case collapsed
    }

    let text: String
    var codePresentation: CodePresentation = .expanded
    var onCollapsedCodeSelected: ((String, String?) -> Void)? = nil

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

    struct ReviewerComment: Sendable, Hashable, Identifiable {
        struct Finding: Sendable, Hashable, Identifiable {
            let id: String
            let severity: String
            let message: String
        }

        let id: String
        let reviewer: String
        let verdict: String
        let findings: [Finding]

        func isDuplicate(of other: ReviewerComment) -> Bool {
            verdict == other.verdict
                && findings.map(\.severity) == other.findings.map(\.severity)
                && findings.map(\.message) == other.findings.map(\.message)
        }
    }

    struct ReviewerContent: Sendable, Hashable {
        let prose: String?
        let comments: [ReviewerComment]
    }

    /// Pulls migration-tool reviewer verdicts out of assistant text even when
    /// streamed JSON and the later `Reviewer A/B: {…}` summary are concatenated
    /// into one paragraph (common with Custom ACP live streaming).
    static func reviewerContent(from text: String) -> ReviewerContent? {
        var comments: [ReviewerComment] = []
        var consumed = Set<Range<String.Index>>()
        var anonymousIndex = 0

        // Prefer labeled `Reviewer A: {…}` / `Reviewer B: {…}` spans.
        // Require the opening `{` on the same line so prose like
        // "Reviewer verdicts:" or "Reviewer A: not-json" cannot steal a later object.
        var search = text.startIndex
        while search < text.endIndex {
            guard let match = text.range(of: #"Reviewer [A-Za-z0-9_-]+:"#,
                                         options: .regularExpression,
                                         range: search..<text.endIndex) else { break }
            let label = String(text[match])
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let afterColon = match.upperBound
            let lineEnd = text[afterColon...].firstIndex(of: "\n") ?? text.endIndex
            let sameLine = text[afterColon..<lineEnd]
            guard let relativeBrace = sameLine.firstIndex(of: "{") else {
                search = afterColon
                continue
            }
            // `relativeBrace` is already a String.Index into `text` (substring shares indices).
            let brace = relativeBrace
            guard sameLine[afterColon..<brace].allSatisfy({ $0.isWhitespace }),
                  let jsonRange = balancedJSONObjectRange(in: text, from: brace),
                  let comment = reviewerComment(label: label,
                                                json: String(text[jsonRange]),
                                                id: label) else {
                search = afterColon
                continue
            }
            comments.append(comment)
            consumed.insert(match.lowerBound..<jsonRange.upperBound)
            search = jsonRange.upperBound
        }

        // Bare streamed verdict objects (no "Reviewer X:" prefix) still map to cards.
        search = text.startIndex
        while search < text.endIndex {
            guard let brace = text[search...].firstIndex(of: "{"),
                  let jsonRange = balancedJSONObjectRange(in: text, from: brace) else { break }
            if consumed.contains(where: { $0.overlaps(jsonRange) }) {
                search = jsonRange.upperBound
                continue
            }
            let json = String(text[jsonRange])
            guard looksLikeReviewerVerdictJSON(json) else {
                search = text.index(after: brace)
                continue
            }
            anonymousIndex += 1
            let label = "Reviewer"
            if let comment = reviewerComment(label: label,
                                             json: json,
                                             id: "\(label)-\(anonymousIndex)"),
               !comments.contains(where: { $0.isDuplicate(of: comment) }) {
                comments.append(comment)
                consumed.insert(jsonRange)
            }
            search = jsonRange.upperBound
        }

        guard !comments.isEmpty else { return nil }

        // Drop extracted spans so streamed JSON does not remain as a raw wall.
        let prose = removingRanges(consumed, from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleProse: String?
        if prose.isEmpty || looksLikeJSON(prose) || looksLikeReviewerVerdictJSON(prose) {
            visibleProse = nil
        } else {
            visibleProse = prose
        }
        return ReviewerContent(prose: visibleProse, comments: deduplicated(comments))
    }

    static func reviewerComments(from text: String) -> [ReviewerComment]? {
        reviewerContent(from: text)?.comments
    }

    private static func reviewerComment(label: String,
                                        json: String,
                                        id: String) -> ReviewerComment? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["verdict"] != nil else { return nil }
        let verdict = object["verdict"] as? String ?? "unknown"
        let findings = (object["findings"] as? [[String: Any]] ?? []).enumerated().map { offset, item in
            ReviewerComment.Finding(
                id: "\(id)-finding-\(offset)",
                severity: item["severity"] as? String ?? "info",
                message: item["message"] as? String ?? ""
            )
        }
        return ReviewerComment(id: id, reviewer: label, verdict: verdict, findings: findings)
    }

    private static func looksLikeReviewerVerdictJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let verdict = object["verdict"] as? String else { return false }
        return verdict == "approve" || verdict == "reject"
    }

    private static func balancedJSONObjectRange(in text: String,
                                                from start: String.Index) -> Range<String.Index>? {
        guard text[start] == "{" else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let ch = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                switch ch {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return start..<text.index(after: index)
                    }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func removingRanges(_ ranges: Set<Range<String.Index>>,
                                       from text: String) -> String {
        let ordered = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result = ""
        var cursor = text.startIndex
        for range in ordered {
            if cursor < range.lowerBound {
                result += text[cursor..<range.lowerBound]
            }
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result += text[cursor...]
        }
        return result
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
    }

    private static func deduplicated(_ comments: [ReviewerComment]) -> [ReviewerComment] {
        var unique: [ReviewerComment] = []
        for comment in comments {
            if let idx = unique.firstIndex(where: { $0.isDuplicate(of: comment) }) {
                // Prefer labeled "Reviewer A/B" over a bare streamed verdict object.
                if unique[idx].reviewer == "Reviewer",
                   comment.reviewer.hasPrefix("Reviewer ") {
                    unique[idx] = comment
                }
                continue
            }
            unique.append(comment)
        }
        return unique
    }

    static func codeLikeSnippet(from text: String) -> (code: String, language: String?)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if looksLikeJSON(trimmed) {
            return (trimmed, "json")
        }
        if looksLikeCode(trimmed) {
            return (trimmed, nil)
        }
        return nil
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
            if let reviewer = Self.reviewerContent(from: text) {
                VStack(alignment: .leading, spacing: Theme.spacing.s12) {
                    if let prose = reviewer.prose {
                        Text(inline(prose))
                            .font(Theme.typography.body)
                            .foregroundStyle(Theme.text.primary)
                            .textSelection(.enabled)
                    }
                    ReviewerCommentGroupView(comments: reviewer.comments)
                }
            } else if codePresentation == .collapsed,
                      let snippet = Self.codeLikeSnippet(from: text) {
                CollapsedCodeBlockView(code: snippet.code,
                                       language: snippet.language,
                                       onOpen: {
                                           onCollapsedCodeSelected?(snippet.code, snippet.language)
                                       })
            } else {
                Text(inline(text))
                    .font(Theme.typography.prose)
                    .foregroundStyle(Theme.text.primary)
                    .textSelection(.enabled)
            }

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
            switch codePresentation {
            case .expanded:
                CodeBlockView(code: code, language: language)
            case .collapsed:
                CollapsedCodeBlockView(code: code,
                                       language: language,
                                       onOpen: {
                                           onCollapsedCodeSelected?(code, language)
                                       })
            }
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

    private static func looksLikeJSON(_ text: String) -> Bool {
        guard (text.hasPrefix("{") && text.hasSuffix("}"))
            || (text.hasPrefix("[") && text.hasSuffix("]")) else { return false }
        guard let data = text.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let codePrefixes = ["import ", "export ", "const ", "let ", "var ", "func ", "function ",
                            "class ", "struct ", "enum ", "interface ", "type ", "return "]
        if lines.contains(where: { line in codePrefixes.contains(where: line.hasPrefix) }) {
            return true
        }
        let structuralLines = lines.filter { line in
            line.hasSuffix("{") || line.hasSuffix("}") || line.hasSuffix(";") || line.contains("=>")
        }
        return lines.count >= 2 && structuralLines.count >= 2
    }
}

private struct ReviewerCommentGroupView: View {
    let comments: [MarkdownProseView.ReviewerComment]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            ForEach(comments) { comment in
                ReviewerCommentView(comment: comment)
            }
        }
    }
}

private struct ReviewerCommentView: View {
    let comment: MarkdownProseView.ReviewerComment

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            HStack(spacing: Theme.spacing.s8) {
                Image(systemName: comment.verdict == "approve" ? "checkmark.seal" : "exclamationmark.triangle")
                    .foregroundStyle(comment.verdict == "approve" ? Theme.signal.success : Theme.signal.warning)
                    .accessibilityHidden(true)
                Text(comment.reviewer)
                    .font(Theme.typography.label)
                    .foregroundStyle(Theme.text.primary)
                Text(comment.verdict)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            if comment.findings.isEmpty {
                Text("No findings")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
            } else {
                VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                    ForEach(comment.findings) { finding in
                        Text("[\(finding.severity)] \(finding.message)")
                            .font(Theme.typography.caption)
                            .foregroundStyle(Theme.text.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.spacing.s12)
        .padding(.vertical, Theme.spacing.s8)
        .background(Theme.surface.bubble,
                    in: RoundedRectangle(cornerRadius: Theme.corner.medium, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(comment.reviewer), \(comment.verdict)")
    }
}

/// Lightweight transcript placeholder for fenced code. Full code still lives in
/// diffs/tools; rendering syntax-highlighted blocks in the live transcript made
/// Custom ACP updates slow and visually noisy.
private struct CollapsedCodeBlockView: View {
    let code: String
    var language: String?
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Theme.spacing.s8) {
            Button {
                onOpen?()
            } label: {
                HStack(spacing: Theme.spacing.s8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(Theme.text.tertiary)
                        .accessibilityHidden(true)
                    Text(summary)
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.text.secondary)
                    Spacer(minLength: 0)
                    Text("Show in work lane")
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.signal.info)
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Show collapsed code block in work lane")

            Spacer(minLength: 0)
            Button("Copy") {
                DesktopActions.copyToPasteboard(code)
            }
            .buttonStyle(.plain)
            .font(Theme.typography.caption)
            .foregroundStyle(Theme.signal.info)
            .accessibilityLabel("Copy collapsed code block")
        }
        .padding(.horizontal, Theme.spacing.s12)
        .padding(.vertical, Theme.spacing.s8)
        .background(Theme.surface.sunken,
                    in: RoundedRectangle(cornerRadius: Theme.corner.medium, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var summary: String {
        let lineCount = max(1, code.split(separator: "\n", omittingEmptySubsequences: false).count)
        let label = language.map { "\($0) " } ?? ""
        return "\(label)code block collapsed · \(lineCount) line\(lineCount == 1 ? "" : "s")"
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
                    .fontDesign(.monospaced)
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
        let ext = Self.fileExtension(for: language)
        DesktopActions.openCodeSnippet(code, fileExtension: ext)
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
