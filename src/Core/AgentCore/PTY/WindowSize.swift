import Foundation

/// Terminal dimensions in rows × columns.
///
/// We pin a default that matches Claude's preferred render width (160×48).
/// The headless terminal is sized to this; resizing on demand is supported
/// but rare — most agents target a fixed virtual terminal.
public struct WindowSize: Sendable, Hashable {
    public var rows: UInt16
    public var cols: UInt16

    public init(rows: UInt16, cols: UInt16) {
        self.rows = rows
        self.cols = cols
    }

    public static let `default` = WindowSize(rows: 48, cols: 160)
}
