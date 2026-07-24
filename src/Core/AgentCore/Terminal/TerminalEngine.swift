@preconcurrency import SwiftTerm
import Foundation

/// Headless terminal engine.
///
/// Wraps a `SwiftTerm.Terminal` in an `actor` so the (mutable, non-Sendable)
/// VT state is reachable only from a single serial executor. Bytes go in via
/// `feed(_:)`, and structured snapshots come out via the
/// `TerminalSnapshotting` protocol.
///
/// Host replies (DSR, CPR, etc.) are exposed on `outboundReplies` for debug
/// viewers and future thin clients. `AgentEngine` deliberately does not write
/// them back to the PTY: the agent is our peer, not a real terminal host.
public actor TerminalEngine: TerminalSnapshotting {

    public nonisolated let outboundReplies: AsyncStream<Data>

    private let terminal: Terminal
    private let bridge: DelegateBridge

    public init(size: WindowSize = .default) {
        var continuation: AsyncStream<Data>.Continuation!
        self.outboundReplies = AsyncStream(bufferingPolicy: .bufferingOldest(StreamBufferDefaults.terminalReplies)) { c in
            continuation = c
        }
        let bridge = DelegateBridge(replyContinuation: continuation)
        var opts = TerminalOptions.default
        opts.cols = Int(size.cols)
        opts.rows = Int(size.rows)
        let term = Terminal(delegate: bridge, options: opts)
        self.terminal = term
        self.bridge = bridge
    }

    /// Feed raw PTY bytes into the emulator.
    public func feed(_ bytes: Data) {
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let buf = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self),
                                          count: raw.count)
            terminal.feed(buffer: ArraySlice(buf))
        }
    }

    /// Resize the virtual screen. The next read by the agent sees the new
    /// dimensions immediately.
    public func resize(to size: WindowSize) {
        terminal.resize(cols: Int(size.cols), rows: Int(size.rows))
    }

    // MARK: - TerminalSnapshotting

    public func snapshotRows() -> [String] {
        let data = terminal.getBufferAsData(kind: .active)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    public func snapshotText() -> String {
        let data = terminal.getBufferAsData(kind: .active)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// True if the terminal received a BEL (0x07) since the last call.
    public func consumeBell() -> Bool {
        let rang = bridge.bellRang
        bridge.bellRang = false
        return rang
    }
}

// MARK: - SwiftTerm delegate bridge

/// Minimal `TerminalDelegate`. SwiftTerm requires a class delegate; this is
/// the one place we relax `Sendable` because every access happens on the
/// owning actor's serial executor (proof: `TerminalEngine` is an `actor` and
/// holds the only reference).
private final class DelegateBridge: TerminalDelegate, @unchecked Sendable {

    var bellRang: Bool = false
    private let replyContinuation: AsyncStream<Data>.Continuation

    init(replyContinuation: AsyncStream<Data>.Continuation) {
        self.replyContinuation = replyContinuation
    }

    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
    func sizeChanged(source: Terminal) {}
    func send(source: Terminal, data: ArraySlice<UInt8>) {
        replyContinuation.yield(Data(data))
    }
    func scrolled(source: Terminal, yDisp: Int) {}
    func linefeed(source: Terminal) {}
    func bufferActivated(source: Terminal) {}
    func synchronizedOutputChanged(source: Terminal, active: Bool) {}
    func bell(source: Terminal) { bellRang = true }
    func selectionChanged(source: Terminal) {}
    func isProcessTrusted(source: Terminal) -> Bool { true }
    func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { nil }
    func mouseModeChanged(source: Terminal) {}
    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {}
    func hostCurrentDirectoryUpdated(source: Terminal) {}
    func hostCurrentDocumentUpdated(source: Terminal) {}
    func colorChanged(source: Terminal, idx: Int?) {}
    func setForegroundColor(source: Terminal, color: Color) {}
    func setBackgroundColor(source: Terminal, color: Color) {}
    func setCursorColor(source: Terminal, color: Color?) {}
    func getColors(source: Terminal) -> (foreground: Color, background: Color) {
        let white = Color(red: 35389, green: 35389, blue: 35389)
        let black = Color(red: 0, green: 0, blue: 0)
        return (foreground: white, background: black)
    }
    func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
    func clipboardCopy(source: Terminal, content: Data) {}
    func notify(source: Terminal, title: String, body: String) {}
}
