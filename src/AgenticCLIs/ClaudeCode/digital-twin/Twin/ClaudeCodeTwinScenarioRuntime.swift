import Foundation

/// Shared turn execution for `fake-claude` and conformance tests.
public enum ClaudeCodeTwinScenarioRuntime: Sendable {

    public struct Context: Sendable {
        public var sessionID: String
        public var workspace: URL
        public var claudeDirectory: URL
        public var model: String
        public var permissionMode: String
        public var resumeSessionID: String?
        public var toolIndex: Int

        public init(sessionID: String,
                    workspace: URL,
                    claudeDirectory: URL,
                    model: String = "fake-claude",
                    permissionMode: String = "default",
                    resumeSessionID: String? = nil,
                    toolIndex: Int = 0) {
            self.sessionID = sessionID
            self.workspace = workspace
            self.claudeDirectory = claudeDirectory
            self.model = model
            self.permissionMode = permissionMode
            self.resumeSessionID = resumeSessionID
            self.toolIndex = toolIndex
        }

        public var store: ClaudeCodeTwinSessionStore {
            ClaudeCodeTwinSessionStore(sessionID: sessionID,
                                       workspace: workspace,
                                       claudeDirectory: claudeDirectory)
        }
    }

    public enum HookSink: Sendable {
        case runner(@Sendable (String, Data) throws -> Void)
        case none
    }

    /// Execute one scripted turn: hooks, transcript lines, and PTY frames.
    @discardableResult
    public static func execute(scenario: ClaudeCodeTwinScenario,
                               userPrompt: String,
                               context: inout Context,
                               hookSink: HookSink,
                               writePTY: (String) -> Void) throws -> String? {
        emitHook("UserPromptSubmit",
                 ClaudeCodeTwinHookEmitter.userPromptSubmit(sessionID: context.sessionID,
                                                            prompt: userPrompt,
                                                            context: hookContext(context)),
                 hookSink: hookSink)

        switch scenario {
        case .textOnly(let reply):
            try appendAssistant(reply, context: &context)
            emitStop(lastMessage: reply, context: context, hookSink: hookSink)
            writePTY(ClaudeCodeTwinPTYScript.promptReady)
            return reply

        case .thinkingThenReply(let thinking, let reply):
            try context.store.append(ClaudeCodeTwinTranscript.assistantThinkingLine(text: thinking))
            try appendAssistant(reply, context: &context)
            emitStop(lastMessage: reply, context: context, hookSink: hookSink)
            writePTY(ClaudeCodeTwinPTYScript.promptReady)
            return reply

        case .withBash(let command, let stdout, let exitCode, let reply):
            let toolID = ClaudeCodeTwinIdentifiers.toolUseID(index: context.toolIndex)
            context.toolIndex += 1
            emitHook("PreToolUse",
                     ClaudeCodeTwinHookEmitter.preToolUse(sessionID: context.sessionID,
                                                          toolUseID: toolID,
                                                          toolName: "Bash",
                                                          input: ["command": command],
                                                          needsPermission: false,
                                                          context: hookContext(context)),
                     hookSink: hookSink)
            try context.store.append(ClaudeCodeTwinTranscript.assistantToolUseLine(toolID: toolID,
                                                                                     tool: "Bash",
                                                                                     input: ["command": command]))
            try context.store.append(ClaudeCodeTwinTranscript.toolResultLine(toolID: toolID,
                                                                             text: stdout,
                                                                             isError: exitCode != 0))
            emitHook("PostToolUse",
                     ClaudeCodeTwinHookEmitter.postToolUse(sessionID: context.sessionID,
                                                           toolUseID: toolID,
                                                           toolName: "Bash",
                                                           output: stdout,
                                                           exitCode: Int(exitCode),
                                                           isError: exitCode != 0,
                                                           context: hookContext(context)),
                     hookSink: hookSink)
            try appendAssistant(reply, context: &context)
            emitStop(lastMessage: reply, context: context, hookSink: hookSink)
            writePTY(stdout + "\n" + ClaudeCodeTwinPTYScript.promptReady)
            return reply

        case .withEdit(let path, _, let reply):
            let toolID = ClaudeCodeTwinIdentifiers.toolUseID(index: context.toolIndex)
            context.toolIndex += 1
            emitHook("PreToolUse",
                     ClaudeCodeTwinHookEmitter.preToolUse(sessionID: context.sessionID,
                                                          toolUseID: toolID,
                                                          toolName: "Edit",
                                                          input: ["file_path": path],
                                                          needsPermission: false,
                                                          context: hookContext(context)),
                     hookSink: hookSink)
            emitHook("PostToolUse",
                     ClaudeCodeTwinHookEmitter.postToolUse(sessionID: context.sessionID,
                                                           toolUseID: toolID,
                                                           toolName: "Edit",
                                                           output: "updated",
                                                           context: hookContext(context)),
                     hookSink: hookSink)
            try appendAssistant(reply, context: &context)
            emitStop(lastMessage: reply, context: context, hookSink: hookSink)
            writePTY(ClaudeCodeTwinPTYScript.promptReady)
            return reply

        case .permissionPrompt(let tool, let summary, let reply):
            let toolID = ClaudeCodeTwinIdentifiers.toolUseID(index: context.toolIndex)
            context.toolIndex += 1
            emitHook("PreToolUse",
                     ClaudeCodeTwinHookEmitter.preToolUse(sessionID: context.sessionID,
                                                          toolUseID: toolID,
                                                          toolName: tool,
                                                          input: ["summary": summary],
                                                          needsPermission: true,
                                                          context: hookContext(context)),
                     hookSink: hookSink)
            writePTY("Allow \(tool)? 1 allow 2 allow always 3 deny\n")
            try appendAssistant(reply, context: &context)
            emitStop(lastMessage: reply, context: context, hookSink: hookSink)
            writePTY(ClaudeCodeTwinPTYScript.promptReady)
            return reply

        case .needsAuth(let url):
            writePTY("Visit \(url.absoluteString) to authenticate\n" + ClaudeCodeTwinPTYScript.promptReady)
            return nil

        case .usageOnly(let inputTokens, let outputTokens, let cost):
            try context.store.append(ClaudeCodeTwinTranscript.assistantUsageLine(inputTokens: inputTokens,
                                                                                 outputTokens: outputTokens,
                                                                                 costUSD: cost))
            emitStop(lastMessage: nil, context: context, hookSink: hookSink)
            writePTY(ClaudeCodeTwinPTYScript.promptReady)
            return nil

        case .crash(let partial):
            writePTY(partial)
            return nil

        case .workspaceTrust(let workspacePath):
            writePTY(ClaudeCodeTwinPTYScript.workspaceTrust(workspace: workspacePath))
            return nil

        case .resumeLatePrompt(let reply):
            writePTY(ClaudeCodeTwinPTYScript.statusWorking)
            writePTY(ClaudeCodeTwinPTYScript.promptReady)
            try appendAssistant(reply, context: &context)
            emitStop(lastMessage: reply, context: context, hookSink: hookSink)
            return reply

        case .resumeStalled:
            writePTY(ClaudeCodeTwinPTYScript.statusWorking)
            return nil

        case .swallowedEnter(let reply):
            writePTY(ClaudeCodeTwinPTYScript.unsubmittedPrompt(userPrompt))
            try appendAssistant(reply, context: &context)
            emitStop(lastMessage: reply, context: context, hookSink: hookSink)
            writePTY(ClaudeCodeTwinPTYScript.promptReady)
            return reply

        case .sequence(let scenarios):
            var last: String?
            for sub in scenarios {
                last = try execute(scenario: sub,
                                   userPrompt: userPrompt,
                                   context: &context,
                                   hookSink: hookSink,
                                   writePTY: writePTY)
            }
            return last
        }
    }

