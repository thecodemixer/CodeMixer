import Foundation
import Testing
@testable import AgentCore
import AgentProtocol
import AgentTestSupport

/// One test per `AgentCommand` case (plus the permission auto-deny timeout).
/// We use `RecordingMockAdapter` to capture adapter-level effects without
/// spawning a real CLI binary. The adapter declares `/bin/cat` as the agent
/// so the PTY child stays alive while the engine writes bytes to it.
@Suite("AgentEngine — command matrix", .serialized)
struct AgentEngineCommandTests {

    // MARK: Conversation

    @Test("start strips billing-poison env before PTY spawn")
    func startStripsBillingPoisonEnv() async throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-billing-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let env = FakeEnvironment(
            processEnv: [
                "SHELL": "/codemixer-test/missing-shell",
                "PATH": "/usr/bin:/bin",
                "CLAUDE_CODE_ENTRYPOINT": "sdk",
                "ANTHROPIC_API_KEY": "sk-test",
            ],
            home: workspace
        )
        let capture = CapturingPTYFactory()
        let h = try await EngineHarness.make(workspace: workspace,
                                             environment: env,
                                             ptyFactory: capture.makePTY(_:))
        guard let spec = capture.lastSpec else {
            Issue.record("expected PTY spawn spec")
            await h.shutdown()
            return
        }
        #expect(spec.environment["CLAUDE_CODE_ENTRYPOINT"] == nil)
        #expect(spec.environment["ANTHROPIC_API_KEY"] == nil)
        #expect(spec.environment["PATH"] == "/usr/bin:/bin")
        await h.shutdown()
    }

    @Test("sendPrompt encodes via adapter and publishes userTurn")
    func sendPrompt() async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(.sendPrompt(text: "hello", attachments: []))
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.adapter.recorded.contains(.userPrompt("hello")))
        let userEvents = await h.collectedSoFar().filter {
            if case .userTurn = $0 { return true }; return false
        }
        #expect(userEvents.count >= 1)
        await h.shutdown()
    }

    @Test("sendPrompt fans the userTurn out to every subscriber (GUI + remote parity)")
    func sendPromptFansOutToAllSubscribers() async throws {
        let h = try await EngineHarness.make()
        // A second independent bus subscriber stands in for a remote
        // ClientConnection. The engine publishes `.userTurn` before the awaited
        // PTY write, so both the GUI collector and this one must see the same
        // turn — proving the reorder is transport-agnostic and reaches every
        // surface uniformly (no GUI-only fast path).
        let remoteSub = await h.engine.bus.subscribe()
        let remoteCollector = EventCollector()
        let remoteTask = Task { await remoteCollector.ingest(remoteSub.stream) }

        try await h.engine.send(.sendPrompt(text: "parity", attachments: []))
        try await Task.sleep(for: .milliseconds(40))

        func sawUserTurn(_ events: [AgentEvent]) -> Bool {
            events.contains {
                if case .userTurn(_, let text) = $0 { return text == "parity" }
                return false
            }
        }
        #expect(sawUserTurn(await h.collectedSoFar()))
        #expect(sawUserTurn(await remoteCollector.snapshot()))

        await h.engine.bus.unsubscribe(remoteSub.id)
        remoteTask.cancel()
        await h.shutdown()
    }

    @Test("sendPrompt publishes userTurn before a PTY write failure is thrown")
    func sendPromptPublishesBeforeWriteFailure() async throws {
        let pty = ScriptedPTY(writeSteps: [.fail(.writeFailed(errno: 5))])
        let h = try await EngineHarness.make(pty: pty)
        let bus = h.engine.bus
        await pty.setWriteProbe { _ in
            await bus.historySnapshot.contains {
                if case .userTurn(_, let text) = $0.event { return text == "will fail" }
                return false
            }
        }

        do {
            try await h.engine.send(.sendPrompt(text: "will fail", attachments: []))
            Issue.record("expected PTY write failure")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: 5))
        } catch {
            Issue.record("expected PTYError.writeFailed, got \(error)")
        }

        #expect(await pty.writeProbeResults() == [true])
        #expect(await pty.writtenTexts() == ["will fail"])
        let history = await h.engine.bus.historySnapshot
        #expect(history.contains {
            if case .userTurn(_, let text) = $0.event { return text == "will fail" }
            return false
        })
        await h.shutdown()
    }

    @Test("sendPrompt write failure still fans userTurn out to remote-like subscribers")
    func sendPromptWriteFailureFansOutToRemoteSubscriber() async throws {
        let pty = ScriptedPTY(writeSteps: [.fail(.writeFailed(errno: 5))])
        let h = try await EngineHarness.make(pty: pty)
        let remoteSub = await h.engine.bus.subscribe()
        let remoteCollector = EventCollector()
        let remoteTask = Task { await remoteCollector.ingest(remoteSub.stream) }

        do {
            try await h.engine.send(.sendPrompt(text: "remote fail", attachments: []))
            Issue.record("expected PTY write failure")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: 5))
        } catch {
            Issue.record("expected PTYError.writeFailed, got \(error)")
        }

        try await Task.sleep(for: .milliseconds(40))
        let remoteEvents = await remoteCollector.snapshot()
        #expect(remoteEvents.contains {
            if case .userTurn(_, let text) = $0 { return text == "remote fail" }
            return false
        })

        await h.engine.bus.unsubscribe(remoteSub.id)
        remoteTask.cancel()
        await h.shutdown()
    }

    @Test("sendPrompt appends resolved attachment refs as local @ paths")
    func sendPromptWithAttachments() async throws {
        let h = try await EngineHarness.make()
        let ref = AttachmentRef(id: "upload-1",
                                filename: "spec.md",
                                byteCount: 4,
                                mimeType: "text/markdown")
        let uploaded = AppSupportPaths.attachmentsDirectory(in: h.environment.appSupportDirectory)
            .appendingPathComponent("upload-1-spec.md")
        try h.fileSystem.writeAtomically(Data("body".utf8), to: uploaded)

        try await h.engine.send(.sendPrompt(text: "review this", attachments: [ref]))
        try await Task.sleep(for: .milliseconds(20))

        let prompts = h.adapter.recorded.compactMap { entry -> String? in
            if case .userPrompt(let s) = entry { return s }; return nil
        }
        #expect(prompts.contains { $0 == "review this\n@\(uploaded.path)" })
        await h.shutdown()
    }

    @Test("sendPrompt writes encoded prompt bytes to the PTY")
    func sendPromptWritesPromptBytesToPTY() async throws {
        try await assertPTYWrite(.init("sendPrompt",
                                       .sendPrompt(text: "hello pty", attachments: []),
                                       "hello pty"))
    }

    @Test("cancelCurrentTurn calls adapter.cancelSequence")
    func cancelCurrentTurn() async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(.sendPrompt(text: "first", attachments: []))
        try await h.engine.send(.cancelCurrentTurn)
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.adapter.recorded.contains(.cancel))
        await h.shutdown()
    }

    @Test("cancelCurrentTurn writes Ctrl-C bytes then interrupts the PTY")
    func cancelCurrentTurnWritesAndInterruptsPTY() async throws {
        try await assertPTYWrite(.init("cancelCurrentTurn",
                                       .cancelCurrentTurn,
                                       bytes: Data([0x03])),
                                 interrupts: true)
    }

    @Test("cancelCurrentTurn write failure propagates and skips interrupt")
    func cancelCurrentTurnWriteFailureSkipsInterrupt() async throws {
        try await assertPTYWriteFailure(.init("cancelCurrentTurn",
                                              .cancelCurrentTurn,
                                              bytes: Data([0x03])))
    }

    @Test("editAndResubmitLast rewrites the last user bubble")
    func editAndResubmit() async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(.sendPrompt(text: "first", attachments: []))
        try await Task.sleep(for: .milliseconds(10))
        // Recover the bubble id from the published userTurn event.
        let events = await h.collectedSoFar()
        guard case .userTurn(let idString, _)? = events.first(where: {
            if case .userTurn = $0 { return true }; return false
        }) else {
            Issue.record("no userTurn event captured"); return
        }
        let targetID = UUID(uuidString: idString)!
        try await h.engine.send(.editAndResubmitLast(targetBubbleID: targetID,
                                                    text: "edited",
                                                    attachments: []))
        try await Task.sleep(for: .milliseconds(80))
        #expect(h.adapter.recorded.contains(.cancel))
        #expect(h.adapter.recorded.contains(.userPrompt("edited")))
        await h.shutdown()
    }

    @Test("editAndResubmitLast propagates cancel write failure before restart")
    func editAndResubmitCancelWriteFailurePropagates() async throws {
        let pty = ScriptedPTY(writeSteps: [.succeed, .fail(.writeFailed(errno: 5))])
        let h = try await EngineHarness.make(pty: pty)
        try await h.engine.send(.sendPrompt(text: "first", attachments: []))
        try await Task.sleep(for: .milliseconds(20))
        let targetID = try await requireLastUserTurnID(h)

        do {
            try await h.engine.send(.editAndResubmitLast(targetBubbleID: targetID,
                                                        text: "edited",
                                                        attachments: []))
            Issue.record("editAndResubmitLast should propagate cancel write failure")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: 5))
        } catch {
            Issue.record("expected PTYError.writeFailed, got \(error)")
        }

        #expect(await pty.writtenData() == [Data("first".utf8), Data([0x03])])
        await h.shutdown()
    }

    @Test("editAndResubmitLast propagates revised prompt write failure after restart")
    func editAndResubmitRevisedPromptWriteFailurePropagates() async throws {
        let firstPTY = ScriptedPTY()
        let restartedPTY = ScriptedPTY(writeSteps: [.fail(.writeFailed(errno: 5))])
        let factory = ScriptedPTYFactory([firstPTY, restartedPTY])
        let h = try await EngineHarness.make(ptyFactory: factory.makePTY)
        try await h.engine.send(.sendPrompt(text: "first", attachments: []))
        try await Task.sleep(for: .milliseconds(20))
        let targetID = try await requireLastUserTurnID(h)

        do {
            try await h.engine.send(.editAndResubmitLast(targetBubbleID: targetID,
                                                        text: "edited fail",
                                                        attachments: []))
            Issue.record("editAndResubmitLast should propagate revised prompt write failure")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: 5))
        } catch {
            Issue.record("expected PTYError.writeFailed, got \(error)")
        }

        #expect(await firstPTY.writtenData() == [Data("first".utf8), Data([0x03])])
        #expect(await restartedPTY.writtenData() == [Data("edited fail".utf8)])
        await h.shutdown()
    }

    @Test("editAndResubmitLast throws staleEditTarget for unknown id")
    func editAndResubmitStaleThrows() async throws {
        let h = try await EngineHarness.make()
        let bogus = UUID()
        await #expect(throws: AgentError.self) {
            try await h.engine.send(.editAndResubmitLast(targetBubbleID: bogus,
                                                        text: "x",
                                                        attachments: []))
        }
        await h.shutdown()
    }

    // MARK: Slash commands

    @Test("newSession writes /clear via adapter encoder")
    func newSession() async throws { try await assertSlash(.newSession, contains: "/clear") }

    @Test("compact writes /compact")
    func compact() async throws { try await assertSlash(.compact, contains: "/compact") }

    @Test("selectModel writes /model with id")
    func selectModel() async throws {
        try await assertSlash(.selectModel(id: "sonnet"), contains: "sonnet")
    }

    @Test("setPermissionMode writes /permission with mode")
    func setPermissionMode() async throws {
        try await assertSlash(.setPermissionMode(.acceptEdits), contains: "acceptEdits")
    }

    @Test("toggleThinkMode on writes /think; off writes /think off")
    func toggleThink() async throws {
        try await assertSlash(.toggleThinkMode(enabled: true), contains: "/think")
        try await assertSlash(.toggleThinkMode(enabled: false), contains: "off")
    }

    @Test("toggleReviewMode on/off")
    func toggleReview() async throws {
        try await assertSlash(.toggleReviewMode(enabled: true), contains: "/review")
        try await assertSlash(.toggleReviewMode(enabled: false), contains: "off")
    }

    @Test("runSlashCommand concatenates name + args")
    func runSlash() async throws {
        try await assertSlash(.runSlashCommand(name: "/foo", args: ["a", "b"]), contains: "/foo a b")
    }

    @Test("runCustomCommand writes path + args")
    func runCustom() async throws {
        try await assertSlash(.runCustomCommand(path: "/proj/review.md", args: ["x"]),
                              contains: "/proj/review.md x")
    }

    @Test("typed slash commands write exact PTY bytes")
    func slashCommandsWriteExactPTYBytes() async throws {
        for testCase in slashPTYWriteCases() {
            try await assertPTYWrite(testCase)
        }
    }

    @Test("typed slash command write failures propagate")
    func slashCommandWriteFailuresPropagate() async throws {
        for testCase in slashPTYWriteCases() {
            try await assertPTYWriteFailure(testCase)
        }
    }

    // MARK: Permission

    @Test("respondToPermission asks adapter to encode response")
    func respondToPermission() async throws {
        let h = try await EngineHarness.make()
        let prompt = PermissionPrompt(toolName: "Bash",
                                      summary: "ls",
                                      argumentsSummary: "{}",
                                      requestedAt: Date())
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await Task.sleep(for: .milliseconds(20))
        try await h.engine.send(.respondToPermission(id: prompt.id, decision: .allow))
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.adapter.recorded.contains(.permissionResponse(.allow, promptID: prompt.id)))
        await h.shutdown()
    }

    @Test("respondToPermission writePTY delivery writes exact PTY bytes")
    func respondToPermissionWritePTYWritesBytes() async throws {
        let pty = ScriptedPTY()
        let adapter = RecordingMockAdapter(permissionDelivery: .writePTY(Data("allow\n".utf8)))
        let h = try await EngineHarness.make(adapter: adapter, pty: pty)
        let prompt = permissionPrompt()
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await Task.sleep(for: .milliseconds(20))

        try await h.engine.send(.respondToPermission(id: prompt.id, decision: .allow))

        #expect(await pty.writtenData() == [Data("allow\n".utf8)])
        #expect(h.adapter.recorded.contains(.permissionResponse(.allow, promptID: prompt.id)))
        await h.shutdown()
    }

    @Test("respondToPermission writePTY delivery propagates PTY write failure")
    func respondToPermissionWritePTYFailurePropagates() async throws {
        let pty = ScriptedPTY(writeSteps: [.fail(.writeFailed(errno: 5))])
        let adapter = RecordingMockAdapter(permissionDelivery: .writePTY(Data("allow\n".utf8)))
        let h = try await EngineHarness.make(adapter: adapter, pty: pty)
        let prompt = permissionPrompt()
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await Task.sleep(for: .milliseconds(20))

        do {
            try await h.engine.send(.respondToPermission(id: prompt.id, decision: .allow))
            Issue.record("respondToPermission should propagate writePTY failure")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: 5))
        } catch {
            Issue.record("expected PTYError.writeFailed, got \(error)")
        }

        #expect(await pty.writtenData() == [Data("allow\n".utf8)])
        await h.shutdown()
    }

    @Test("respondToPermission both delivery writes PTY bytes")
    func respondToPermissionBothWritesPTYBytes() async throws {
        let pty = ScriptedPTY()
        let adapter = RecordingMockAdapter(permissionDelivery: .both(ptyBytes: Data("both\n".utf8),
                                                                     hookStdout: Data("{}".utf8)))
        let h = try await EngineHarness.make(adapter: adapter, pty: pty)
        let prompt = permissionPrompt()
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await Task.sleep(for: .milliseconds(20))

        try await h.engine.send(.respondToPermission(id: prompt.id, decision: .allowAlways))

        #expect(await pty.writtenData() == [Data("both\n".utf8)])
        #expect(h.adapter.recorded.contains(.permissionResponse(.allowAlways, promptID: prompt.id)))
        await h.shutdown()
    }

    @Test("respondToPermission both delivery propagates PTY write failure")
    func respondToPermissionBothFailurePropagates() async throws {
        let pty = ScriptedPTY(writeSteps: [.fail(.writeFailed(errno: 5))])
        let adapter = RecordingMockAdapter(permissionDelivery: .both(ptyBytes: Data("both\n".utf8),
                                                                     hookStdout: Data("{}".utf8)))
        let h = try await EngineHarness.make(adapter: adapter, pty: pty)
        let prompt = permissionPrompt()
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await Task.sleep(for: .milliseconds(20))

        do {
            try await h.engine.send(.respondToPermission(id: prompt.id, decision: .deny))
            Issue.record("respondToPermission should propagate both-delivery PTY failure")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: 5))
        } catch {
            Issue.record("expected PTYError.writeFailed, got \(error)")
        }

        #expect(await pty.writtenData() == [Data("both\n".utf8)])
        await h.shutdown()
    }

    @Test("respondToPermission hook-only delivery does not touch the PTY")
    func respondToPermissionHookOnlyDoesNotWritePTY() async throws {
        let pty = ScriptedPTY()
        let adapter = RecordingMockAdapter(permissionDelivery: .respondToHookProcess(jsonStdout: Data("{}".utf8)))
        let h = try await EngineHarness.make(adapter: adapter, pty: pty)
        let prompt = permissionPrompt()
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await Task.sleep(for: .milliseconds(20))

        try await h.engine.send(.respondToPermission(id: prompt.id, decision: .deny))

        #expect(await pty.writtenData().isEmpty)
        #expect(h.adapter.recorded.contains(.permissionResponse(.deny, promptID: prompt.id)))
        await h.shutdown()
    }

    @Test("respondToPermission for unknown id is a no-op")
    func respondToPermissionUnknown() async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(.respondToPermission(id: UUID(), decision: .deny))
        await h.shutdown()
    }

    // MARK: Lifecycle

    @Test("closeSession transitions engine to stopped")
    func closeSession() async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(.closeSession)
        try await Task.sleep(for: .milliseconds(50))
        let state = await h.engine.currentState
        #expect(state == .stopped)
    }

    // MARK: Out-of-band

    @Test("speakAssistantBubble publishes speakBubbleRequested")
    func speakBubble() async throws {
        let h = try await EngineHarness.make()
        let id = UUID()
        try await h.engine.send(.speakAssistantBubble(eventID: id, action: .play))
        try await Task.sleep(for: .milliseconds(20))
        let events = await h.collectedSoFar()
        #expect(events.contains { if case .speakBubbleRequested = $0 { return true }; return false })
        await h.shutdown()
    }

    @Test("revertFile publishes fileReverted")
    func revertFile() async throws {
        let workspace = try await makeGitWorkspace(initial: "original\n")
        let file = workspace.appendingPathComponent("foo.txt")
        try "changed\n".write(to: file, atomically: true, encoding: .utf8)

        let h = try await EngineHarness.make(workspace: workspace)
        try await h.engine.send(.revertFile(path: "foo.txt"))
        try await Task.sleep(for: .milliseconds(20))

        let events = await h.collectedSoFar()
        #expect(events.contains {
            if case .fileReverted(let p) = $0 { return p == "foo.txt" }; return false
        })
        let restored = try String(contentsOf: file, encoding: .utf8)
        #expect(restored == "original\n")
        await h.shutdown()
    }

    @Test("revertHunk reverts only the selected hunk")
    func revertHunk() async throws {
        let original = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let workspace = try await makeGitWorkspace(initial: original)
        let file = workspace.appendingPathComponent("foo.txt")
        let changed = (1...20)
            .map { line -> String in
                if line == 2 { return "two changed" }
                if line == 18 { return "eighteen changed" }
                return "line \(line)"
            }
            .joined(separator: "\n") + "\n"
        try changed.write(to: file, atomically: true, encoding: .utf8)

        let diff = try await GitDiffEngine(workspace: workspace).diff(for: "foo.txt")
        let firstHunkID = try #require(diff.hunks.first?.id)

        let h = try await EngineHarness.make(workspace: workspace)
        try await h.engine.send(.revertHunk(path: "foo.txt", hunkID: firstHunkID))
        try await Task.sleep(for: .milliseconds(20))

        let events = await h.collectedSoFar()
        #expect(events.contains {
            if case .fileReverted(let p) = $0 { return p == "foo.txt" }; return false
        })
        let content = try String(contentsOf: file, encoding: .utf8)
        #expect(content.contains("line 2\n"))
        #expect(content.contains("eighteen changed"))
        await h.shutdown()
    }

    @Test("updateAutoApprovalRules publishes prefsChanged and persists")
    func updateRules() async throws {
        let h = try await EngineHarness.make()
        let rules = [AutoApprovalRule(match: "Bash ls *", decision: .allow)]
        try await h.engine.send(.updateAutoApprovalRules(rules))
        try await Task.sleep(for: .milliseconds(20))
        let state = await h.engine.prefs.state()
        #expect(state.autoApprovalRules.count == 1)
        await h.shutdown()
    }

    @Test("updateAppearancePref publishes appearancePrefChanged and persists")
    func updateAppearance() async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(.updateAppearancePref(key: .theme, value: .string("dark")))
        try await Task.sleep(for: .milliseconds(20))
        let state = await h.engine.prefs.state()
        #expect(state.appearance.theme == "dark")
        await h.shutdown()
    }

    @Test("requestSnapshot publishes snapshotReady with payload")
    func requestSnapshot() async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(.requestSnapshot(.prefs))
        try await Task.sleep(for: .milliseconds(20))
        let events = await h.collectedSoFar()
        #expect(events.contains {
            if case .snapshotReady(let k, _) = $0 { return k == .prefs }; return false
        })
        await h.shutdown()
    }

    // MARK: Resume startup watchdog

    @Test("resumed sessions without a live SessionStart reuse stalled-turn events")
    func resumedSessionStartupStalls() async throws {
        let clock = FakeClock()
        let adapter = RecordingMockAdapter(capabilities: .ptyTUIFallback)
        let h = try await EngineHarness.make(clock: clock,
                                             adapter: adapter,
                                             resumeSessionID: "old-session")

        try await spinUntil(clock: clock, target: 1, timeout: .seconds(2))
        clock.advance(by: ActivityTiming.resumeStartupStallTimeout + .milliseconds(1))
        try await Task.sleep(for: .milliseconds(40))

        let events = await h.collectedSoFar()
        #expect(events.contains {
            if case .activityStateChanged(.probablyStuck) = $0 { return true }
            return false
        })
        #expect(events.contains {
            if case .noEventGap(_, let elapsed) = $0 {
                return elapsed > ActivityTiming.probablyStuckThreshold
            }
            return false
        })
        await h.shutdown()
    }

    @Test("ready resumed prompt cancels the resume startup watchdog")
    func readyResumePromptCancelsWatchdog() async throws {
        let clock = FakeClock()
        let pty = ScriptedPTY()
        let adapter = RecordingMockAdapter(capabilities: .ptyTUIFallback)
        let h = try await EngineHarness.make(clock: clock,
                                             adapter: adapter,
                                             resumeSessionID: "old-session",
                                             pty: pty)

        try await spinUntil(clock: clock, target: 1, timeout: .seconds(2))
        await pty.emit("❯\u{00A0}\n? for shortcuts\n")
        #expect(h.adapter.emit(.sessionStarted(sessionID: "old-session",
                                              model: nil,
                                              cwd: h.workspace)))
        let sendTask = Task {
            try await h.engine.send(.sendPrompt(text: "ready", attachments: []))
        }
        for _ in 0..<3 {
            clock.advance(by: ActivityTiming.resumePromptReadyPollInterval)
            try await Task.sleep(for: .milliseconds(40))
        }
        try await sendTask.value
        #expect(await pty.writtenTexts() == ["ready"])
        clock.advance(by: ActivityTiming.resumeStartupStallTimeout + .milliseconds(1))
        try await Task.sleep(for: .milliseconds(40))

        let events = await h.collectedSoFar()
        #expect(!events.contains {
            if case .noEventGap(_, let elapsed) = $0 {
                return elapsed > ActivityTiming.probablyStuckThreshold
            }
            return false
        })
        #expect(!events.contains {
            if case .activityStateChanged(.probablyStuck) = $0 { return true }
            return false
        })
        await h.shutdown()
    }

    @Test("resumed prompt waits for Claude's ready prompt before writing PTY bytes")
    func resumedPromptWaitsForClaudeReadyPrompt() async throws {
        let pty = ScriptedPTY()
        let adapter = RecordingMockAdapter(capabilities: .ptyTUIFallback)
        let h = try await EngineHarness.make(adapter: adapter,
                                             resumeSessionID: "old-session",
                                             pty: pty)

        let sendTask = Task {
            try await h.engine.send(.sendPrompt(text: "held", attachments: []))
        }
        try await Task.sleep(for: .milliseconds(40))

        #expect(await pty.writtenData().isEmpty)
        #expect((await h.collectedSoFar()).contains {
            if case .userTurn(_, let text) = $0 { return text == "held" }
            return false
        })

        #expect(h.adapter.emit(.sessionStarted(sessionID: "old-session",
                                              model: nil,
                                              cwd: h.workspace)))
        try await Task.sleep(for: .milliseconds(150))
        #expect(await pty.writtenData().isEmpty)

        await pty.emit("❯\u{00A0}\n? for shortcuts\n")
        try await waitUntil(timeout: .seconds(2)) {
            await pty.writtenTexts() == ["held"]
        }

        #expect(await pty.writtenTexts() == ["held"])
        try await sendTask.value
        await h.shutdown()
    }

    @Test("new TUI session first prompt waits for Claude's ready prompt")
    func newTUISessionPromptWaitsForClaudeReadyPrompt() async throws {
        let pty = ScriptedPTY()
        let adapter = RecordingMockAdapter(capabilities: .ptyTUIFallback)
        let h = try await EngineHarness.make(adapter: adapter, pty: pty)

        let sendTask = Task {
            try await h.engine.send(.sendPrompt(text: "fresh held", attachments: []))
        }
        try await Task.sleep(for: .milliseconds(40))

        #expect(await pty.writtenData().isEmpty)

        #expect(h.adapter.emit(.sessionStarted(sessionID: "new-session",
                                              model: nil,
                                              cwd: h.workspace)))
        await pty.emit("❯\u{00A0}\n? for shortcuts\n")
        try await waitUntil(timeout: .seconds(2)) {
            await pty.writtenTexts() == ["fresh held"]
        }

        #expect(await pty.writtenTexts() == ["fresh held"])
        try await sendTask.value
        await h.shutdown()
    }

    @Test("startup timeout does not release prompt while permission is pending")
    func startupTimeoutDoesNotReleasePromptWhilePermissionPending() async throws {
        let clock = FakeClock()
        let pty = ScriptedPTY()
        let adapter = RecordingMockAdapter(capabilities: .ptyTUIFallback)
        let h = try await EngineHarness.make(clock: clock, adapter: adapter, pty: pty)

        let sendTask = Task {
            try await h.engine.send(.sendPrompt(text: "blocked by trust", attachments: []))
        }
        let prompt = PermissionPrompt(toolName: "WorkspaceTrust",
                                      summary: "Trust this workspace?",
                                      argumentsSummary: h.workspace.path,
                                      requestedAt: clock.now())
        #expect(h.adapter.emit(.permissionRequest(prompt: prompt)))

        // Wait until the engine has ingested the permission into pending state
        // before advancing the resume-startup watchdog — otherwise the stall
        // handler can race ahead of the adapter event fan-out.
        try await waitUntil(timeout: .seconds(2)) {
            await h.collectedSoFar().contains {
                if case .permissionRequest(let p) = $0 { return p.id == prompt.id }
                return false
            }
        }
        try await spinUntil(clock: clock, target: 1, timeout: .seconds(2))
        clock.advance(by: ActivityTiming.resumeStartupStallTimeout + .milliseconds(1))
        try await Task.sleep(for: .milliseconds(40))

        #expect(await pty.writtenData().isEmpty)
        sendTask.cancel()
        await h.shutdown()
    }

    @Test("resumed prompt releases after resume startup timeout")
    func resumedPromptReleasesAfterStartupTimeout() async throws {
        let clock = FakeClock()
        let pty = ScriptedPTY()
        let adapter = RecordingMockAdapter(capabilities: .ptyTUIFallback)
        let h = try await EngineHarness.make(clock: clock,
                                             adapter: adapter,
                                             resumeSessionID: "old-session",
                                             pty: pty)

        let sendTask = Task {
            try await h.engine.send(.sendPrompt(text: "released", attachments: []))
        }
        try await spinUntil(clock: clock, target: 1, timeout: .seconds(2))
        try await Task.sleep(for: .milliseconds(40))

        #expect(await pty.writtenData().isEmpty)
        clock.advance(by: ActivityTiming.resumeStartupStallTimeout + .milliseconds(1))
        try await Task.sleep(for: .milliseconds(40))
        try await sendTask.value

        #expect(await pty.writtenTexts() == ["released"])
        await h.shutdown()
    }

    @Test("ready prompt detector accepts current and guarded fallback prompts")
    func readyPromptDetectorAcceptsKnownPrompts() {
        #expect(AgentEngine.rowsContainClaudeReadyPrompt([
            "● high · /effort",
            "────────────────",
            "❯\u{00A0}",
            "? for shortcuts · ← for agents"
        ]))
        #expect(AgentEngine.rowsContainClaudeReadyPrompt([
            ">",
            "? for shortcuts"
        ]))
    }

    @Test("ready prompt detector rejects replayed prompt text and stray arrows")
    func readyPromptDetectorRejectsFalsePositives() {
        #expect(!AgentEngine.rowsContainClaudeReadyPrompt([
            "❯ good day",
            "⏺ Good day, Alice!"
        ]))
        #expect(!AgentEngine.rowsContainClaudeReadyPrompt([
            ">",
            "some shell transcript without Claude footer"
        ]))
    }

    @Test("unsubmitted-prompt detector matches input rows still carrying text")
    func unsubmittedPromptDetectorMatchesPendingText() {
        #expect(AgentEngine.rowsShowUnsubmittedPrompt([
            "❯ still here",
            "? for shortcuts"
        ]))
        #expect(AgentEngine.rowsShowUnsubmittedPrompt([
            "> pending text",
            "? for shortcuts"
        ]))
    }

    @Test("unsubmitted-prompt detector ignores empty input rows and arrows")
    func unsubmittedPromptDetectorIgnoresEmptyInput() {
        #expect(!AgentEngine.rowsShowUnsubmittedPrompt([
            "❯\u{00A0}",
            "? for shortcuts"
        ]))
        #expect(!AgentEngine.rowsShowUnsubmittedPrompt([
            "> pending text without footer"
        ]))
    }

    // MARK: Startup submit recovery (missed-Enter safety net)

    @Test("startup submit recovery re-sends Enter when first prompt stays unsubmitted")
    func startupSubmitRecoveryResendsEnterWhenUnsubmitted() async throws {
        let clock = FakeClock()
        let pty = ScriptedPTY()
        let adapter = RecordingMockAdapter(capabilities: .ptyTUIFallback)
        let h = try await EngineHarness.make(clock: clock,
                                             adapter: adapter,
                                             resumeSessionID: "old-session",
                                             pty: pty)

        try await spinUntil(clock: clock, target: 1, timeout: .seconds(2))
        await pty.emit("❯\u{00A0}\n? for shortcuts\n")
        #expect(h.adapter.emit(.sessionStarted(sessionID: "old-session",
                                              model: nil,
                                              cwd: h.workspace)))
        let sendTask = Task {
            try await h.engine.send(.sendPrompt(text: "stuck", attachments: []))
        }
        for _ in 0..<3 {
            clock.advance(by: ActivityTiming.resumePromptReadyPollInterval)
            try await Task.sleep(for: .milliseconds(40))
        }
        try await sendTask.value
        #expect(await pty.writtenTexts() == ["stuck"])

        // Simulate the prompt still sitting in the input row (Enter swallowed).
        await pty.emit("❯ stuck\n? for shortcuts\n")
        try await Task.sleep(for: .milliseconds(40))
        clock.advance(by: ActivityTiming.startupSubmitRecoveryDelay + .milliseconds(1))
        try await waitUntil(timeout: .seconds(2)) {
            await pty.writtenTexts() == ["stuck", "\r"]
        }

        #expect(await pty.writtenTexts() == ["stuck", "\r"])
        await h.shutdown()
    }

    @Test("startup submit recovery sends no Enter when first prompt was accepted")
    func startupSubmitRecoveryStaysQuietWhenAccepted() async throws {
        let clock = FakeClock()
        let pty = ScriptedPTY()
        let adapter = RecordingMockAdapter(capabilities: .ptyTUIFallback)
        let h = try await EngineHarness.make(clock: clock,
                                             adapter: adapter,
                                             resumeSessionID: "old-session",
                                             pty: pty)

        try await spinUntil(clock: clock, target: 1, timeout: .seconds(2))
        await pty.emit("❯\u{00A0}\n? for shortcuts\n")
        #expect(h.adapter.emit(.sessionStarted(sessionID: "old-session",
                                              model: nil,
                                              cwd: h.workspace)))
        let sendTask = Task {
            try await h.engine.send(.sendPrompt(text: "accepted", attachments: []))
        }
        for _ in 0..<3 {
            clock.advance(by: ActivityTiming.resumePromptReadyPollInterval)
            try await Task.sleep(for: .milliseconds(40))
        }
        try await sendTask.value
        #expect(await pty.writtenTexts() == ["accepted"])

        // Input row is empty again: Claude accepted the prompt.
        await pty.emit("❯\u{00A0}\n? for shortcuts\n")
        try await Task.sleep(for: .milliseconds(40))
        clock.advance(by: ActivityTiming.startupSubmitRecoveryDelay + .milliseconds(1))
        try await Task.sleep(for: .milliseconds(80))

        #expect(await pty.writtenTexts() == ["accepted"])
        await h.shutdown()
    }

    // MARK: Permission auto-deny timeout

    @Test("Pending permission auto-denies after permissionTimeout elapses")
    func permissionAutoDenies() async throws {
        let clock = FakeClock()
        let h = try await EngineHarness.make(clock: clock, permissionTimeout: .seconds(60))
        let prompt = PermissionPrompt(toolName: "Bash",
                                      summary: "rm -rf /",
                                      argumentsSummary: "{}",
                                      requestedAt: clock.now())
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await spinUntil(clock: clock, target: 1, timeout: .seconds(2))
        clock.advance(by: .seconds(61))
        try await Task.sleep(for: .milliseconds(80))
        let events = await h.collectedSoFar()
        let sawResolved = events.contains {
            if case .permissionAlreadyResolved(let id, let by) = $0 {
                return id == prompt.id && by == "timeout"
            }
            return false
        }
        #expect(sawResolved)
        #expect(h.adapter.recorded.contains(.permissionResponse(.deny, promptID: prompt.id)))
        await h.shutdown()
    }

    @Test("respondToPermission before timeout cancels the auto-deny")
    func respondCancelsTimeout() async throws {
        let clock = FakeClock()
        let h = try await EngineHarness.make(clock: clock, permissionTimeout: .seconds(60))
        let prompt = PermissionPrompt(toolName: "Bash",
                                      summary: "x",
                                      argumentsSummary: "{}",
                                      requestedAt: clock.now())
        h.adapter.emit(.permissionRequest(prompt: prompt))
        try await spinUntil(clock: clock, target: 1, timeout: .seconds(2))
        try await h.engine.send(.respondToPermission(id: prompt.id, decision: .allow))
        try await Task.sleep(for: .milliseconds(20))
        clock.advance(by: .seconds(120))
        try await Task.sleep(for: .milliseconds(50))
        let events = await h.collectedSoFar()
        let sawTimeoutResolution = events.contains {
            if case .permissionAlreadyResolved(_, let by) = $0 { return by == "timeout" }
            return false
        }
        #expect(!sawTimeoutResolution)
        await h.shutdown()
    }

    // MARK: Helpers

    private struct PTYWriteCase {
        let name: String
        let command: AgentCommand
        let expectedBytes: Data

        init(_ name: String, _ command: AgentCommand, _ expectedText: String) {
            self.name = name
            self.command = command
            self.expectedBytes = Data(expectedText.utf8)
        }

        init(_ name: String, _ command: AgentCommand, bytes: Data) {
            self.name = name
            self.command = command
            self.expectedBytes = bytes
        }
    }

    private func slashPTYWriteCases() -> [PTYWriteCase] {
        [
            .init("newSession", .newSession, "/clear\n"),
            .init("compact", .compact, "/compact\n"),
            .init("selectModel", .selectModel(id: "sonnet"), "/model sonnet\n"),
            .init("setPermissionMode", .setPermissionMode(.acceptEdits), "/permission acceptEdits\n"),
            .init("toggleThinkMode on", .toggleThinkMode(enabled: true), "/think\n"),
            .init("toggleThinkMode off", .toggleThinkMode(enabled: false), "/think off\n"),
            .init("toggleReviewMode on", .toggleReviewMode(enabled: true), "/review\n"),
            .init("toggleReviewMode off", .toggleReviewMode(enabled: false), "/review off\n"),
            .init("runSlashCommand", .runSlashCommand(name: "/foo", args: ["a", "b"]), "/foo a b\n"),
            .init("runCustomCommand",
                  .runCustomCommand(path: "/proj/review.md", args: ["x"]),
                  "/proj/review.md x\n")
        ]
    }

    private func assertPTYWrite(_ testCase: PTYWriteCase,
                                interrupts: Bool = false) async throws {
        let pty = ScriptedPTY()
        let h = try await EngineHarness.make(pty: pty)

        try await h.engine.send(testCase.command)

        #expect(await pty.writtenData() == [testCase.expectedBytes],
                "\(testCase.name) wrote unexpected PTY bytes")
        #expect(await pty.wasInterrupted() == interrupts,
                "\(testCase.name) interrupt state mismatch")
        await h.shutdown()
    }

    private func assertPTYWriteFailure(_ testCase: PTYWriteCase) async throws {
        let pty = ScriptedPTY(writeSteps: [.fail(.writeFailed(errno: 5))])
        let h = try await EngineHarness.make(pty: pty)

        do {
            try await h.engine.send(testCase.command)
            Issue.record("\(testCase.name) should propagate PTY write failure")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: 5))
        } catch {
            Issue.record("\(testCase.name) threw unexpected error: \(error)")
        }

        #expect(await pty.writtenData() == [testCase.expectedBytes],
                "\(testCase.name) failed after writing unexpected bytes")
        #expect(await pty.wasInterrupted() == false,
                "\(testCase.name) should not interrupt after a failed write")
        await h.shutdown()
    }

    private func requireLastUserTurnID(_ h: EngineHarness) async throws -> UUID {
        let events = await h.collectedSoFar()
        guard case .userTurn(let idString, _)? = events.last(where: {
            if case .userTurn = $0 { return true }
            return false
        }), let id = UUID(uuidString: idString) else {
            Issue.record("no userTurn event captured")
            throw AgentError.internalInvariant(detail: "missing userTurn in test harness")
        }
        return id
    }

    private func permissionPrompt() -> PermissionPrompt {
        PermissionPrompt(toolName: "Bash",
                         summary: "ls",
                         argumentsSummary: "{}",
                         requestedAt: Date())
    }

    private func assertSlash(_ command: AgentCommand, contains substring: String) async throws {
        let h = try await EngineHarness.make()
        try await h.engine.send(command)
        try await Task.sleep(for: .milliseconds(20))
        let prompts = h.adapter.recorded.compactMap { entry -> String? in
            if case .userPrompt(let s) = entry { return s }; return nil
        }
        #expect(prompts.contains { $0.contains(substring) },
                "no slash text matched '\(substring)' in \(prompts)")
        await h.shutdown()
    }

    private func spinUntil(clock: FakeClock, target: Int, timeout: Duration) async throws {
        let start = ContinuousClock.now
        while clock.pendingSleepCount < target {
            if start.duration(to: .now) > timeout { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func waitUntil(timeout: Duration,
                           predicate: () async -> Bool) async throws {
        let start = ContinuousClock.now
        while !(await predicate()) {
            if start.duration(to: .now) > timeout {
                Issue.record("timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeGitWorkspace(initial: String) async throws -> URL {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-git-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appendingPathComponent("foo.txt")
        try initial.write(to: file, atomically: true, encoding: .utf8)
        try await runGit(["init"], cwd: workspace)
        try await runGit(["add", "foo.txt"], cwd: workspace)
        try await runGit([
            "-c", "user.name=Codemixer Tests",
            "-c", "user.email=codemixer@example.invalid",
            "commit", "-m", "baseline"
        ], cwd: workspace)
        return workspace
    }

    private func runGit(_ arguments: [String], cwd: URL) async throws {
        _ = try await ProcessRunner().run(executable: SystemPaths.env,
                                          arguments: ["git"] + arguments,
                                          cwd: cwd)
    }
}

// MARK: - Test harness

actor EventCollector {
    private(set) var events: [AgentEvent] = []
    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream { events.append(entry.event) }
    }
    func snapshot() -> [AgentEvent] { events }
}

struct EngineHarness {
    let engine: AgentEngine
    let adapter: RecordingMockAdapter
    let collector: EventCollector
    let subID: UUID
    let workspace: URL
    let environment: FakeEnvironment
    let fileSystem: InMemoryFileSystem
    let pty: ScriptedPTY?

    static func make(clock: any AgentClock = SystemClock(),
                     workspace: URL? = nil,
                     environment: FakeEnvironment? = nil,
                     permissionTimeout: Duration = .seconds(300),
                     adapter: RecordingMockAdapter? = nil,
                     resumeSessionID: String? = nil,
                     pty: ScriptedPTY? = nil,
                     ptyFactory: AgentPTYFactory? = nil) async throws -> EngineHarness {
        let fs = InMemoryFileSystem()
        let workspace = workspace ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-engine-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let env = environment ?? FakeEnvironment(home: workspace)
        let seams = Seams.fake(environment: env, fileSystem: fs).with(clock: clock)
        let engine: AgentEngine
        if let ptyFactory {
            engine = AgentEngine(seams: seams,
                                 permissionTimeout: permissionTimeout,
                                 ptyFactory: ptyFactory)
        } else if let pty {
            engine = AgentEngine(seams: seams,
                                 permissionTimeout: permissionTimeout,
                                 ptyFactory: { _ in pty })
        } else {
            engine = AgentEngine(seams: seams, permissionTimeout: permissionTimeout)
        }
        await engine.bootstrap()
        let adapter = adapter ?? RecordingMockAdapter()
        try await engine.start(adapter: adapter,
                               workspace: workspace,
                               resumeSessionID: resumeSessionID)
        let sub = await engine.bus.subscribe()
        let collector = EventCollector()
        Task { await collector.ingest(sub.stream) }
        return EngineHarness(engine: engine,
                             adapter: adapter,
                             collector: collector,
                             subID: sub.id,
                             workspace: workspace,
                             environment: env,
                             fileSystem: fs,
                             pty: pty)
    }

    func collectedSoFar() async -> [AgentEvent] { await collector.snapshot() }

    func shutdown() async {
        await engine.bus.unsubscribe(subID)
        await engine.shutdown(reason: .naturalExit)
    }
}

final class CapturingPTYFactory: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lastSpec: PTYHost.ChildSpec?
    private let inner = ScriptedPTY()

    func makePTY(_ spec: PTYHost.ChildSpec) throws -> any AgentPTY {
        lock.lock()
        lastSpec = spec
        lock.unlock()
        return inner
    }
}

final class ScriptedPTYFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var ptys: [ScriptedPTY]

    init(_ ptys: [ScriptedPTY]) {
        self.ptys = ptys
    }

    func makePTY(_ spec: PTYHost.ChildSpec) throws -> any AgentPTY {
        lock.lock()
        defer { lock.unlock() }
        guard !ptys.isEmpty else {
            throw AgentError.internalInvariant(detail: "scripted PTY factory exhausted")
        }
        return ptys.removeFirst()
    }
}

actor ScriptedPTY: AgentPTY {
    enum WriteStep: Sendable {
        case succeed
        case fail(PTYError)
    }

    nonisolated let outboundBytes: AsyncStream<Data>

    private let outboundContinuation: AsyncStream<Data>.Continuation
    private let writeSteps: [WriteStep]
    private var nextWriteIndex = 0
    private var writes: [Data] = []
    private var probes: [Bool] = []
    private var writeProbe: (@Sendable (Data) async -> Bool)?
    private var closed = false
    private var interrupted = false

    init(writeSteps: [WriteStep] = []) {
        var continuation: AsyncStream<Data>.Continuation!
        self.outboundBytes = AsyncStream(bufferingPolicy: .bufferingOldest(StreamBufferDefaults.ptyChunks)) { c in
            continuation = c
        }
        self.outboundContinuation = continuation
        self.writeSteps = writeSteps
    }

    func setWriteProbe(_ probe: @escaping @Sendable (Data) async -> Bool) {
        writeProbe = probe
    }

    func write(_ data: Data) async throws {
        guard !closed else { throw PTYError.alreadyClosed }
        writes.append(data)
        if let writeProbe {
            probes.append(await writeProbe(data))
        }

        let step = nextWriteIndex < writeSteps.count ? writeSteps[nextWriteIndex] : .succeed
        nextWriteIndex += 1
        switch step {
        case .succeed:
            return
        case .fail(let error):
            throw error
        }
    }

    func interrupt() {
        interrupted = true
    }

    func close() {
        closed = true
        outboundContinuation.finish()
    }

    func emit(_ text: String) {
        outboundContinuation.yield(Data(text.utf8))
    }

    func writtenTexts() -> [String] {
        writes.map { String(decoding: $0, as: UTF8.self) }
    }

    func writtenData() -> [Data] {
        writes
    }

    func writeProbeResults() -> [Bool] {
        probes
    }

    func wasInterrupted() -> Bool {
        interrupted
    }
}

// MARK: - Seams extension

extension Seams {
    /// Return a copy of the seams with `clock` replaced.
    func with(clock: any AgentClock) -> Seams {
        Seams(clock: clock,
              random: self.random,
              environment: self.environment,
              fileSystem: self.fileSystem)
    }
}

// MARK: - AgentEngine.slashLine internal helper tests

@Suite("AgentEngine — slashLine helper")
struct SlashLineTests {
    // Exercise `slashLine(for:)` without spinning up a full engine.
    // The method lives on the actor, so every test is async.
    private let engine = AgentEngine(seams: .fake())

    @Test("newSession produces /clear with newline")
    func newSession() async {
        let line = await engine.slashLine(for: .newSession)
        #expect(line == "/clear\n")
    }

    @Test("compact produces /compact with newline")
    func compact() async {
        let line = await engine.slashLine(for: .compact)
        #expect(line == "/compact\n")
    }

    @Test("selectModel encodes model id")
    func selectModel() async {
        let line = await engine.slashLine(for: .selectModel(id: "claude-opus-4"))
        #expect(line == "/model claude-opus-4\n")
    }

    @Test("toggleThinkMode on produces /think")
    func thinkOn() async {
        let line = await engine.slashLine(for: .toggleThinkMode(enabled: true))
        #expect(line == "/think\n")
    }

    @Test("toggleThinkMode off produces /think off")
    func thinkOff() async {
        let line = await engine.slashLine(for: .toggleThinkMode(enabled: false))
        #expect(line == "/think off\n")
    }

    @Test("runSlashCommand joins name and args with spaces")
    func runSlashCommand() async {
        let line = await engine.slashLine(for: .runSlashCommand(name: "/memory", args: ["add", "note"]))
        #expect(line == "/memory add note\n")
    }

    @Test("sendPrompt produces empty string (not a slash command)")
    func sendPromptIsEmpty() async {
        let line = await engine.slashLine(for: .sendPrompt(text: "hello", attachments: []))
        #expect(line == "")
    }
}
