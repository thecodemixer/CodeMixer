import Foundation

/// A coarse block-level parse of assistant markdown.
///
/// Agent answers are mostly code, lists, and headings — not flowing prose — so
/// inline-only `AttributedString(markdown:)` (the previous renderer) dropped the
/// structure that matters most. This splits text into the handful of block
/// kinds the conversation actually needs (visual-style §15); inline emphasis
/// inside each non-code block is still handled by `AttributedString`.
///
/// Deliberately small and dependency-free: it is a pragmatic block splitter,
/// not a full CommonMark implementation.
public enum MarkdownBlock: Sendable, Hashable, Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case blockQuote(String)
    /// Fenced code block. `language` is the info string after the opening fence.
    case code(language: String?, code: String)

    public var id: String {
        switch self {
        case .heading(let l, let t):   return "h\(l):\(t)"
        case .paragraph(let t):        return "p:\(t)"
        case .unorderedList(let i):    return "ul:\(i.joined(separator: "|"))"
        case .orderedList(let i):      return "ol:\(i.joined(separator: "|"))"
        case .blockQuote(let t):       return "bq:\(t)"
        case .code(let lang, let c):   return "code:\(lang ?? "")|\(c)"
        }
    }

    /// Parse markdown into block-level elements, preserving order. Streaming-safe:
    /// an unterminated trailing fence is rendered as a code block so partial code
    /// still reads as code while it arrives.
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: "\n")
        var index = 0

        var paragraphBuffer: [String] = []
        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraphBuffer.removeAll()
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                index += 1  // consume closing fence (or run past the end if unterminated)
                blocks.append(.code(language: language.isEmpty ? nil : language,
                                    code: codeLines.joined(separator: "\n")))
                continue
            }

            // Heading.
            if let heading = Self.heading(from: trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            // Block quote (consume consecutive `>` lines).
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let q = lines[index].trimmingCharacters(in: .whitespaces)
                    quoteLines.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.blockQuote(quoteLines.joined(separator: "\n")))
                continue
            }

            // Unordered list.
            if Self.isUnorderedItem(trimmed) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count,
                      Self.isUnorderedItem(lines[index].trimmingCharacters(in: .whitespaces)) {
                    let t = lines[index].trimmingCharacters(in: .whitespaces)
                    items.append(String(t.dropFirst(2)))
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            // Ordered list.
            if Self.orderedItemContent(trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count,
                      let content = Self.orderedItemContent(lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(content)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // Blank line ends a paragraph.
            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            paragraphBuffer.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Line classifiers

    private static func heading(from trimmed: String) -> MarkdownBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        let level = hashes.count
        guard level >= 1, level <= 6 else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.first == " " else { return nil }
        return .heading(level: level,
                        text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isUnorderedItem(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
    }

    /// Returns the item text if `trimmed` is an ordered list item like `1. foo`.
    private static func orderedItemContent(_ trimmed: String) -> String? {
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard afterDigits.first == ".", afterDigits.dropFirst().first == " " else { return nil }
        return String(afterDigits.dropFirst(2))
    }
}
