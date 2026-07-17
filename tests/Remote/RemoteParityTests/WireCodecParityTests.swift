import Foundation
import Testing
@testable import AgentCore
@testable import AgentProtocol

/// Round-trip parity for every `AgentEvent` case. Beyond shape parity we
/// assert field-level survival via a semantic equality helper that allows
/// known lossy conversions (URL canonicalisation, `Duration` ↔ `Int ms`
/// rounding).
@Suite("WireCodec — domain ↔ wire round-trip")
struct WireCodecParityTests {

    @Test("Every AgentEvent shape round-trips through WireCodec")
    func eventShapeRoundTrip() {
        for event in allEvents() {
            let restored = WireCodec.decode(WireCodec.encode(event))
            #expect(restored.shape == event.shape,
                    "shape mismatch for \(event)")
        }
    }

    @Test("Every AgentEvent round-trips with field-level semantic equality")
    func eventSemanticRoundTrip() {
        for event in allEvents() {
            let restored = WireCodec.decode(WireCodec.encode(event))
            #expect(restored.semanticallyEquals(event),
                    "semantic mismatch for \(event) -> \(restored)")
        }
    }

    @Test("ToolProgress round-trips for every arm")
    func toolProgressRoundTrip() {
        let progresses: [ToolProgress] = [
            .bashLine("compiling…"),
            .fileBytes(written: 128, total: 1024),
            .fileBytes(written: 0, total: nil),
            .generic(message: "still working"),
        ]
        for p in progresses {
            let event = AgentEvent.toolProgress(callID: UUID(), progress: p)
            let restored = WireCodec.decode(WireCodec.encode(event))
            guard case .toolProgress(_, let restoredP) = restored else {
                Issue.record("not a toolProgress: \(restored)"); return
            }
            #expect(restoredP.semanticallyEquals(p))
        }
    }

    @Test("ToolInput preserves summary + jsonPayload")
    func toolInputFields() {
        let input = ToolInput(summary: "ls", jsonPayload: #"{"path":"/tmp"}"#)
        let event = AgentEvent.toolStart(id: "t",
                                         name: "Bash",
                                         input: input,
                                         startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let restored = WireCodec.decode(WireCodec.encode(event))
        guard case .toolStart(_, _, let r, _) = restored else {
            Issue.record("not a toolStart"); return
        }
        #expect(r.summary == input.summary)
        #expect(r.jsonPayload == input.jsonPayload)
    }

    @Test("ToolOutput preserves summary + jsonPayload + errorMessage")
    func toolOutputFields() {
        let output = ToolOutput(summary: "done",
                                jsonPayload: #"{"ok":true}"#,
                                errorMessage: nil)
        let event = AgentEvent.toolEnd(id: "t", success: true, output: output, durationMS: 7)
        let restored = WireCodec.decode(WireCodec.encode(event))
        guard case .toolEnd(_, _, let r, _) = restored else {
            Issue.record("not a toolEnd"); return
        }
        #expect(r.summary == output.summary)
        #expect(r.jsonPayload == output.jsonPayload)
        #expect(r.errorMessage == output.errorMessage)
    }

    @Test("PermissionPrompt preserves every field")
    func permissionPromptFields() {
        let id = UUID()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let prompt = PermissionPrompt(id: id,
                                      toolName: "Bash",
                                      summary: "rm -rf /",
                                      argumentsSummary: "{}",
                                      requestedAt: at)
        let event = AgentEvent.permissionRequest(prompt: prompt)
        let restored = WireCodec.decode(WireCodec.encode(event))
        guard case .permissionRequest(let r) = restored else {
            Issue.record("not a permissionRequest"); return
        }
        #expect(r.id == id)
        #expect(r.toolName == "Bash")
        #expect(r.summary == "rm -rf /")
        #expect(r.argumentsSummary == "{}")
        #expect(Int(r.requestedAt.timeIntervalSince1970) == Int(at.timeIntervalSince1970))
    }

    @Test("authURL survives string serialisation")
    func authURLRoundTrip() {
        let event = AgentEvent.authURL(URL(string: "https://claude.ai/oauth/abc")!)
        let restored = WireCodec.decode(WireCodec.encode(event))
        guard case .authURL(let u) = restored else { Issue.record("not authURL"); return }
        #expect(u.absoluteString == "https://claude.ai/oauth/abc")
    }

    @Test("snapshotReady payload base64-round-trips")
    func snapshotPayload() {
        let payload = Data((0..<256).map { UInt8($0 & 0xff) })
        let event = AgentEvent.snapshotReady(kind: .diff, payload: payload)
        let restored = WireCodec.decode(WireCodec.encode(event))
        guard case .snapshotReady(let kind, let p) = restored else {
            Issue.record("not snapshotReady"); return
        }
        #expect(kind == .diff)
        #expect(p == payload)
    }

    @Test("error event preserves code through the wire")
    func errorCodeSurvives() {
        let event = AgentEvent.error(.spawnFailed(errno: 22, detail: "bad arg"))
        let restored = WireCodec.decode(WireCodec.encode(event))
        guard case .error(let err) = restored else { Issue.record("not error"); return }
        #expect(err.code == "spawn_failed")
        guard case .spawnFailed(let errno, let detail) = err else {
            Issue.record("expected spawnFailed"); return
        }
        #expect(errno == 22)
        #expect(detail == "bad arg")
    }

    @Test("noEventGap duration round-trips with ms granularity")
    func noEventGapDuration() {
        let event = AgentEvent.noEventGap(turnID: UUID(), elapsed: .milliseconds(11_500))
        let restored = WireCodec.decode(WireCodec.encode(event))
        guard case .noEventGap(_, let d) = restored else {
            Issue.record("not noEventGap"); return
        }
        #expect(d == .milliseconds(11_500))
    }

    /// One value per `AgentEvent` case, including every arm of nested unions.
    private func allEvents() -> [AgentEvent] {
        let cwd = URL(fileURLWithPath: "/tmp/workspace")
        let prompt = PermissionPrompt(toolName: "Bash",
                                      summary: "Run: ls",
                                      argumentsSummary: "{}",
                                      requestedAt: Date(timeIntervalSince1970: 1_700_000_000))
        return [
            .sessionStarted(sessionID: "s1", model: "claude-sonnet-4-5", cwd: cwd),
            .userTurn(id: "u1", text: "hello"),
            .textDelta(messageID: UUID(), delta: "world"),
            .assistantText(id: "a1", blockID: "b1", text: "ok", isFinal: true),
            .thinkingChunk(blockID: UUID(), delta: "step"),
            .thinkingComplete(blockID: UUID(), duration: .milliseconds(420)),
            .toolStart(id: "t1", name: "Bash",
                       input: ToolInput(summary: "ls"),
                       startedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            .toolProgress(callID: UUID(), progress: .bashLine("line 1")),
            .toolProgress(callID: UUID(), progress: .fileBytes(written: 1, total: 2)),
            .toolProgress(callID: UUID(), progress: .generic(message: "x")),
            .toolEnd(id: "t1", success: true, output: ToolOutput(summary: "done"), durationMS: 12),
            .permissionRequest(prompt: prompt),
            .permissionAlreadyResolved(id: UUID(), byDevice: "Phone"),
            .statusPhraseChanged(source: .hookHint, phrase: "Reading"),
            .activityStateChanged(.stillWorking),
            .noEventGap(turnID: UUID(), elapsed: .seconds(11)),
            .authURL(URL(string: "https://claude.ai/oauth/abc")!),
            .bell,
            .fileTouched(URL(fileURLWithPath: "/tmp/a.txt"), kind: .fsObserved),
            .usage(tokens: 10, costUSD: 0.001),
            .engineRestarted,
            .stopped(reason: .naturalExit),
            .error(.binaryNotFound(agentID: .claudeCode, hint: "install")),
            .speakBubbleRequested(id: "bubble-1"),
            .fileReverted(path: "/tmp/a.txt"),
            .prefsChanged(rulesCount: 2),
            .appearancePrefChanged(key: .theme, value: .string("dark")),
            .snapshotReady(kind: .prefs, payload: Data("{}".utf8)),
            .clientAction(ClientAction(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                kind: .permissionMode,
                title: "Permission mode",
                detail: "Plan"
            )),
        ]
    }
}

// MARK: - Semantic equality helpers

extension AgentEvent {
    /// Loose shape tag for equality without expecting URL/Date round-trip parity.
    fileprivate var shape: String {
        switch self {
        case .sessionStarted:           "sessionStarted"
        case .userTurn:                 "userTurn"
        case .textDelta:                "textDelta"
        case .assistantText:            "assistantText"
        case .thinkingChunk:            "thinkingChunk"
        case .thinkingComplete:         "thinkingComplete"
        case .toolStart:                "toolStart"
        case .toolProgress:             "toolProgress"
        case .toolEnd:                  "toolEnd"
        case .permissionRequest:        "permissionRequest"
        case .permissionAlreadyResolved: "permissionAlreadyResolved"
        case .statusPhraseChanged:      "statusPhraseChanged"
        case .activityStateChanged:     "activityStateChanged"
        case .noEventGap:               "noEventGap"
        case .authURL:                  "authURL"
        case .bell:                     "bell"
        case .fileTouched:              "fileTouched"
        case .usage:                    "usage"
        case .engineRestarted:          "engineRestarted"
        case .stopped:                  "stopped"
        case .error:                    "error"
        case .speakBubbleRequested:     "speakBubbleRequested"
        case .fileReverted:             "fileReverted"
        case .prefsChanged:             "prefsChanged"
        case .appearancePrefChanged:    "appearancePrefChanged"
        case .snapshotReady:            "snapshotReady"
        case .clientAction:             "clientAction"
        }
    }

    /// Field-level equality that ignores known lossy round-trip conversions:
    ///   • `URL.path` canonicalisation (string round-trip via `URL.absoluteString`)
    ///   • `Duration` → integer milliseconds → `Duration` (ms granularity)
    ///   • `AgentError` unknown codes decode to `.internalInvariant`
    fileprivate func semanticallyEquals(_ other: AgentEvent) -> Bool {
        guard self.shape == other.shape else { return false }
        switch (self, other) {
        case (.sessionStarted(let id1, let m1, let c1), .sessionStarted(let id2, let m2, let c2)):
            return id1 == id2 && m1 == m2 && c1.path == c2.path
        case (.userTurn(let id1, let t1), .userTurn(let id2, let t2)):
            return id1 == id2 && t1 == t2
        case (.textDelta(let m1, let d1), .textDelta(let m2, let d2)):
            return m1 == m2 && d1 == d2
        case (.assistantText(let id1, let b1, let t1, let f1),
              .assistantText(let id2, let b2, let t2, let f2)):
            return id1 == id2 && b1 == b2 && t1 == t2 && f1 == f2
        case (.thinkingChunk(let b1, let d1), .thinkingChunk(let b2, let d2)):
            return b1 == b2 && d1 == d2
        case (.thinkingComplete(let b1, let d1), .thinkingComplete(let b2, let d2)):
            return b1 == b2 && msEqual(d1, d2)
        case (.toolStart(let id1, let n1, let i1, let s1),
              .toolStart(let id2, let n2, let i2, let s2)):
            return id1 == id2 && n1 == n2 && i1.summary == i2.summary
                && i1.jsonPayload == i2.jsonPayload
                && Int(s1.timeIntervalSince1970) == Int(s2.timeIntervalSince1970)
        case (.toolProgress(let c1, let p1), .toolProgress(let c2, let p2)):
            return c1 == c2 && p1.semanticallyEquals(p2)
        case (.toolEnd(let id1, let ok1, let o1, let ms1),
              .toolEnd(let id2, let ok2, let o2, let ms2)):
            return id1 == id2 && ok1 == ok2
                && o1.summary == o2.summary && o1.jsonPayload == o2.jsonPayload
                && o1.errorMessage == o2.errorMessage && ms1 == ms2
        case (.permissionRequest(let p1), .permissionRequest(let p2)):
            return p1.id == p2.id && p1.toolName == p2.toolName
                && p1.summary == p2.summary && p1.argumentsSummary == p2.argumentsSummary
        case (.permissionAlreadyResolved(let id1, let by1),
              .permissionAlreadyResolved(let id2, let by2)):
            return id1 == id2 && by1 == by2
        case (.statusPhraseChanged(let s1, let p1), .statusPhraseChanged(let s2, let p2)):
            return s1 == s2 && p1 == p2
        case (.activityStateChanged(let a1), .activityStateChanged(let a2)):
            return a1 == a2
        case (.noEventGap(let t1, let d1), .noEventGap(let t2, let d2)):
            return t1 == t2 && msEqual(d1, d2)
        case (.authURL(let u1), .authURL(let u2)):
            return u1.absoluteString == u2.absoluteString
        case (.bell, .bell):
            return true
        case (.fileTouched(let u1, let k1), .fileTouched(let u2, let k2)):
            return u1.path == u2.path && k1 == k2
        case (.usage(let t1, let c1), .usage(let t2, let c2)):
            return t1 == t2 && c1 == c2
        case (.engineRestarted, .engineRestarted):
            return true
        case (.stopped(let r1), .stopped(let r2)):
            return r1 == r2
        case (.error(let e1), .error(let e2)):
            return e1 == e2
        case (.speakBubbleRequested(let id1), .speakBubbleRequested(let id2)):
            return id1 == id2
        case (.fileReverted(let p1), .fileReverted(let p2)):
            return p1 == p2
        case (.prefsChanged(let n1), .prefsChanged(let n2)):
            return n1 == n2
        case (.appearancePrefChanged(let k1, let v1), .appearancePrefChanged(let k2, let v2)):
            return k1 == k2 && v1 == v2
        case (.snapshotReady(let k1, let p1), .snapshotReady(let k2, let p2)):
            return k1 == k2 && p1 == p2
        case (.clientAction(let a1), .clientAction(let a2)):
            return a1 == a2
        default:
            return false
        }
    }
}

extension ToolProgress {
    fileprivate func semanticallyEquals(_ other: ToolProgress) -> Bool {
        switch (self, other) {
        case (.bashLine(let a), .bashLine(let b)): return a == b
        case (.fileBytes(let aw, let at), .fileBytes(let bw, let bt)): return aw == bw && at == bt
        case (.generic(let a), .generic(let b)): return a == b
        default: return false
        }
    }
}

private func msEqual(_ a: Duration, _ b: Duration) -> Bool {
    let am = Int(a.components.seconds * 1_000) + Int(a.components.attoseconds / 1_000_000_000_000_000)
    let bm = Int(b.components.seconds * 1_000) + Int(b.components.attoseconds / 1_000_000_000_000_000)
    return am == bm
}
