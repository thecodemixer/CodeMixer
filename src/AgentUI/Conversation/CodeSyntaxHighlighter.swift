import SwiftUI

/// A small, dependency-free syntax highlighter for fenced code blocks.
///
/// Rationale (see the `conversation-rendering` plan task): the package ships no
/// syntax-highlighting dependency, and pulling one in for v1 is more surface
/// than the feature needs. This tokenizer covers the constructs that read as
/// "code at a glance" across the C-family, Swift, Python, JS/TS, shell, and
/// JSON — comments, strings, numbers, and a shared keyword set — using
/// `Theme.signal.*` tints so it stays on-token and adapts to light/dark. It is
/// intentionally approximate; correctness of language grammar is a non-goal.
enum CodeSyntaxHighlighter {

    private static let keywords: Set<String> = [
        // Swift / C-family / general
        "func", "let", "var", "if", "else", "for", "while", "return", "guard",
        "switch", "case", "default", "break", "continue", "struct", "class",
        "enum", "protocol", "extension", "import", "public", "private",
        "internal", "fileprivate", "static", "final", "async", "await", "throws",
        "try", "throw", "do", "catch", "defer", "in", "where", "self", "nil",
        "true", "false", "init", "deinit", "typealias", "associatedtype",
        // Python
        "def", "elif", "lambda", "None", "True", "False", "and", "or", "not",
        "with", "as", "pass", "yield", "from", "global", "raise", "print",
        // JS/TS
        "function", "const", "type", "interface", "export", "new", "this",
        "void", "null", "undefined", "typeof", "instanceof", "extends",
        // shell
        "echo", "then", "fi", "done", "elif", "esac", "local", "export",
    ]

    static func highlight(_ code: String, language: String?) -> AttributedString {
        var result = AttributedString()
        let lines = code.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            result.append(highlightLine(line))
            if idx < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    private static func highlightLine(_ line: String) -> AttributedString {
        // Whole-line comment shortcut (covers //, #, --).
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("--") {
            var s = AttributedString(line)
            s.foregroundColor = Theme.text.tertiary
            return s
        }

        var output = AttributedString()
        var token = ""
        var inString = false
        var stringDelimiter: Character = "\""

        func flushToken() {
            guard !token.isEmpty else { return }
            var piece = AttributedString(token)
            if keywords.contains(token) {
                piece.foregroundColor = Theme.signal.info
            } else if isNumber(token) {
                piece.foregroundColor = Theme.signal.warning
            } else {
                piece.foregroundColor = Theme.text.primary
            }
            output.append(piece)
            token = ""
        }

        for ch in line {
            if inString {
                token.append(ch)
                if ch == stringDelimiter {
                    var piece = AttributedString(token)
                    piece.foregroundColor = Theme.signal.success
                    output.append(piece)
                    token = ""
                    inString = false
                }
                continue
            }

            if ch == "\"" || ch == "'" || ch == "`" {
                flushToken()
                inString = true
                stringDelimiter = ch
                token.append(ch)
                continue
            }

            if ch.isLetter || ch.isNumber || ch == "_" {
                token.append(ch)
            } else {
                flushToken()
                var piece = AttributedString(String(ch))
                piece.foregroundColor = Theme.text.secondary
                output.append(piece)
            }
        }
        // Flush trailing token / unterminated string.
        if inString {
            var piece = AttributedString(token)
            piece.foregroundColor = Theme.signal.success
            output.append(piece)
        } else {
            flushToken()
        }
        return output
    }

    private static func isNumber(_ token: String) -> Bool {
        guard let first = token.first, first.isNumber else { return false }
        return token.allSatisfy { $0.isNumber || $0 == "." || $0 == "x"
            || ("a"..."f").contains($0) || ("A"..."F").contains($0) }
    }
}
