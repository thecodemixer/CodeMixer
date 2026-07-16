import Foundation
import CryptoKit

/// One line in a diff hunk.
public struct DiffLine: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case context, addition, deletion }
    public let id: UUID
    public let text: String
    public let kind: Kind
    public let oldLineNumber: Int?
    public let newLineNumber: Int?

    public init(id: UUID,
                text: String,
                kind: Kind,
                oldLineNumber: Int? = nil,
                newLineNumber: Int? = nil) {
        self.id = id
        self.text = text
        self.kind = kind
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }

    public init(text: String,
                kind: Kind,
                oldLineNumber: Int? = nil,
                newLineNumber: Int? = nil) {
        self.init(id: DiffLine.stableID(
            text: text,
            kind: kind,
            oldLineNumber: oldLineNumber,
            newLineNumber: newLineNumber
        ),
        text: text,
        kind: kind,
        oldLineNumber: oldLineNumber,
        newLineNumber: newLineNumber)
    }

    private static func stableID(text: String,
                                 kind: Kind,
                                 oldLineNumber: Int?,
                                 newLineNumber: Int?) -> UUID {
        let material = "\(kind)|\(oldLineNumber.map(String.init) ?? "-")|\(newLineNumber.map(String.init) ?? "-")|\(text)"
        let digest = Array(SHA256.hash(data: Data(material.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

/// One `@@` hunk inside a file diff.
public struct DiffHunk: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let header: String
    public let oldRange: ClosedRange<Int>
    public let newRange: ClosedRange<Int>
    public let lines: [DiffLine]

    public init(id: UUID? = nil,
                header: String,
                oldRange: ClosedRange<Int>,
                newRange: ClosedRange<Int>,
                lines: [DiffLine]) {
        self.id = id ?? DiffHunk.stableID(header: header,
                                          oldRange: oldRange,
                                          newRange: newRange,
                                          lines: lines)
        self.header = header
        self.oldRange = oldRange
        self.newRange = newRange
        self.lines = lines
    }

    private static func stableID(header: String,
                                 oldRange: ClosedRange<Int>,
                                 newRange: ClosedRange<Int>,
                                 lines: [DiffLine]) -> UUID {
        var material = "\(header)|\(oldRange.lowerBound)-\(oldRange.upperBound)|\(newRange.lowerBound)-\(newRange.upperBound)"
        for line in lines {
            let prefix = switch line.kind {
            case .context: " "
            case .addition: "+"
            case .deletion: "-"
            }
            material += "\n\(prefix)\(line.text)"
        }
        let digest = Array(SHA256.hash(data: Data(material.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

/// All hunks for one file.
public struct FileDiff: Sendable, Hashable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let hunks: [DiffHunk]
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count } }

    public init(relativePath: String, hunks: [DiffHunk]) {
        self.relativePath = relativePath
        self.hunks = hunks
    }
}
