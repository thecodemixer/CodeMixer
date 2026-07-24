import Foundation

/// Incremental newline-delimited JSON framing shared by stdio JSON-RPC agents.
public struct JSONLFraming: Sendable {
    public static let defaultMaximumFrameBytes = 4 * 1024 * 1024

    private let maximumFrameBytes: Int
    private var buffer = Data()

    public init(maximumFrameBytes: Int = Self.defaultMaximumFrameBytes) {
        self.maximumFrameBytes = maximumFrameBytes
    }

    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        guard buffer.count <= maximumFrameBytes || buffer.contains(Self.lineFeed) else {
            throw JSONLFramingError.frameTooLarge(bytes: buffer.count)
        }

        var frames: [Data] = []
        while let newline = buffer.firstIndex(of: Self.lineFeed) {
            var frame = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if frame.last == Self.carriageReturn {
                frame.removeLast()
            }
            if !frame.isEmpty {
                guard frame.count <= maximumFrameBytes else {
                    throw JSONLFramingError.frameTooLarge(bytes: frame.count)
                }
                frames.append(frame)
            }
        }
        guard buffer.count <= maximumFrameBytes else {
            throw JSONLFramingError.frameTooLarge(bytes: buffer.count)
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

public enum JSONLFramingError: Error, Sendable, Equatable {
    case frameTooLarge(bytes: Int)
}
