import Foundation

/// One item in a markdown list, with the nesting and numbering the author wrote.
public struct MarkdownListItem: Sendable, Hashable {
    /// Nesting level, `0` for a top-level item. Derived from relative
    /// indentation, so both 2-space and 4-space sub-lists nest one level.
    public let depth: Int
    /// The author's own number for an ordered item; `nil` for a bullet. Kept
    /// rather than recomputed so a list that starts at `3.` still reads as one.
    public let ordinal: Int?
    public let text: String

    public init(depth: Int = 0, ordinal: Int? = nil, text: String) {
        self.depth = depth
        self.ordinal = ordinal
        self.text = text
    }
}

/// A coarse block-level parse of assistant markdown.
///
/// Agent answers are mostly code, lists, tables, and headings — not flowing
/// prose — so inline-only `AttributedString(markdown:)` (the previous renderer)
/// dropped the structure that matters most. This splits text into the handful of
/// block kinds the conversation actually needs (visual-style §15); inline
/// emphasis inside each non-code block is still handled by `AttributedString`.
///
/// Deliberately small and dependency-free: it is a pragmatic block splitter,
/// not a full CommonMark implementation. Known omissions: setext headings,
/// indented (unfenced) code blocks, and escaped pipes inside table cells.
public enum MarkdownBlock: Sendable, Hashable, Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([MarkdownListItem])
    case orderedList([MarkdownListItem])
    case blockQuote(String)
    /// Pipe table. `rows` are ragged-tolerant: a short row renders blank cells.
    case table(headers: [String], rows: [[String]])
    case thematicBreak
    /// Fenced code block. `language` is the info string after the opening fence.
    case code(language: String?, code: String)

    public var id: String {
        switch self {
        case .heading(let l, let t):   return "h\(l):\(t)"
        case .paragraph(let t):        return "p:\(t)"
        case .unorderedList(let i):    return "ul:\(Self.itemKey(i))"
        case .orderedList(let i):      return "ol:\(Self.itemKey(i))"
        case .blockQuote(let t):       return "bq:\(t)"
        case .table(let h, let r):     return "tbl:\(h.joined(separator: "|"))|\(r.count)"
        case .thematicBreak:           return "hr"
        case .code(let lang, let c):   return "code:\(lang ?? "")|\(c)"
        }
    }

    private static func itemKey(_ items: [MarkdownListItem]) -> String {
        items.map { "\($0.depth)/\($0.ordinal.map(String.init) ?? "")/\($0.text)" }
            .joined(separator: "|")
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

            // Thematic break. Checked before the list scanners: a bullet needs a
            // space after its marker, so `---` / `***` cannot be a list item.
            if Self.isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            // Pipe table — only when the row after the header is a delimiter row,
            // which is what separates a real table from prose containing pipes.
            if index + 1 < lines.count,
               trimmed.contains("|"),
               Self.isTableDelimiter(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let headers = Self.tableCells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard rowLine.contains("|"), !rowLine.isEmpty else { break }
                    rows.append(Self.tableCells(rowLine))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
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
                var depths = DepthTracker()
                var items: [MarkdownListItem] = []
                while index < lines.count {
                    let raw = lines[index]
                    let itemText = raw.trimmingCharacters(in: .whitespaces)
                    guard Self.isUnorderedItem(itemText) else { break }
                    items.append(MarkdownListItem(depth: depths.depth(forIndentOf: raw),
                                                  text: String(itemText.dropFirst(2))))
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            // Ordered list.
            if Self.orderedItem(trimmed) != nil {
                flushParagraph()
                var depths = DepthTracker()
                var items: [MarkdownListItem] = []
                while index < lines.count {
                    let raw = lines[index]
                    guard let item = Self.orderedItem(raw.trimmingCharacters(in: .whitespaces)) else { break }
                    items.append(MarkdownListItem(depth: depths.depth(forIndentOf: raw),
                                                  ordinal: item.ordinal,
                                                  text: item.text))
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

    // MARK: - Nesting

    /// Maps the indent widths seen inside one list onto contiguous depths, so a
    /// 2-space and a 4-space sub-list both nest exactly one level.
    private struct DepthTracker {
        private var widths: [Int] = []

        mutating func depth(forIndentOf line: String) -> Int {
            let width = MarkdownBlock.indentWidth(of: line)
            while let last = widths.last, last > width { widths.removeLast() }
            if widths.last != width { widths.append(width) }
            return max(0, widths.count - 1)
        }
    }

    private static func indentWidth(of line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += tabWidth } else { break }
        }
        return width
    }

    private static let tabWidth = 4

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

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3, let marker = trimmed.first,
              marker == "-" || marker == "*" || marker == "_" else { return false }
        return trimmed.allSatisfy { $0 == marker }
    }

    /// A delimiter row is what promotes a pipe line to a table: `|---|:--:|`.
    private static func isTableDelimiter(_ trimmed: String) -> Bool {
        guard trimmed.contains("|") else { return false }
        let cells = tableCells(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let core = cell.drop(while: { $0 == ":" }).reversed().drop(while: { $0 == ":" })
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    private static func tableCells(_ trimmed: String) -> [String] {
        var body = Substring(trimmed)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        return body.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isUnorderedItem(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
    }

    /// Returns the ordinal and text if `trimmed` is an ordered item like `3. foo`.
    private static func orderedItem(_ trimmed: String) -> (ordinal: Int, text: String)? {
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, let ordinal = Int(digits) else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard afterDigits.first == ".", afterDigits.dropFirst().first == " " else { return nil }
        return (ordinal, String(afterDigits.dropFirst(2)))
    }
}
