import Foundation

import AgentProtocol

/// Parses ACP session-open model metadata into composer-facing options.
///
/// Cursor and other ACP agents may advertise models through the legacy
/// `models` object, the newer `configOptions` array, or both.
enum ACPModelCatalog {
    struct Snapshot: Equatable, Sendable {
        var currentModelID: String?
        var available: [AgentModelOption]
    }

    static func parse(models: JSONValue?, configOptions: [JSONValue]) -> Snapshot {
        let fromModels = parseModelsObject(models)
        if !fromModels.available.isEmpty {
            return fromModels
        }
        return parseModelConfigOptions(configOptions)
    }

    private static func parseModelsObject(_ models: JSONValue?) -> Snapshot {
        guard let models else { return Snapshot(currentModelID: nil, available: []) }
        let current = nonEmpty(models["currentModelId"]?.stringValue)
            ?? nonEmpty(models["currentModelID"]?.stringValue)
        let available = (models["availableModels"]?.arrayValue ?? [])
            .compactMap(option(from:))
        return Snapshot(currentModelID: current, available: available)
    }

    private static func parseModelConfigOptions(_ configOptions: [JSONValue]) -> Snapshot {
        for entry in configOptions {
            guard let object = entry.objectValue,
                  isModelConfigOption(object),
                  let options = object["options"]?.arrayValue,
                  !options.isEmpty else { continue }
            let current = nonEmpty(object["currentValue"]?.stringValue)
            let available = options.compactMap { entry -> AgentModelOption? in
                guard let object = entry.objectValue else { return nil }
                return configOption(from: object)
            }
            guard !available.isEmpty else { continue }
            return Snapshot(currentModelID: current, available: available)
        }
        return Snapshot(currentModelID: nil, available: [])
    }

    private static func isModelConfigOption(_ object: [String: JSONValue]) -> Bool {
        object["category"]?.stringValue == "model" || object["id"]?.stringValue == "model"
    }

    private static func option(from value: JSONValue) -> AgentModelOption? {
        guard let object = value.objectValue else { return nil }
        return configOption(from: object)
    }

    private static func configOption(from object: [String: JSONValue]) -> AgentModelOption? {
        let id = nonEmpty(object["modelId"]?.stringValue)
            ?? nonEmpty(object["id"]?.stringValue)
            ?? nonEmpty(object["value"]?.stringValue)
        guard let id else { return nil }
        let label = nonEmpty(object["name"]?.stringValue)
            ?? nonEmpty(object["label"]?.stringValue)
            ?? nonEmpty(object["title"]?.stringValue)
            ?? id
        return AgentModelOption(id: id, label: label)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
