import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Byte-oriented PTY stdin reader for interactive prompt submission.
enum PTYInputReader {
    enum Input: Equatable {
        case submit(String)
        case interrupt
        case permissionChoice(String)
        case eof
    }

    static func readNext() -> Input? {
        var byte: UInt8 = 0
        let count = read(STDIN_FILENO, &byte, 1)
        guard count == 1 else { return .eof }

        if byte == 0x03 { return .interrupt }
        if byte == 0x04 { return .eof }

        if byte == 0x31 || byte == 0x32 || byte == 0x33 {
            var line = String(UnicodeScalar(byte))
            while true {
                var next: UInt8 = 0
                let n = read(STDIN_FILENO, &next, 1)
                guard n == 1 else { break }
                if next == 0x0D || next == 0x0A { break }
                line.append(Character(UnicodeScalar(next)))
            }
            return .permissionChoice(line)
        }

        var buffer = [UInt8]()
        if byte != 0x0D && byte != 0x0A {
            buffer.append(byte)
        }
        while true {
            var next: UInt8 = 0
            let n = read(STDIN_FILENO, &next, 1)
            guard n == 1 else {
                if buffer.isEmpty { return .eof }
                break
            }
            if next == 0x0D || next == 0x0A { break }
            buffer.append(next)
        }
        let text = String(decoding: buffer, as: UTF8.self)
        return .submit(text)
    }
}
