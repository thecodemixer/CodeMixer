import Foundation
import OSLog
import AgentCore

/// Tail Claude's per-session JSONL transcript and emit assistant text blocks
/// as `AgentEvent` values.
///
/// Path layout: `~/.claude/projects/<slug>/<session-id>.jsonl`. `ClaudeProjectPaths`
/// owns the slug convention. The session id is discovered from the first
/// `SessionStart` hook; until then, we tail every recent file in the slug
/// directory and discard duplicates by record id.
public actor ClaudeTranscriptTailer {

    private struct TranscriptTool: Sendable {
        let name: String
        let inputJSON: String
    }

    private let claudeDirectory: URL
    private let workspace: URL
    private let fileSystem: any FileSystem
    private let clock: any AgentClock
    private let random: any RandomSource
    private var userTurnReplayActive: Bool
    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "ClaudeTranscriptTailer")
    private var sessionID: String?
    private var boundTranscriptURL: URL?
    private var seenRecordIDs: Set<String> = []
    private var transcriptTools: [String: TranscriptTool] = [:]
    private var fileOffsets: [String: Int] = [:]
    private var partialLines: [String: String] = [:]
    private var watchTask: Task<Void, Never>?
    private var continuation: AsyncStream<AgentEvent>.Continuation?
    private var assistantTextEmitted = false

    public init(claudeDirectory: URL,
                workspace: URL,
                initialSessionID: String? = nil,
                replayUserTurns: Bool = true,
                fileSystem: any FileSystem = SystemFileSystem(),
                clock: any AgentClock = SystemClock(),
                random: any RandomSource = SystemRandomSource()) {
        self.claudeDirectory = claudeDirectory
        self.workspace = workspace
        self.sessionID = initialSessionID
        self.userTurnReplayActive = replayUserTurns
        self.fileSystem = fileSystem
        self.clock = clock
        self.random = random
    }

    public func bind(sessionID: String) {
        if self.sessionID != sessionID {
            assistantTextEmitted = false
        }
        self.sessionID = sessionID
        log.debug("bound transcript session=\(sessionID, privacy: .public)")
    }

    /// Prefer the hook-supplied authoritative transcript path over slug recomputation.
    public func bind(transcriptURL: URL) {
        boundTranscriptURL = transcriptURL
        let sid = transcriptURL.deletingPathExtension().lastPathComponent
        if !sid.isEmpty {
            if sessionID != sid {
                assistantTextEmitted = false
            }
            sessionID = sid
        }
        log.debug("bound transcript url=\(transcriptURL.path, privacy: .public)")
    }

    /// True once this tailer has emitted any `assistantText` for the bound session.
    ///
    /// Used by `ClaudeAdapter` to drop redundant `last_assistant_message` payloads
    /// on Stop hooks when the JSONL transcript already surfaced the reply.
    public func hasEmittedAssistantText() -> Bool {
        assistantTextEmitted
    }

    public func start() -> AsyncStream<AgentEvent> {
        var continuation: AsyncStream<AgentEvent>.Continuation!
        let stream = AsyncStream<AgentEvent>(bufferingPolicy: .bufferingNewest(StreamBufferDefaults.transcriptEvents)) { c in
            continuation = c
        }
        self.continuation = continuation
        watchTask = Task { [weak self] in await self?.runLoop() }
        return stream
    }

    public func stop() {
        watchTask?.cancel()
        watchTask = nil
        continuation?.finish()
        continuation = nil
    }

    /// Synchronously ingest the currently-bound transcript once.
    ///
    /// The poll loop calls this periodically, and the adapter also calls it
    /// from Claude's Stop hook so the final assistant record is surfaced before
    /// the UI marks the turn idle.
    public func drain() async {
        if let url = currentTranscriptURL() {
            log.debug("draining transcript \(url.path, privacy: .public)")
            if await ingest(url: url) {
                userTurnReplayActive = false
            }
        } else {
            log.debug("no transcript available to drain")
        }
        for url in subagentTranscriptURLs() {
            _ = await ingest(url: url)
        }
    }

    // MARK: - Loop

    private func runLoop() async {
        // Poll at 100ms — fast enough to catch the first assistant record within
        // one poll cycle of the Stop hook, without meaningful CPU overhead.
        while !Task.isCancelled {
            try? await clock.sleep(for: .milliseconds(100))
            await drain()
        }
    }

    private func currentTranscriptURL() -> URL? {
        if let boundTranscriptURL { return boundTranscriptURL }
        guard let sid = sessionID else { return nil }
        for dir in projectDirectories() {
            let url = dir.appendingPathComponent("\(sid).jsonl")
            if fileSystem.fileExists(at: url) { return url }
        }
        return projectDirectories().first?.appendingPathComponent("\(sid).jsonl")
    }

    /// Enumerate subagent JSONL files at `<slug>/<sessionID>/subagents/*.jsonl`.
    ///
    /// Claude writes separate per-subagent transcripts into a `subagents/`
    /// subdirectory alongside the main session file. Each record there carries
    /// a `parentMessageId` that the `events(from:)` mapper uses to route output
    /// to the correct parent tool card.
    private func subagentTranscriptURLs() -> [URL] {
        guard let sid = sessionID else { return [] }
        return projectWorkspaces()
            .flatMap { workspace in
                let subagentsDir = ClaudeProjectPaths.subagentsDirectory(sessionID: sid,
                                                                         workspace: workspace,
                                                                         claudeDirectory: claudeDirectory)
                return (try? fileSystem.contentsOfDirectory(at: subagentsDir)) ?? []
            }
            .filter { $0.pathExtension == "jsonl" }
    }

    private func projectDirectories() -> [URL] {
        projectWorkspaces().map {
            ClaudeProjectPaths.projectDirectory(for: $0, claudeDirectory: claudeDirectory)
        }
    }

    private func projectWorkspaces() -> [URL] {
        ClaudeProjectPaths.workspaceVariants(for: workspace)
    }

    private func ingest(url: URL) async -> Bool {
        let key = url.path
        let previousOffset = fileOffsets[key] ?? 0
        guard let currentSize = try? fileSystem.byteCount(at: url) else { return false }
        let offset = currentSize < previousOffset ? 0 : previousOffset
        if offset == 0 { partialLines.removeValue(forKey: key) }
        guard let data = try? fileSystem.readData(at: url, fromOffset: offset),
              !data.isEmpty,
              let newText = String(data: data, encoding: .utf8) else {
            fileOffsets[key] = currentSize
            return false
        }
        fileOffsets[key] = currentSize

        let text = (partialLines[key] ?? "") + newText
        let endsWithNewline = text.hasSuffix("\n")
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var unterminatedLine: String?
        if !endsWithNewline, let tail = lines.popLast() {
            unterminatedLine = tail
        } else {
            partialLines.removeValue(forKey: key)
        }

        var emitted = false
        for line in lines {
            let result = ingestLine(line)
            emitted = result.emitted || emitted
        }
        if let unterminatedLine {
            let result = ingestLine(unterminatedLine)
            if result.parsed {
                partialLines.removeValue(forKey: key)
                emitted = result.emitted || emitted
            } else {
                partialLines[key] = unterminatedLine
            }
        }
        return emitted
    }

    private func ingestLine(_ line: String) -> (parsed: Bool, emitted: Bool) {
        guard let lineData = line.data(using: .utf8),
              let record = try? JSONDecoder().decode(Record.self, from: lineData) else {
            return (parsed: false, emitted: false)
        }
        let id = record.uuid ?? "\(record.type)-\(record.toolUseID ?? "")-\(line.hashValue)"
        guard !seenRecordIDs.contains(id) else { return (parsed: true, emitted: false) }
        seenRecordIDs.insert(id)
        if sessionID == nil, let recordSessionID = record.sessionId {
            sessionID = recordSessionID
            log.debug("bound transcript session from record=\(recordSessionID, privacy: .public)")
        }

        var emitted = false
        for event in events(from: record, recordID: id) {
            if case .assistantText = event {
                assistantTextEmitted = true
                log.debug("emitting assistantText record=\(id, privacy: .public)")
            }
            continuation?.yield(event)
            emitted = true
        }
        return (parsed: true, emitted: emitted)
    }

    private func events(from record: Record, recordID: String) -> [AgentEvent] {
        if record.type == "tool_result" {
            return toolResultEvents(id: record.toolUseID,
                                    content: resultText(text: record.text, blocks: record.content),
                                    isError: record.isError ?? false,
                                    durationMS: record.durationMS ?? 0)
        }

        guard let message = record.message else { return [] }
        if record.type == "user",
           let resultEvents = toolResultEvents(from: message),
           !resultEvents.isEmpty {
            return resultEvents
        }
        if userTurnReplayActive,
           record.type == "user",
           let text = userText(from: message),
           !text.isEmpty {
            return [.userTurn(id: recordID, text: text)]
        }
        guard record.type == "assistant",
              let blocks = message.content else { return [] }

        var out: [AgentEvent] = []
        let isSubagent = record.parentMessageId != nil

        for block in blocks {
            switch block {
            case .text(let text) where !text.isEmpty:
                if isSubagent, let parentID = record.parentMessageId,
                   let callID = UUID(uuidString: parentID) {
                    // Subagent turn: surface as tool progress keyed to the parent call.
                    out.append(.toolProgress(callID: callID, progress: .generic(message: text)))
                } else {
                    out.append(.assistantText(id: recordID,
                                              blockID: random.uuid().uuidString,
                                              text: text,
                                              isFinal: true))
                }
            case .thinking(let text) where !text.isEmpty:
                if isSubagent, let parentID = record.parentMessageId,
                   let callID = UUID(uuidString: parentID) {
                    out.append(.toolProgress(callID: callID,
                                             progress: .generic(message: "Thinking:\n\(text)")))
                } else {
                    let id = random.uuid()
                    out.append(.thinkingChunk(blockID: id, delta: text))
                    out.append(.thinkingComplete(blockID: id, duration: .milliseconds(0)))
                }
            case .toolUse(let id, let name, let json):
                let toolID = id ?? random.uuid().uuidString
                transcriptTools[toolID] = TranscriptTool(name: name, inputJSON: json)
                out.append(.toolStart(id: toolID,
                                      name: name,
                                      input: ToolInput(summary: toolSummary(name: name, inputJSON: json),
                                                       jsonPayload: json),
                                      startedAt: clock.now()))
            case .toolResult(let id, let content, let isError):
                out.append(contentsOf: toolResultEvents(id: id,
                                                        content: content,
                                                        isError: isError,
                                                        durationMS: 0))
            default:
                break
            }
        }
        if let usage = message.usage,
           let inputT = usage.input_tokens,
           let outputT = usage.output_tokens {
            out.append(.usage(tokens: inputT + outputT, costUSD: usage.cost_usd))
        }
        return out
    }

    private func toolResultEvents(from message: Message) -> [AgentEvent]? {
        guard let blocks = message.content else { return nil }
        return blocks.flatMap { block in
            if case .toolResult(let id, let content, let isError) = block {
                return toolResultEvents(id: id, content: content, isError: isError, durationMS: 0)
            }
            return []
        }
    }

    private func toolResultEvents(id: String?,
                                  content: String,
                                  isError: Bool,
                                  durationMS: Int) -> [AgentEvent] {
        guard let id else { return [] }
        let tool = transcriptTools[id]
        var events: [AgentEvent] = []
        if let fileTouched = fileTouchedEvent(tool: tool) {
            events.append(fileTouched)
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = trimmed.isEmpty ? "Tool completed" : trimmed
        events.append(.toolEnd(id: id,
                               success: !isError,
                               output: ToolOutput(summary: summary,
                                                  errorMessage: isError ? summary : nil),
                               durationMS: durationMS))
        return events
    }

    private func userText(from message: Message) -> String? {
        if let text = message.text { return text }
        return message.content?.compactMap { block in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n")
    }

    private func resultText(text: String?, blocks: [ContentBlock]?) -> String {
        if let text { return text }
        return blocks?.compactMap { block in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n") ?? ""
    }

    private func toolSummary(name: String, inputJSON: String) -> String {
        ClaudeHookDecoder(clock: clock, random: random)
            .humanSummary(tool: name, args: toolInput(from: inputJSON))
    }

    private func toolInput(from json: String) -> [String: AnyCodableValue]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: AnyCodableValue].self, from: data)
    }

    private func fileTouchedEvent(tool: TranscriptTool?) -> AgentEvent? {
        guard let tool,
              ["Edit", "Write", "MultiEdit"].contains(tool.name),
              case .string(let path) = toolInput(from: tool.inputJSON)?["file_path"] else { return nil }
        return .fileTouched(URL(fileURLWithPath: path), kind: .hookReported)
    }

}
