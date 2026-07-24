import Foundation
import Testing
@testable import AgentCore

@Suite("TerminalEngine — headless screen scraping")
struct TerminalEngineTests {

    @Test("Feeding plain text appears in the snapshot")
    func snapshotContainsFedText() async {
        let engine = TerminalEngine(size: WindowSize(rows: 24, cols: 80))
        await engine.feed(Data("Hello, Claude!\n".utf8))
        let text = await engine.snapshotText()
        #expect(text.contains("Hello, Claude!"))
    }

    @Test("BEL sets the bell flag once, then consumes it")
    func bellIsLatched() async {
        let engine = TerminalEngine(size: WindowSize(rows: 4, cols: 16))
        await engine.feed(Data([0x07]))
        #expect(await engine.consumeBell() == true)
        #expect(await engine.consumeBell() == false)
    }

    @Test("resize(to:) accepts a smaller window without corrupting snapshots")
    func resizeDoesNotCrash() async {
        let engine = TerminalEngine(size: WindowSize(rows: 24, cols: 80))
        // Resize to a narrower terminal — must not crash.
        await engine.resize(to: WindowSize(rows: 10, cols: 40))
        await engine.feed(Data("ok".utf8))
        let rows = await engine.snapshotRows()
        #expect(rows.first?.contains("ok") == true)
    }

    @Test("ANSI CUP escape writes text at the specified row")
    func ansiCursorMove() async {
        let engine = TerminalEngine(size: WindowSize(rows: 24, cols: 80))
        // ESC [ 5 ; 1 H  — move cursor to row 5, col 1 (1-indexed VT100).
        let cup = Data("\u{1B}[5;1H".utf8)
        await engine.feed(cup)
        await engine.feed(Data("X".utf8))
        let rows = await engine.snapshotRows()
        // SwiftTerm rows are 0-indexed; row 5 → index 4.
        #expect(rows.indices.contains(4))
        #expect(rows[4].hasPrefix("X"))
    }

    @Test("DSR request is exposed on outboundReplies")
    func outboundReplyStream() async throws {
        let engine = TerminalEngine(size: WindowSize(rows: 24, cols: 80))
        let replies = engine.outboundReplies
        let waiter = Task {
            for await reply in replies {
                return reply
            }
            return Data()
        }

        await engine.feed(Data("\u{1B}[6n".utf8))
        let reply = await waiter.value
        let text = String(data: reply, encoding: .utf8) ?? ""
        #expect(text.hasPrefix("\u{1B}["))
        #expect(text.hasSuffix("R"))
    }
}
