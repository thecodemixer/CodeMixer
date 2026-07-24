import Foundation

/// Conformed by a fake ACP twin's scripted-response server type. Shared by
/// `fake-acp` and `fake-custom-acp`'s `main.swift` (via `runACPTwinStdioLoop`)
/// so the two executables differ only in their per-scenario response bodies,
/// not in the newline-framed stdin/stdout plumbing around them.
public protocol ACPTwinServer {
    mutating func handle(_ incoming: ACPIncoming) -> [Data]
}

/// Runs a fake ACP twin's stdin → JSON-RPC dispatch loop until stdin closes:
/// decode one `ACPIncoming` frame per line (stripping a trailing `\r`), hand
/// it to `server.handle(_:)`, and write each reply frame to stdout. A decode
/// failure replies with a JSON-RPC parse-error frame instead of crashing the
/// process, matching what a real ACP agent would do for a malformed request.
public func runACPTwinStdioLoop(_ server: inout some ACPTwinServer) {
    setbuf(stdout, nil)
    while let line = readLine() {
        guard !line.isEmpty else { continue }
        var frame = Data(line.utf8)
        if frame.last == 0x0D { frame.removeLast() }
        do {
            let incoming = try ACPIncoming.decode(frame)
            for reply in server.handle(incoming) {
                writeACPTwinFrame(reply)
            }
        } catch {
            writeACPTwinFrame(ACPRPCCodec.errorResponse(
                id: .number(-1),
                code: -32_600,
                message: String(describing: error)
            ))
        }
    }
}

public func writeACPTwinFrame(_ data: Data) {
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        _ = write(STDOUT_FILENO, base, raw.count)
    }
}
