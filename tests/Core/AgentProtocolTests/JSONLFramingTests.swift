import Foundation
import Testing
@testable import AgentProtocol

@Suite("JSONLFraming — shared stdio frame parser")
struct JSONLFramingTests {
    @Test("append buffers partial frames and emits complete payloads")
    func buffersPartialFrames() throws {
        var framing = JSONLFraming(maximumFrameBytes: 64)

        #expect(try framing.append(Data("{\"a\"".utf8)).isEmpty)
        let frames = try framing.append(Data(":1}\n{\"b\":2}\r\n\n".utf8))

        #expect(frames.map { String(decoding: $0, as: UTF8.self) } == [
            "{\"a\":1}",
            "{\"b\":2}",
        ])
    }

    @Test("frame appends a newline delimiter")
    func frameAppendsNewline() {
        let framed = JSONLFraming.frame(Data("{\"x\":1}".utf8))
        #expect(String(decoding: framed, as: UTF8.self) == "{\"x\":1}\n")
    }

    @Test("oversized unterminated frame reports byte count")
    func oversizedFrameThrows() {
        var framing = JSONLFraming(maximumFrameBytes: 4)

        #expect(throws: JSONLFramingError.frameTooLarge(bytes: 5)) {
            _ = try framing.append(Data("abcde".utf8))
        }
    }
}
