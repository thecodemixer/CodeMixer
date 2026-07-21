import Foundation
import AgentCore

/// Converts markdown into a constrained, escaped HTML subset for the local
/// folder docs preview. No remote markdown dependency — reuses `MarkdownBlock`.
enum MarkdownHTMLRenderer {
    struct TOCItem: Hashable, Identifiable {
        var id: String { anchor }
        let level: Int
        let title: String
        let anchor: String
    }

    /// Renders markdown HTML. Relative image/link targets are rewritten only when
    /// they resolve inside `projectRoot`; otherwise they become plain text.
    /// Local images are inlined as `data:` URIs when `imageData` returns bytes —
    /// WKWebView does not reliably load sibling `file:` URLs from `loadHTMLString`.
    static func render(_ markdown: String,
                       projectRoot: URL? = nil,
                       documentDirectory: URL? = nil,
                       imageData: ((String) -> Data?)? = nil) -> String {
        let rewritten = rewriteInlineMedia(
            markdown,
            projectRoot: projectRoot,
            documentDirectory: documentDirectory,
            imageData: imageData
        )
        let blocks = MarkdownBlock.parse(rewritten)
        var html: [String] = []
        var usedAnchors = Set<String>()
        for block in blocks {
            html.append(render(block, usedAnchors: &usedAnchors))
        }
        return html.joined(separator: "\n")
    }

    /// Heading texts in document order for a simple TOC.
    static func tableOfContents(_ markdown: String) -> [(level: Int, title: String, anchor: String)] {
        tocItems(markdown).map { ($0.level, $0.title, $0.anchor) }
    }

    static func tocItems(_ markdown: String) -> [TOCItem] {
        var usedAnchors = Set<String>()
        var items: [TOCItem] = []
        for block in MarkdownBlock.parse(markdown) {
            if case .heading(let level, let text) = block {
                let anchor = uniqueAnchor(for: text, used: &usedAnchors)
                items.append(TOCItem(level: level, title: text, anchor: anchor))
            }
        }
        return items
    }

    /// Whether `relative` stays inside `projectRoot` when resolved from `baseDirectory`.
    static func containedRelativePath(_ relative: String,
                                      projectRoot: URL,
                                      baseDirectory: URL) -> String? {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("http://"),
              !trimmed.hasPrefix("https://"),
              !trimmed.hasPrefix("mailto:"),
              !trimmed.hasPrefix("#") else { return nil }
        let root = projectRoot.standardizedFileURL
        var base = baseDirectory.standardizedFileURL
        // Without directory semantics, `URL(fileURLWithPath:relativeTo:)` treats the
        // last path component as a file and drops it (docs/foo → project/foo).
        if !base.hasDirectoryPath {
            base = base.appendingPathComponent("", isDirectory: true)
        }
        let candidate = URL(fileURLWithPath: trimmed, relativeTo: base).standardizedFileURL
        let rootPath = root.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if candidatePath == rootPath { return nil }
        return String(candidatePath.dropFirst(prefix.count))
    }

