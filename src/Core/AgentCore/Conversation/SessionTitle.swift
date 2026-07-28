/// Derives stable, compact sidebar titles from the first user turn.
import Foundation

enum SessionTitle {
    static let maximumLength = 80
    static let untitled = "New Chat"

    static func from(firstUserText: String?) -> String {
        guard let firstUserText else { return untitled }
        let firstLine = firstUserText
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !firstLine.isEmpty else { return untitled }
        guard firstLine.count > maximumLength else { return firstLine }
        return String(firstLine.prefix(maximumLength - 1)) + "…"
    }
}
