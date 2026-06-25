import Testing
import Foundation
@testable import ClaudeCode
import AgentCore
import AgentProtocol


@Suite("ClaudeTranscriptTailer fixtures")
struct TranscriptTailerTests {

    /// Synthetic JSONL mirroring what `~/.claude/projects/<slug>/<sid>.jsonl`
    /// looks like for a small session.
    private static let fixtureJSONL = """
    {"type":"assistant","uuid":"rec-1","sessionId":"sid-1","message":{"role":"assistant","content":[{"type":"text","text":"Hello, world."}]}}
    {"type":"assistant","uuid":"rec-2","sessionId":"sid-1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Let me decide."},{"type":"text","text":"Done."}],"usage":{"input_tokens":12,"output_tokens":4,"cost_usd":0.001}}}
    {"type":"assistant","uuid":"rec-3","sessionId":"sid-1","message":{"role":"assistant","content":[{"type":"tool_use","id":"t-1","name":"Bash","input":{"command":"ls"}}]}}
    {"type":"tool_result","uuid":"rec-4","sessionId":"sid-1","tool_use_id":"t-1","content":[{"type":"text","text":"file.txt"}],"is_error":false}
    """

    @Test func tailerEmitsExpectedEventShape() async throws {
        // Write the fixture into a temporary projects directory that mirrors
        // Claude's real layout, then point the tailer at it.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-tailer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let workspace = URL(fileURLWithPath: "/var/folders/codemixer-test")
        let projects = ClaudeProjectPaths.projectDirectory(for: workspace,
                                                           claudeDirectory: tmp)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Self.fixtureJSONL.write(to: projects.appendingPathComponent("sid-1.jsonl"),
                                    atomically: true, encoding: .utf8)

        let tailer = ClaudeTranscriptTailer(claudeDirectory: tmp, workspace: workspace)
        await tailer.bind(sessionID: "sid-1")
        let stream = await tailer.start()
        let collector = EventCollector()
        let collectTask = Task { await collector.collect(from: stream) }

        await tailer.drain()
        await tailer.stop()
        collectTask.cancel()
        let collected = await collector.events

        #expect(collected.contains {
            if case .assistantText(_, _, let text, true) = $0, text.contains("Hello") { return true }
            return false
        })
        #expect(collected.contains {
            if case .thinkingChunk(_, let text) = $0, text == "Let me decide." { return true }
            return false
        })
        #expect(collected.contains {
            if case .toolStart(_, "Bash", _, _) = $0 { return true }
            return false
        })
        #expect(collected.contains {
            if case .toolEnd("t-1", true, let output, _) = $0 { return output.summary == "file.txt" }
            return false
        })
        #expect(collected.contains {
            if case .usage(let tokens, _) = $0, tokens == 16 { return true }
            return false
        })
    }

    // MARK: - Dedup

    @Test("Records with the same uuid are not emitted twice on re-read")
    func deduplication() async throws {
        let (tmp, tailer, projects) = try makeTailer()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let line = #"{"type":"assistant","uuid":"dup-1","sessionId":"sid-1","message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}"#
        let url = projects.appendingPathComponent("sid-1.jsonl")
        try line.write(to: url, atomically: true, encoding: .utf8)

        await tailer.bind(sessionID: "sid-1")
        let stream = await tailer.start()
        let collector = EventCollector()
        let task = Task { await collector.collect(from: stream) }
        await tailer.drain()
        let appended = line + "\n" + line
        try appended.write(to: url, atomically: true, encoding: .utf8)
        await tailer.drain()
        await tailer.stop()
        task.cancel()

        let collected = await collector.events
        let assistantTexts = collected.filter {
            if case .assistantText(_, _, let text, _) = $0, text == "hi" { return true }; return false
        }
        #expect(assistantTexts.count == 1, "expected exactly 1 emit, got \(assistantTexts.count)")
    }

    @Test("A new uuid appended later is emitted without re-emitting the old record")
    func deduplicationNewRecord() async throws {
        let (tmp, tailer, projects) = try makeTailer()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let line1 = #"{"type":"assistant","uuid":"dedup-a","sessionId":"s","message":{"role":"assistant","content":[{"type":"text","text":"first"}]}}"#
        let line2 = #"{"type":"assistant","uuid":"dedup-b","sessionId":"s","message":{"role":"assistant","content":[{"type":"text","text":"second"}]}}"#
        let url = projects.appendingPathComponent("s.jsonl")
        try line1.write(to: url, atomically: true, encoding: .utf8)

        await tailer.bind(sessionID: "s")
        let stream = await tailer.start()
        let collector = EventCollector()
        let collectTask = Task { await collector.collect(from: stream) }
        await tailer.drain()
        try (line1 + "\n" + line2).write(to: url, atomically: true, encoding: .utf8)
        await tailer.drain()
        await tailer.stop()
        collectTask.cancel()

        let collected = await collector.events
        let texts = collected.compactMap { e -> String? in
            if case .assistantText(_, _, let t, _) = e { return t }; return nil
        }
        #expect(texts.contains("first"))
        #expect(texts.contains("second"))
        #expect(texts.filter { $0 == "first" }.count == 1)
    }

    @Test("Explicit drain emits the final assistant record without waiting for poll")
    func explicitDrainEmitsFinalAssistantRecord() async throws {
        let (tmp, tailer, projects) = try makeTailer()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let line = """
        {"parentUuid":"user-1","isSidechain":false,"message":{"model":"claude-sonnet-4-6","id":"msg-1","type":"message","role":"assistant","content":[{"type":"text","text":"Hi! How can I help you today?"}],"stop_reason":"end_turn"},"type":"assistant","uuid":"asst-1","sessionId":"s"}
        """
        try line.write(to: projects.appendingPathComponent("s.jsonl"),
                       atomically: true,
                       encoding: .utf8)

        await tailer.bind(sessionID: "s")
        let stream = await tailer.start()
        var iterator = stream.makeAsyncIterator()

        await tailer.drain()
        let event = await iterator.next()
        guard case .assistantText(_, _, let text, true)? = event else {
            Issue.record("expected assistantText, got \(String(describing: event))")
            await tailer.stop()
            return
        }

        #expect(text == "Hi! How can I help you today?")
        await tailer.stop()
    }

    @Test("Replay emits user records with string content")
    func replayEmitsUserRecords() async throws {
        let (tmp, tailer, projects) = try makeTailer()
        defer { try? FileManager.default.removeItem(at: tmp) }

        try #"{"type":"user","uuid":"user-1","sessionId":"s","message":{"role":"user","content":"hi"}}"#
            .write(to: projects.appendingPathComponent("s.jsonl"),
                   atomically: true,
                   encoding: .utf8)

        await tailer.bind(sessionID: "s")
        let stream = await tailer.start()
        var iterator = stream.makeAsyncIterator()

        await tailer.drain()
        let event = await iterator.next()
        guard case .userTurn("user-1", "hi")? = event else {
            Issue.record("expected userTurn, got \(String(describing: event))")
            await tailer.stop()
            return
        }
        await tailer.stop()
    }

    @Test("Live tailing suppresses user records")
    func liveTailingSuppressesUserRecords() async throws {
        let (tmp, tailer, projects) = try makeTailer(replayUserTurns: false)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let line = """
        {"type":"user","uuid":"user-1","sessionId":"s","message":{"role":"user","content":"hi"}}
        {"type":"assistant","uuid":"asst-1","sessionId":"s","message":{"role":"assistant","content":[{"type":"text","text":"hello"}]}}
        """
        try line.write(to: projects.appendingPathComponent("s.jsonl"),
                       atomically: true,
                       encoding: .utf8)

        await tailer.bind(sessionID: "s")
        let stream = await tailer.start()
        let collector = EventCollector()
        let task = Task { await collector.collect(from: stream) }

        await tailer.drain()
        await tailer.stop()
        task.cancel()

        let collected = await collector.events
        #expect(!collected.contains {
            if case .userTurn = $0 { return true }
            return false
        })
        #expect(collected.contains {
            if case .assistantText(_, _, "hello", true) = $0 { return true }
            return false
        })
    }

    @Test("Resumed sessions suppress user records after initial replay")
    func resumedSessionSuppressesNewUserRecordsAfterReplay() async throws {
        let (tmp, tailer, projects) = try makeTailer()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = projects.appendingPathComponent("s.jsonl")
        let initial = #"{"type":"user","uuid":"old-user","sessionId":"s","message":{"role":"user","content":"old"}}"#
        try initial.write(to: url, atomically: true, encoding: .utf8)

        await tailer.bind(sessionID: "s")
        let stream = await tailer.start()
        let collector = EventCollector()
        let task = Task { await collector.collect(from: stream) }

        await tailer.drain()
        let appended = initial + "\n" +
            #"{"type":"user","uuid":"new-user","sessionId":"s","message":{"role":"user","content":"new"}}"# + "\n" +
            #"{"type":"assistant","uuid":"new-asst","sessionId":"s","message":{"role":"assistant","content":[{"type":"text","text":"reply"}]}}"#
        try appended.write(to: url, atomically: true, encoding: .utf8)
        await tailer.drain()
        await tailer.stop()
        task.cancel()

        let collected = await collector.events
        let userTexts = collected.compactMap { event -> String? in
            if case .userTurn(_, let text) = event { return text }
            return nil
        }
        #expect(userTexts == ["old"])
    }

    @Test("Initial session id loads the requested transcript")
    func initialSessionIDLoadsRequestedTranscript() async throws {
        let workspace = URL(fileURLWithPath: "/var/test-workspace")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-tt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let projects = ClaudeProjectPaths.projectDirectory(for: workspace,
                                                           claudeDirectory: tmp)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try #"{"type":"assistant","uuid":"wanted","sessionId":"wanted","message":{"role":"assistant","content":[{"type":"text","text":"requested"}]}}"#
            .write(to: projects.appendingPathComponent("wanted.jsonl"),
                   atomically: true,
                   encoding: .utf8)
        try #"{"type":"assistant","uuid":"other","sessionId":"other","message":{"role":"assistant","content":[{"type":"text","text":"unrelated"}]}}"#
            .write(to: projects.appendingPathComponent("other.jsonl"),
                   atomically: true,
                   encoding: .utf8)

        let tailer = ClaudeTranscriptTailer(claudeDirectory: tmp,
                                            workspace: workspace,
                                            initialSessionID: "wanted")
        let stream = await tailer.start()
        var iterator = stream.makeAsyncIterator()

        await tailer.drain()
        let event = await iterator.next()
        guard case .assistantText(_, _, "requested", true)? = event else {
            Issue.record("expected requested transcript, got \(String(describing: event))")
            await tailer.stop()
            return
        }
        await tailer.stop()
    }

    @Test("Replay emits completed tool calls")
    func replayEmitsCompletedToolCalls() async throws {
        let (tmp, tailer, projects) = try makeTailer()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let line = """
        {"type":"assistant","uuid":"tool-start","sessionId":"s","message":{"role":"assistant","content":[{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"pwd"}}]}}
        {"type":"tool_result","uuid":"tool-end","sessionId":"s","tool_use_id":"tool-1","content":[{"type":"text","text":"/tmp/ws"}],"is_error":false}
        """
        try line.write(to: projects.appendingPathComponent("s.jsonl"),
                       atomically: true,
                       encoding: .utf8)

        await tailer.bind(sessionID: "s")
        let stream = await tailer.start()
        let collector = EventCollector()
        let task = Task { await collector.collect(from: stream) }

        await tailer.drain()
        await tailer.stop()
        task.cancel()

        let collected = await collector.events
        #expect(collected.contains {
            if case .toolStart("tool-1", "Bash", let input, _) = $0 {
                return input.summary == "Run: pwd"
            }
            return false
        })
        #expect(collected.contains {
            if case .toolEnd("tool-1", true, let output, _) = $0 {
                return output.summary == "/tmp/ws"
            }
            return false
        })
    }

    @Test("Replay emits nested user tool results")
    func replayEmitsNestedUserToolResults() async throws {
        let (tmp, tailer, projects) = try makeTailer()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let line = """
        {"type":"assistant","uuid":"nested-start","sessionId":"s","message":{"role":"assistant","content":[{"type":"tool_use","id":"nested-1","name":"Read","input":{"file_path":"README.md"}}]}}
        {"type":"user","uuid":"nested-end","sessionId":"s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"nested-1","content":"contents","is_error":false}]}}
        """
        try line.write(to: projects.appendingPathComponent("s.jsonl"),
                       atomically: true,
                       encoding: .utf8)

        await tailer.bind(sessionID: "s")
        let stream = await tailer.start()
        let collector = EventCollector()
        let task = Task { await collector.collect(from: stream) }

        await tailer.drain()
        await tailer.stop()
        task.cancel()

        let collected = await collector.events
        #expect(collected.contains {
            if case .toolStart("nested-1", "Read", let input, _) = $0 {
                return input.summary == "Read README.md"
            }
            return false
        })
        #expect(collected.contains {
            if case .toolEnd("nested-1", true, let output, _) = $0 {
                return output.summary == "contents"
            }
            return false
        })
        #expect(!collected.contains {
            if case .userTurn(_, "contents") = $0 { return true }
            return false
        })
    }

    @Test("Replay emits file touches for completed edit tools")
    func replayEmitsEditFileTouches() async throws {
        let (tmp, tailer, projects) = try makeTailer()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appendingPathComponent("edited.txt").path
        let line = """
        {"type":"assistant","uuid":"edit-start","sessionId":"s","message":{"role":"assistant","content":[{"type":"tool_use","id":"edit-1","name":"Edit","input":{"file_path":"\(file)","old_string":"a","new_string":"b"}}]}}
        {"type":"tool_result","uuid":"edit-end","sessionId":"s","tool_use_id":"edit-1","content":"updated","is_error":false}
        """
        try line.write(to: projects.appendingPathComponent("s.jsonl"),
                       atomically: true,
                       encoding: .utf8)

        await tailer.bind(sessionID: "s")
        let stream = await tailer.start()
        let collector = EventCollector()
        let task = Task { await collector.collect(from: stream) }

        await tailer.drain()
        await tailer.stop()
        task.cancel()

        let collected = await collector.events
        #expect(collected.contains {
            if case .fileTouched(let url, .hookReported) = $0 { return url.path == file }
            return false
        })
        #expect(collected.contains {
            if case .toolEnd("edit-1", true, _, _) = $0 { return true }
            return false
        })
    }

    @Test("Tailer finds transcripts under a symlink-resolved workspace slug")
    func resolvedWorkspaceSlugFallback() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-tt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let realWorkspace = tmp.appendingPathComponent("real-workspace", isDirectory: true)
        let linkedWorkspace = tmp.appendingPathComponent("linked-workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: realWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedWorkspace,
                                                   withDestinationURL: realWorkspace)

        let projects = ClaudeProjectPaths.projectDirectory(for: realWorkspace,
                                                           claudeDirectory: tmp)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try #"{"type":"assistant","uuid":"resolved-1","sessionId":"s","message":{"role":"assistant","content":[{"type":"text","text":"resolved"}]}}"#
            .write(to: projects.appendingPathComponent("s.jsonl"),
                   atomically: true,
                   encoding: .utf8)

        let tailer = ClaudeTranscriptTailer(claudeDirectory: tmp, workspace: linkedWorkspace)
        await tailer.bind(sessionID: "s")
        let stream = await tailer.start()
        var iterator = stream.makeAsyncIterator()

        await tailer.drain()
        let event = await iterator.next()
        guard case .assistantText(_, _, "resolved", true)? = event else {
            Issue.record("expected assistantText from resolved slug, got \(String(describing: event))")
            await tailer.stop()
            return
        }
        await tailer.stop()
    }

    // MARK: - Subagent

    @Test("Subagent record (parentMessageId set) surfaces as toolProgress not assistantText")
    func subagentAsToolProgress() async throws {
        let parentID = UUID().uuidString
        let line = """
        {"type":"assistant","uuid":"sub-1","sessionId":"s","parentMessageId":"\(parentID)","message":{"role":"assistant","content":[{"type":"text","text":"subagent output"}]}}
        """
        let (tmp, tailer, projects) = try makeTailer()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try line.write(to: projects.appendingPathComponent("s.jsonl"),
                       atomically: true, encoding: .utf8)

        await tailer.bind(sessionID: "s")
        let stream = await tailer.start()
        let collector = EventCollector()
        let task = Task { await collector.collect(from: stream) }
        await tailer.drain()
        await tailer.stop()
        task.cancel()

        let collected = await collector.events
        #expect(collected.contains {
            if case .toolProgress(_, .generic(let msg)) = $0, msg.contains("subagent") { return true }
            return false
        })
        #expect(!collected.contains {
            if case .assistantText = $0 { return true }; return false
        })
    }

    @Test("Fresh chat does not replay an on-disk transcript before session bind")
    func freshChatWaitsForSessionBind() async throws {
        let (tmp, tailer, projects) = try makeTailer(replayUserTurns: false)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try #"{"type":"assistant","uuid":"old-1","sessionId":"old-session","message":{"role":"assistant","content":[{"type":"text","text":"stale"}]}}"#
            .write(to: projects.appendingPathComponent("old-session.jsonl"),
                   atomically: true,
                   encoding: .utf8)

        let stream = await tailer.start()
        let collector = EventCollector()
        let task = Task { await collector.collect(from: stream) }

        await tailer.drain()
        await tailer.stop()
        task.cancel()

        let collected = await collector.events
        #expect(collected.isEmpty)
    }

    @Test("Incremental reads only parse newly appended transcript bytes")
    func incrementalReadAppendsOnlyNewBytes() async throws {
        let (tmp, tailer, projects) = try makeTailer()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = projects.appendingPathComponent("s.jsonl")
        let first = #"{"type":"assistant","uuid":"inc-1","sessionId":"s","message":{"role":"assistant","content":[{"type":"text","text":"first"}]}}"#
        try first.write(to: url, atomically: true, encoding: .utf8)

        await tailer.bind(sessionID: "s")
        let stream = await tailer.start()
        let collector = EventCollector()
        let task = Task { await collector.collect(from: stream) }

        await tailer.drain()
        try (first + "\n" +
            #"{"type":"assistant","uuid":"inc-2","sessionId":"s","message":{"role":"assistant","content":[{"type":"text","text":"second"}]}}"#)
            .write(to: url, atomically: true, encoding: .utf8)
        await tailer.drain()
        await tailer.stop()
        task.cancel()

        let texts = await collector.events.compactMap { event -> String? in
            if case .assistantText(_, _, let text, _) = event { return text }
            return nil
        }
        #expect(texts == ["first", "second"])
    }

    @Test("Incremental reads preserve split JSON records until the next append")
    func incrementalReadBuffersSplitJSONRecord() async throws {
        let (tmp, tailer, projects) = try makeTailer()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = projects.appendingPathComponent("s.jsonl")
        let record = #"{"type":"assistant","uuid":"split-1","sessionId":"s","message":{"role":"assistant","content":[{"type":"text","text":"split reply"}]}}"#
        let midpoint = record.index(record.startIndex, offsetBy: record.count / 2)
        try String(record[..<midpoint]).write(to: url, atomically: true, encoding: .utf8)

        await tailer.bind(sessionID: "s")
        let stream = await tailer.start()
        let collector = EventCollector()
        let task = Task { await collector.collect(from: stream) }

        await tailer.drain()
        var texts = await collector.events.compactMap { event -> String? in
            if case .assistantText(_, _, let text, _) = event { return text }
            return nil
        }
        #expect(texts.isEmpty)

        try record.write(to: url, atomically: true, encoding: .utf8)
        await tailer.drain()
        await tailer.stop()
        task.cancel()

        texts = await collector.events.compactMap { event -> String? in
            if case .assistantText(_, _, let text, _) = event { return text }
            return nil
        }
        #expect(texts == ["split reply"])
    }

    @Test("Incremental read consumes complete non-emitting records")
    func incrementalReadConsumesCompleteNonEmittingRecord() async throws {
        let (tmp, tailer, projects) = try makeTailer()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let url = projects.appendingPathComponent("s.jsonl")
        let emptyThinking = #"{"type":"assistant","uuid":"think-empty","sessionId":"s","message":{"role":"assistant","content":[{"type":"thinking","thinking":""}]}}"#
        let reply = #"{"type":"assistant","uuid":"reply-after-empty","sessionId":"s","message":{"role":"assistant","content":[{"type":"text","text":"visible reply"}]}}"#
        try emptyThinking.write(to: url, atomically: true, encoding: .utf8)

        await tailer.bind(sessionID: "s")
        let stream = await tailer.start()
        let collector = EventCollector()
        let task = Task { await collector.collect(from: stream) }

        await tailer.drain()
        try (emptyThinking + "\n" + reply).write(to: url, atomically: true, encoding: .utf8)
        await tailer.drain()
        await tailer.stop()
        task.cancel()

        let texts = await collector.events.compactMap { event -> String? in
            if case .assistantText(_, _, let text, _) = event { return text }
            return nil
        }
        #expect(texts == ["visible reply"])
    }

    // MARK: - Helpers

    /// Returns (claudeDir, tailer, projectsSlugDir) pre-created under NSTemporaryDirectory.
    private func makeTailer(workspace: URL = URL(fileURLWithPath: "/var/test-workspace"),
                            replayUserTurns: Bool = true)
        throws -> (URL, ClaudeTranscriptTailer, URL)
    {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-tt-\(UUID().uuidString)", isDirectory: true)
        let projects = ClaudeProjectPaths.projectDirectory(for: workspace,
                                                           claudeDirectory: tmp)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let tailer = ClaudeTranscriptTailer(claudeDirectory: tmp,
                                            workspace: workspace,
                                            replayUserTurns: replayUserTurns)
        return (tmp, tailer, projects)
    }
}

/// Actor-isolated event collector — avoids mutating a `var` from inside a Task closure,
/// which the Swift 6 concurrency checker rejects as a potential data race.
private actor EventCollector {
    private(set) var events: [AgentEvent] = []

    func collect(from stream: AsyncStream<AgentEvent>) async {
        for await event in stream { events.append(event) }
    }
}
