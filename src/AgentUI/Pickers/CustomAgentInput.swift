import Foundation

/// Normalizes hand-typed or pasted custom-agent launch fields into the literal
/// strings persisted on `CustomAgentRef`.
///
/// These fields are almost always pasted from a shell or from Finder's "Copy as
/// Pathname", so they arrive wrapped in quotes or with backslash-escaped spaces.
/// Those characters are literal on disk: persisting them verbatim makes
/// `CustomACPBinaryLocator` search for a file whose name begins with a quote and
/// the adapter fails with `binaryNotFound` before any ACP handshake — a failure
/// that reads to the user as "the agent just never started".
enum CustomAgentInput {
    /// Unwraps one layer of surrounding quotes and resolves backslash escapes.
    ///
    /// An unbalanced leading quote is dropped rather than kept, because a
    /// half-selected paste (`"/usr/local/bin/agent`) is far more likely than a
    /// path whose first character really is a quote.
    static func executablePath(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let quote = trimmed.first, quote == "\"" || quote == "'" else {
            return unescaped(trimmed)
        }
        guard trimmed.count > 1, trimmed.last == quote else {
            return unescaped(String(trimmed.dropFirst()))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let inner = String(trimmed.dropFirst().dropLast())
        return quote == "'" ? inner : unescaped(inner)
    }

    /// Splits an argument line the way a POSIX shell would: whitespace separates
    /// tokens except inside quotes, and a backslash escapes the next character.
    ///
    /// Naive whitespace splitting mangles the common `--cwd "/My Projects/api"`
    /// case into three broken arguments.
    static func arguments(from raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isTokenOpen = false
        var openQuote: Character?
        var isEscaping = false

        for character in raw {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }
            if character == "\\", openQuote != "'" {
                isEscaping = true
                isTokenOpen = true
                continue
            }
            if let quote = openQuote {
                if character == quote {
                    openQuote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                openQuote = character
                isTokenOpen = true
                continue
            }
            if character.isWhitespace {
                if isTokenOpen {
                    tokens.append(current)
                    current = ""
                    isTokenOpen = false
                }
                continue
            }
            current.append(character)
            isTokenOpen = true
        }

        if isEscaping {
            current.append("\\")
        }
        if isTokenOpen {
            tokens.append(current)
        }
        return tokens
    }

    private static func unescaped(_ value: String) -> String {
        var result = ""
        var isEscaping = false
        for character in value {
            if isEscaping {
                result.append(character)
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                result.append(character)
            }
        }
        if isEscaping {
            result.append("\\")
        }
        return result
    }
}
