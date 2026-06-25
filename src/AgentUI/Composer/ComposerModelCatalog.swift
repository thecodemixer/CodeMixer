import Foundation

/// Model choices currently exposed by the composer model menu.
enum ComposerModelCatalog {
    struct Option: Sendable, Hashable {
        let label: String
        let id: String
    }

    static let defaultOption = Option(label: "Gemini 3.1 Pro",
                                      id: "gemini-3.1-pro")

    static let options: [Option] = [
        defaultOption,
        Option(label: "Claude 3.5 Sonnet",
               id: "claude-3-5-sonnet-20241022"),
    ]
}
