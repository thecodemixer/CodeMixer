import Foundation

import A2UICore
import AgentCore
import AgentProtocol

/// Decodes MIME-typed A2UI `EmbeddedResource` content blocks per the
/// CodeMixer A2UI-over-ACP v1 profile (`docs/architecture.md`). Activated
/// only by exact `mimeType == "application/a2ui+json"` — the `uri` is an
/// opaque accumulator key, never an authority or security boundary.
///
/// Scope note: real Custom ACP servers (including the migration tool) emit
/// one complete resource body per `session/update`/`tool_call` notification
/// rather than splitting a single JSON array across multiple deltas, so this
/// binding treats each observed resource as one self-contained batch rather
/// than accumulating partial UTF-8/JSON across chunks. If a server ever
/// streams a resource byte-by-byte, the JSON decode fails closed into one
/// `MALFORMED_RESOURCE` validation issue rather than corrupting state.
extension ACPEventDecoder {
    /// Finds one MIME-typed A2UI resource in an `agent_message_chunk`-style
    /// `content` block, or nested one level inside a `tool_call`/
    /// `tool_call_update` `content[].content` wrapper.
    func a2uiResource(in content: JSONValue?) -> (uri: String, text: String)? {
        guard let content else { return nil }
        if let direct = a2uiResourceBlock(content) { return direct }
        guard let array = content.arrayValue else { return nil }
        for item in array {
            if let direct = a2uiResourceBlock(item) { return direct }
            if let nested = item["content"], let direct = a2uiResourceBlock(nested) { return direct }
        }
        return nil
    }

    private func a2uiResourceBlock(_ value: JSONValue) -> (uri: String, text: String)? {
        guard value["type"]?.stringValue == "resource",
              let resource = value["resource"],
              resource["mimeType"]?.stringValue == A2UISchemaProfile.embeddedResourceMIMEType,
              let text = resource["text"]?.stringValue,
              let uri = resource["uri"]?.stringValue else { return nil }
        return (uri, text)
    }

    /// Decodes one complete resource body (a JSON array of `server_to_client`
    /// messages) into a typed, ordered `A2UIServerBatch`. Non-array roots,
    /// invalid UTF-8/JSON, and per-item shape failures become indexed
    /// `A2UIValidationIssue`s rather than dropping the whole resource —
    /// schema/limit validation against session state happens later in
    /// `A2UISurfaceReducer`, the one shared reduction authority.
    func a2uiBatchEvent(uri: String, text: String, sessionID: String) -> AgentEvent? {
        guard let context = state.context, !sessionID.isEmpty else { return nil }
        let key = A2UITranscriptKeyRef(projectRootPath: context.workspace.path,
                                       namespace: context.customAgentID,
                                       sessionID: sessionID)
        func batch(_ items: [A2UIServerBatch.Item]) -> AgentEvent {
            .a2uiBatch(A2UIServerBatch(agentID: context.customAgentID,
                                       transcriptKey: key,
                                       resourceURI: uri,
                                       items: items,
                                       recordedAt: clock.now()))
        }
        guard text.utf8.count <= A2UILimits.maxPayloadBytes else {
            return batch([.init(index: 0, message: nil, validationError: .init(code: "LIMIT_EXCEEDED", surfaceID: nil,
                                                                               message: "A2UI resource exceeds \(A2UILimits.maxPayloadBytes) bytes."))])
        }
        guard let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return batch([.init(index: 0, message: nil, validationError: .init(code: "MALFORMED_RESOURCE",
                                                                               surfaceID: nil,
                                                                               message: "A2UI resource text is not valid UTF-8 JSON."))])
        }
        guard let array = decoded.arrayValue else {
            return batch([.init(index: 0, message: nil, validationError: .init(code: "NON_ARRAY_ROOT", surfaceID: nil,
                                                                               message: "A2UI resource root must be a JSON array of messages."))])
        }
        guard array.count <= A2UILimits.maxBatchItems else {
            return batch([.init(index: 0, message: nil, validationError: .init(code: "LIMIT_EXCEEDED", surfaceID: nil,
                                                                               message: "A2UI batch exceeds \(A2UILimits.maxBatchItems) items."))])
        }
        let items: [A2UIServerBatch.Item] = array.enumerated().map { index, element in
            decodeItem(element, index: index)
        }
        return batch(items)
    }

    private func decodeItem(_ element: JSONValue, index: Int) -> A2UIServerBatch.Item {
        if let version = element["version"]?.stringValue,
           !A2UISchemaProfile.supportedVersions.contains(version) {
            return .init(index: index, message: nil, validationError: .init(code: "UNSUPPORTED_VERSION", surfaceID: nil,
                                                                            message: "Unsupported A2UI version '\(version)'."))
        }
        do {
            let jsonData = try JSONEncoder().encode(element)
            let message = try JSONDecoder().decode(A2UIServerMessage.self, from: jsonData)
            return .init(index: index, message: message, validationError: nil)
        } catch {
            return .init(index: index, message: nil, validationError: .init(code: "MALFORMED_MESSAGE", surfaceID: nil,
                                                                            message: "Item \(index): \(error)"))
        }
    }
}