    public static func emitSessionStart(context: Context, hookSink: HookSink) {
        emitHook("SessionStart",
                 ClaudeCodeTwinHookEmitter.sessionStart(sessionID: context.sessionID,
                                                        project: context.workspace,
                                                        model: context.model,
                                                        permissionMode: context.permissionMode,
                                                        context: hookContext(context)),
                 hookSink: hookSink)
    }

    // MARK: - Private

    private static func hookContext(_ context: Context) -> ClaudeCodeTwinHookEmitter.Context {
        ClaudeCodeTwinHookEmitter.Context(sessionID: context.sessionID,
                                          workspace: context.workspace,
                                          claudeDirectory: context.claudeDirectory,
                                          permissionMode: context.permissionMode)
    }

    private static func appendAssistant(_ reply: String, context: inout Context) throws {
        try context.store.append(ClaudeCodeTwinTranscript.assistantTextLine(text: reply))
    }

    private static func emitStop(lastMessage: String?,
                                 context: Context,
                                 hookSink: HookSink) {
        emitHook("Stop",
                 ClaudeCodeTwinHookEmitter.stop(sessionID: context.sessionID,
                                                 lastAssistantMessage: lastMessage,
                                                 context: hookContext(context)),
                 hookSink: hookSink)
    }

    private static func emitHook(_ eventName: String, _ payload: Data, hookSink: HookSink) {
        guard case .runner(let run) = hookSink else { return }
        try? run(eventName, payload)
    }
}
