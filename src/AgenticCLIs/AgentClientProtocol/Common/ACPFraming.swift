import Foundation

/// Incremental newline-delimited JSON framer for ACP stdio JSON-RPC.
///
/// A single transport read may contain part of one JSON value or many values.
/// The framer retains only the unfinished suffix and rejects an unterminated
/// frame once it exceeds the bounded memory budget.
public struct ACPFraming: Sendable {
    public static let maximumFrameBytes = 4 * 1024 * 1024

    private var buffer = Data()

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        guard buffer.count <= Self.maximumFrameBytes || buffer.contains(Self.lineFeed) else {
            throw ACPAgentError.frameTooLarge(bytes: buffer.count)
        }

        var frames: [Data] = []
        while let newline = buffer.firstIndex(of: Self.lineFeed) {
            var frame = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if frame.last == Self.carriageReturn {
                frame.removeLast()
            }
            if !frame.isEmpty {
                guard frame.count <= Self.maximumFrameBytes else {
                    throw ACPAgentError.frameTooLarge(bytes: frame.count)
                }
                frames.append(frame)
            }
        }
        guard buffer.count <= Self.maximumFrameBytes else {
            throw ACPAgentError.frameTooLarge(bytes: buffer.count)
        }
        return frames
    }

    public static func frame(_ payload: Data) -> Data {
        var framed = payload
        framed.append(lineFeed)
        return framed
    }

    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
}
