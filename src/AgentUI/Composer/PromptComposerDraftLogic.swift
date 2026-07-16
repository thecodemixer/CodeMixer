import Foundation

/// Draft-input triggers and token insertion helpers extracted from the composer view.
enum PromptComposerDraftLogic {

    struct PaletteTriggers: Equatable {
        var showSlashPalette: Bool
        var showFilePicker: Bool
        var filePickerQuery: String
    }

    static func slashQuery(from draft: String) -> String {
        draft.hasPrefix("/") ? String(draft.dropFirst()) : ""
    }

    static func paletteTriggers(for draft: String,
                                showSlashPalette: Bool,
                                showFilePicker: Bool) -> PaletteTriggers {
        let slashMatch = draft.hasPrefix("/") && !draft.contains(" ")
        var nextSlash = showSlashPalette
        if slashMatch != showSlashPalette { nextSlash = slashMatch }

        var nextFilePicker = showFilePicker
        var fileQuery = ""
        if let match = draft.lastMatch(of: /(?:^|\s)@(\S*)$/) {
            fileQuery = String(match.1)
            if !showFilePicker { nextFilePicker = true }
        } else if showFilePicker {
            nextFilePicker = false
        }

        return PaletteTriggers(showSlashPalette: nextSlash,
                               showFilePicker: nextFilePicker,
                               filePickerQuery: fileQuery)
    }

    static func fileReference(for url: URL, workspace: URL?) -> String {
        if let workspace, url.path.hasPrefix(workspace.path) {
            return "@" + url.path.replacingOccurrences(of: workspace.path + "/", with: "")
        }
        return "@" + url.path
    }

    static func insertToken(_ token: String, into draft: inout String) {
        draft += (draft.isEmpty ? "" : "\n") + token
    }

    static func insertAtPath(_ path: String, into draft: inout String) {
        if let range = draft.range(of: #"(?:^|\s)@\S*$"#,
                                   options: [.regularExpression, .backwards]) {
            let prefix = draft[..<range.lowerBound]
            let sep = draft[range.lowerBound] == " " ? " " : ""
            draft = String(prefix) + sep + "@" + path
        } else {
            draft += "@" + path
        }
    }
}

// MARK: - Regex helpers (Swift 5.7+ Regex literals)

extension String {
    func lastMatch(of regex: Regex<(Substring, Substring)>) -> (Substring, Substring)? {
        try? regex.firstMatch(in: self).map { ($0.output.0, $0.output.1) }
    }
}