    private static func rewriteInlineMedia(_ markdown: String,
                                           projectRoot: URL?,
                                           documentDirectory: URL?,
                                           imageData: ((String) -> Data?)?) -> String {
        guard let projectRoot else { return markdown }
        let base = documentDirectory ?? projectRoot
        var result = markdown
        // Images: ![alt](path)
        let imagePattern = try! NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)"#
        )
        let imageMatches = imagePattern.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ).reversed()
        for match in imageMatches {
            guard let altRange = Range(match.range(at: 1), in: result),
                  let pathRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let alt = String(result[altRange])
            let path = String(result[pathRange])
            if let relative = containedRelativePath(path, projectRoot: projectRoot, baseDirectory: base) {
                if let data = imageData?(relative),
                   let mime = mimeType(forRelativePath: relative) {
                    let src = "data:\(mime);base64,\(data.base64EncodedString())"
                    let replacement = "<img src=\"\(escapeAttribute(src))\" alt=\"\(escapeAttribute(alt))\" />"
                    result.replaceSubrange(fullRange, with: replacement)
                } else {
                    // Fallback: project-relative path (may not render in WKWebView).
                    let replacement = "<img src=\"\(escapeAttribute(relative))\" alt=\"\(escapeAttribute(alt))\" />"
                    result.replaceSubrange(fullRange, with: replacement)
                }
            } else if path.hasPrefix("http://") || path.hasPrefix("https://") {
                // Keep remote image markdown as escaped alt text — no embedded remote loads.
                result.replaceSubrange(fullRange, with: escapeText(alt.isEmpty ? path : alt))
            } else {
                result.replaceSubrange(fullRange, with: escapeText(alt.isEmpty ? path : alt))
            }
        }

        // Links: [text](path) — leave http(s) for the WebView policy to open externally.
        let linkPattern = try! NSRegularExpression(
            pattern: #"(?<!!)\[([^\]]+)\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)"#
        )
        let linkMatches = linkPattern.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        ).reversed()
        for match in linkMatches {
            guard let textRange = Range(match.range(at: 1), in: result),
                  let pathRange = Range(match.range(at: 2), in: result),
                  let fullRange = Range(match.range, in: result) else { continue }
            let text = String(result[textRange])
            let path = String(result[pathRange])
            if path.hasPrefix("http://") || path.hasPrefix("https://") || path.hasPrefix("#") {
                continue
            }
            if let relative = containedRelativePath(path, projectRoot: projectRoot, baseDirectory: base) {
                let replacement = "<a href=\"\(escapeAttribute(relative))\">\(escapeText(text))</a>"
                result.replaceSubrange(fullRange, with: replacement)
            } else {
                result.replaceSubrange(fullRange, with: escapeText(text))
            }
        }
        return result
    }

    private static func render(_ block: MarkdownBlock, usedAnchors: inout Set<String>) -> String {
        switch block {
        case .heading(let level, let text):
            let clamped = min(max(level, 1), 6)
            let anchor = uniqueAnchor(for: text, used: &usedAnchors)
            return "<h\(clamped) id=\"\(escapeAttribute(anchor))\">\(inline(text))</h\(clamped)>"
        case .paragraph(let text):
            // Already-rewritten <img>/<a> tags must pass through; escape the rest.
            return "<p>\(passthroughTrustedTags(text))</p>"
        case .unorderedList(let items):
            let body = items.map { "<li>\(passthroughTrustedTags($0))</li>" }.joined()
            return "<ul>\(body)</ul>"
        case .orderedList(let items):
            let body = items.map { "<li>\(passthroughTrustedTags($0))</li>" }.joined()
            return "<ol>\(body)</ol>"
        case .blockQuote(let text):
            return "<blockquote><p>\(passthroughTrustedTags(text))</p></blockquote>"
        case .code(let language, let code):
            let lang = language.map { " data-language=\"\(escapeAttribute($0))\"" } ?? ""
            let copyLabel = language.map { escapeAttribute($0) } ?? "code"
            return """
            <div class="code-block"><button class="copy" data-copy="\(escapeAttribute(code))" aria-label="Copy \(copyLabel)">Copy</button><pre\(lang)><code>\(escapeText(code))</code></pre></div>
            """
        }
    }

    private static func passthroughTrustedTags(_ text: String) -> String {
        // Split on our injected tags so ordinary markdown text stays escaped.
        let pattern = try! NSRegularExpression(
            pattern: #"(<img\b[^>]*/>)|(<a\b[^>]*>.*?</a>)"#
        )
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return inline(text) }
        var output = ""
        var cursor = 0
        for match in matches {
            let before = NSRange(location: cursor, length: match.range.location - cursor)
            if before.length > 0 {
                output += inline(ns.substring(with: before))
            }
            output += ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            output += inline(ns.substring(from: cursor))
        }
        return output
    }

    private static func inline(_ text: String) -> String {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return escapeText(String(attributed.characters))
        }
        return escapeText(text)
    }

    static func escapeText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escapeText(text).replacingOccurrences(of: "'", with: "&#39;")
    }

    static func mimeType(forRelativePath path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        default: return nil
        }
    }

    private static func uniqueAnchor(for title: String, used: inout Set<String>) -> String {
        let base = title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        var candidate = base.isEmpty ? "section" : base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }
}
