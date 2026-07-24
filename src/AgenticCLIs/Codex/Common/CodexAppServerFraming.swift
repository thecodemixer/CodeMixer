import Foundation
import AgentProtocol

/// Incremental newline-delimited JSON framer for Codex App Server stdio.
///
/// A single transport read may contain part of one JSON value or many values.
/// The framer retains only the unfinished suffix and rejects an unterminated
/// frame once it exceeds the bounded memory budget.
public struct CodexAppServerFraming: Sendable {
    public static let maximumFrameBytes = JSONLFraming.defaultMaximumFrameBytes

    private var framing = JSONLFraming(maximumFrameBytes: maximumFrameBytes)

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        do {
            return try framing.append(bytes)
        } catch JSONLFramingError.frameTooLarge(let count) {
            throw CodexAgentError.frameTooLarge(bytes: count)
        }
    }

    public static func frame(_ payload: Data) -> Data {
        JSONLFraming.frame(payload)
    }
}
