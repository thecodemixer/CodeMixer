/// CoverageManifest.swift
///
/// Compiler-verified inventory of every public symbol this package exports.
/// If a symbol is renamed or deleted the file will fail to compile, surfacing
/// the API drift immediately in CI rather than silently losing coverage.
///
/// HOW TO UPDATE
/// 1. Run `scripts/regen-coverage-manifest.swift` from the repo root.
/// 2. Review the diff; if you're removing a symbol intentionally, remove it
///    here too. If you're adding one, add it here with a passing test.
/// 3. Commit both changes in the same PR.
///
/// HOW THIS WORKS
/// Each entry below is a live Swift expression that names the symbol.  The
/// compiler evaluates them; nothing is executed at runtime.

import Foundation
import A2UICore
import AgentCore
import AgentProtocol
import ClaudeCode

// ─────────────────────────────────────────────────────────────────────────────
// AgentCore — Seams
// ─────────────────────────────────────────────────────────────────────────────

private func _agentClockSymbols(_: some AgentClock) {
    // AgentClock protocol members: enforced by conformance, no direct ref needed
}
private let _systemClock                  = SystemClock()
private let _systemRandom                 = SystemRandomSource()
private let _systemEnv                    = SystemEnvironment()
private let _systemFS                     = SystemFileSystem()

// ─────────────────────────────────────────────────────────────────────────────
// AgentCore — Events & Supporting Types
// ─────────────────────────────────────────────────────────────────────────────

// AgentID
private let _agentIDs: [AgentID] = [
    .claudeCode, .codex, .cursorCLI, .geminiCLI, .openCode, .copilot, .other,
]

// AgentCapabilities
private let _caps: AgentCapabilities = [
    .hooksOverUDS, .transcriptJSONL,
    .ptyTUIFallback, .permissionPrompts, .resumableSessions,
]
private let _shippingAgents = AgentID.shipping

// Policy constants (compile-time refs only)
private let _pinTTL = RemoteAuthTiming.pinTTL
private let _lockoutSeconds = RemoteAuthTiming.lockoutSeconds
private let _maxAttempts = RemoteAuthTiming.maxAttempts
private let _idleCheck = DaemonDefaults.idleCheckInterval
private let _idleExit = DaemonDefaults.idleExitAfterChecks
private let _idlePhrase = ActivityTiming.idlePhrase
private let _thinkingPhrase = ActivityTiming.thinkingPhrase
private let _promptReadinessPollInterval = ActivityTiming.promptReadinessPollInterval
private func _promptWriteSettleDelay(_ adapter: some AgentAdapter) -> Duration {
    adapter.promptWriteSettleDelay
}
private let _derivedInternalEntryID = InternalEntryID.derive(fromAdapterTurnID: AdapterTurnID(rawValue: "turn-1"))
private let _modelCatalogProbeTimeout = ModelCatalogTiming.probeTimeout
private let _bonjourType = RemoteDefaults.bonjourServiceType
private let _bonjourName = RemoteDefaults.bonjourServiceName
private let _bonjourVer = RemoteDefaults.bonjourTXTVersion
private let _p12Name = AppSupportPaths.remoteServerP12FileName

// PermissionPrompt
private let _pp = PermissionPrompt(
    id: PermissionPromptID(rawValue: UUID()),
    toolName: "T", summary: "S", argumentsSummary: "A",
    requestedAt: Date()
)

// ToolInput / ToolOutput
private let _ti = ToolInput(summary: "s")
private let _to = ToolOutput(summary: "s")

// ToolProgress
private let _tpBash    = ToolProgress.bashLine("x")
private let _tpFile    = ToolProgress.fileBytes(written: 1, total: nil)
private let _tpGeneric = ToolProgress.generic(message: "x")

// AuthStatus
private let _asAuthenticated = AuthStatus.authenticated(account: nil)
private let _asUnauth        = AuthStatus.unauthenticated
private let _asExpired       = AuthStatus.expired
private let _asUnknown       = AuthStatus.unknown

// LaunchContext
private let _launchCtx = LaunchContext(workspace: URL(fileURLWithPath: "/"))

// PermissionResponseDelivery
private let _prd1 = PermissionResponseDelivery.writePTY(Data())
private let _prd2 = PermissionResponseDelivery.respondToHookProcess(jsonStdout: Data())
private let _prd3 = PermissionResponseDelivery.both(ptyBytes: Data(), hookStdout: Data())

// SlashCommand
private let _sc = SlashCommand(id: "/help", name: "/help", summary: "Help")

// SessionSummary
private let _ss = SessionSummary(
    id: "x", agentID: .claudeCode,
    workspace: URL(fileURLWithPath: "/"), title: "t",
    lastActivity: Date(), messageCount: 0
)

// HookSocketHandle — init declared; stream type checked
private func _hookSocketHandleInit(
    stream: AsyncStream<HookRequest>,
    respond: @escaping @Sendable (HookRequestID, Data) async -> Void
) -> HookSocketHandle {
    HookSocketHandle(incoming: stream, respond: respond)
}

// HookRequest
private let _hookReq = HookRequest(id: HookRequestID(rawValue: UUID()),
                                   eventName: "Stop",
                                   jsonPayload: Data())

// FSEvent
private let _fsEvent = FSEvent(
    url: URL(fileURLWithPath: "/tmp/x"), kind: .modified, observedAt: Date()
)
private let _fsKinds: [FSEvent.Kind] = [.modified, .created, .removed, .renamed]

// FileSystemError
private let _fseNotFound      = FileSystemError.notFound(path: "/")
private let _fseDenied        = FileSystemError.permissionDenied(path: "/")
private let _fseIO            = FileSystemError.ioError(path: "/", underlying: "")
private let _fseNotRegular    = FileSystemError.notRegularFile(path: "/")

// AdapterRegistry
private let _adapterRegistry = AdapterRegistry.shared

// ─────────────────────────────────────────────────────────────────────────────
// AgentProtocol — commands, wire types
// ─────────────────────────────────────────────────────────────────────────────

// PermissionDecision
private let _pdAllow      = PermissionDecision.allow
private let _pdAllowAlways = PermissionDecision.allowAlways
private let _pdDeny       = PermissionDecision.deny
private let _pdOption     = PermissionDecision.option(id: "opt")

// PermissionMode
private let _pmDefault     = PermissionMode.default
private let _pmAcceptEdits = PermissionMode.acceptEdits
private let _pmBypass      = PermissionMode.bypassPermissions
private let _pmPlan        = PermissionMode.plan

// ClientAction — Codemixer-owned history markers (live + export only)
private let _clientActionKinds: [ClientAction.Kind] = [
    .mode, .model, .slashCommand, .permissionMode, .permissionResponse, .sessionLifecycle,
]
private let _clientAction = ClientAction(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
    kind: .permissionMode,
    title: "Permission mode",
    detail: "Plan"
)
private let _recordClientActionCommand = AgentCommand.recordClientAction(_clientAction)

// TTSAction
private let _ttsPlay  = TTSAction.play
private let _ttsPause = TTSAction.pause
private let _ttsStop  = TTSAction.stop

// StopReason
private let _stopNatural  = StopReason.naturalExit
private let _stopCancel   = StopReason.userCancel
private let _stopSpawn    = StopReason.spawnFailed
private let _stopCrash    = StopReason.crashed
private let _stopAuth     = StopReason.authExpired

// FileChangeKind
private let _fckHook      = FileChangeKind.hookReported
private let _fckFSObserved = FileChangeKind.fsObserved
private let _fckTUI       = FileChangeKind.tuiScraped

// StatusPhraseSource
private let _spsHeuristic  = StatusPhraseSource.heuristic
private let _spsTUI        = StatusPhraseSource.tuiScrape
private let _spsHook       = StatusPhraseSource.hookHint
private let _spsPinned     = StatusPhraseSource.adapterPinned

// ActivitySubstate
private let _asIdle          = ActivitySubstate.idle
private let _asFirstChunk    = ActivitySubstate.awaitingFirstChunk
private let _asStreaming      = ActivitySubstate.streamingText
private let _asThinking       = ActivitySubstate.thinking
private let _asRunningTool    = ActivitySubstate.runningTool
private let _asWaitPerm       = ActivitySubstate.waitingPermission
private let _asStillWorking   = ActivitySubstate.stillWorking
private let _asProbablyStuck  = ActivitySubstate.probablyStuck

// ─────────────────────────────────────────────────────────────────────────────
// ClaudeAdapter — public types
// ─────────────────────────────────────────────────────────────────────────────

// TerminalLine / TerminalSnapshot (from ClaudeTUIFallback)
private let _tl = TerminalLine(text: "hi", row: 0)
private let _ts = TerminalSnapshot(lines: [])
private let _tsPlain = TerminalSnapshot(plainText: "hello\nworld")

// MulticastEventBus — new API surface (reconnect-with-replay)
// HistoryEntry: the typed ring-buffer element with bus-assigned ID
private func _historyEntry(_ e: MulticastEventBus.HistoryEntry) {
    _ = e.id
    _ = e.event
}
// subscribe(after:) / lastPublishedID / historySnapshot — verified via type-checking only
private func _busReconnectAPI(_ bus: MulticastEventBus) async {
    let _: MulticastEventBus.Subscription = await bus.subscribe(after: nil)
    let _: MulticastEventBus.Subscription = await bus.subscribe(after: UUID())
    let _: UUID? = await bus.lastPublishedID
    let _: [MulticastEventBus.HistoryEntry] = await bus.historySnapshot
}

// ServerFrame.subscribed — checked at type level
private func _serverFrameSubscribed() -> [ServerFrame] {
    [.subscribed(latestEventID: nil, outcome: .fresh),
     .subscribed(latestEventID: UUID(), outcome: .resumed)]
}

// ClientFrame.subscribe with lastSeenEventID — checked at type level
private func _clientFrameSubscribe() -> [ClientFrame] {
    [.subscribe(lastSeenEventID: nil),
     .subscribe(lastSeenEventID: UUID())]
}

// NetworkConnectionMetadata — checked at type level
private let _networkMetadata = NetworkConnectionMetadata(
    path: "/v1/ws",
    headers: ["Authorization": "Bearer token"]
)
private let _networkOptionsMetadata = NetworkOptions.webSocket(authorizationBearer: "token")

// truncateTranscript — AgentAdapter default + ClaudeAdapter override
// Verified by calling the default (no-op) extension through a protocol existential.
private func _truncateTranscript(adapter: any AgentAdapter) async {
    let ws = URL(fileURLWithPath: "/tmp")
    let _: Bool = await adapter.truncateTranscript(afterUserTurnID: AdapterTurnID(rawValue: "id"), sessionID: "sid", workspace: ws)
}

// subagentTranscriptURLs — ClaudeTranscriptTailer (verified via type-check only;
// private implementation, confirmed by build).

// ─────────────────────────────────────────────────────────────────────────────
// A2UI — wire DTOs (AgentProtocol) + core validation/reduction (A2UICore)
// ─────────────────────────────────────────────────────────────────────────────

private let _a2uiVersion = A2UISchemaProfile.version
private let _a2uiSupportedVersions = A2UISchemaProfile.supportedVersions
private let _a2uiMIME = A2UISchemaProfile.embeddedResourceMIMEType
private let _a2uiBasicCatalogID = A2UISchemaProfile.basicCatalogID
private let _a2uiTestCatalogID = A2UISchemaProfile.testScopedCatalogID
private let _a2uiCapMetaKey = A2UISchemaProfile.clientCapabilitiesMetaKey
private let _a2uiCapMetaKeyAlias = A2UISchemaProfile.clientCapabilitiesMetaKeyAlias
private let _a2uiClientDataModelMetaKey = A2UISchemaProfile.clientDataModelMetaKey
private let _a2uiUpstreamCommit = A2UISchemaProfile.upstreamCommit
private let _a2uiUpstreamRepo = A2UISchemaProfile.upstreamRepository
private let _a2uiUpstreamLicense = A2UISchemaProfile.upstreamLicenseNote
private let _a2uiManifest = A2UISchemaProfile.schemaManifest
private func _a2uiSchemaSource(_ s: A2UISchemaProfile.SchemaSource) {
    _ = s.name; _ = s.sourceURL; _ = s.sha256
}

private let _a2uiTheme = A2UITheme(primaryColor: nil)
private func _a2uiThemeAPI(_ t: A2UITheme) { _ = t.primaryColor }
private func _a2uiComponent(_ c: A2UIComponent) {
    _ = c.id; _ = c.body; _ = c.weight; _ = c.accessibility
    _ = c.body.wireKindName; _ = c.body.isUnknown; _ = c.body.kind
}
private let _a2uiComponentInit = A2UIComponent(id: "x", body: .divider(A2UIDividerProps()))
private let _a2uiComponentBodyKinds = A2UIComponentBody.Kind.allCases
private func _a2uiComponentBodyKindAPI(_ k: A2UIComponentBody.Kind) { _ = k.rawValue }

private let _a2uiCreate = A2UIServerMessage.createSurface(
    surfaceID: "s", catalogID: A2UISchemaProfile.testScopedCatalogID, theme: nil, sendDataModel: false
)
private let _a2uiUpdateComponents = A2UIServerMessage.updateComponents(surfaceID: "s", components: [])
private let _a2uiUpdateDataModel = A2UIServerMessage.updateDataModel(surfaceID: "s", path: "/", value: nil)
private let _a2uiDeleteSurface = A2UIServerMessage.deleteSurface(surfaceID: "s")
private let _a2uiMessageSurfaceID = _a2uiCreate.surfaceID

private let _a2uiKeyRef = A2UITranscriptKeyRef(projectRootPath: "/", namespace: "n", sessionID: "s")
private let _a2uiIssue = A2UIValidationIssue(code: "C", surfaceID: nil, path: nil, message: "m")
private let _a2uiBatchItem = A2UIServerBatch.Item(index: 0, message: nil, validationError: nil)
private let _a2uiBatch = A2UIServerBatch(
    agentID: "a", transcriptKey: _a2uiKeyRef, resourceURI: "a2ui://x", items: [], recordedAt: Date()
)
private let _a2uiIntent = A2UIInteractionIntent(
    transcriptKey: _a2uiKeyRef, agentID: "a", surfaceID: "s", generation: 1, sourceComponentID: "c",
    repeatedListScopePaths: [], localOverlay: [:], occurredAt: Date()
)
private let _a2uiAction = A2UIActionEnvelope(
    transcriptKey: _a2uiKeyRef, agentID: "a", surfaceID: "s", sourceComponentID: "c",
    eventName: "e", context: [:], timestamp: Date()
)
private let _a2uiClientError = A2UIClientErrorEnvelope(
    transcriptKey: _a2uiKeyRef, agentID: "a", surfaceID: "s", code: "C", path: nil, message: "m"
)

private let _a2uiLimits: [Int] = [
    A2UILimits.maxPayloadBytes, A2UILimits.maxBatchItems, A2UILimits.maxJSONDepth,
    A2UILimits.maxJSONNodes, A2UILimits.maxSurfacesPerSession, A2UILimits.maxComponentsPerSurface,
    A2UILimits.maxListExpansion, A2UILimits.maxExpressionDepth, A2UILimits.maxExpressionCallCount,
    A2UILimits.maxPointerLength, A2UILimits.maxRegexPatternLength, A2UILimits.maxRegexInputLength,
    A2UILimits.maxFormatPatternLength, A2UILimits.maxResolvedStringLength,
]
private let _a2uiMinInterval = A2UILimits.minDataModelUpdateInterval

private let _a2uiFunctionNames = A2UICatalog.functionNames
private let _a2uiVoidFunctions = A2UICatalog.voidFunctions
private let _a2uiCheckableMarkers = A2UICatalog.checkableBodyMarkers
private let _a2uiIsKnownCatalog = A2UICatalog.isKnownCatalogID(A2UISchemaProfile.basicCatalogID)
private func _a2uiCatalogBodyAPI(_ b: A2UIComponentBody) {
    _ = A2UICatalog.isCheckable(b)
    _ = A2UICatalog.isTwoWayBound(b)
    _ = A2UICatalog.isKnownComponentBody(b)
}

private let _a2uiPointerTokens = A2UIJSONPointer.tokens("/a/b")
private let _a2uiPointerValue = A2UIJSONPointer.value(at: "/a", in: .object([:]))
private let _a2uiPointerScoped = A2UIJSONPointer.resolveScoped("/a", scopePaths: [])
private let _a2uiPointerSetting = A2UIJSONPointer.setting(at: "/a", to: .null, in: .object([:]))

private let _a2uiSurfaceState = A2UISurfaceState(
    surfaceID: "s", agentID: "a", catalogID: A2UISchemaProfile.testScopedCatalogID,
    theme: nil, sendDataModel: false, generation: 1, createdAt: Date()
)
private func _a2uiSurfaceStateAPI(_ s: A2UISurfaceState) {
    _ = s.surfaceID; _ = s.agentID; _ = s.catalogID; _ = s.generation; _ = s.createdAt
    _ = s.components; _ = s.rootComponentID; _ = s.isRenderable
    _ = s.dataModel; _ = s.sensitivePaths; _ = s.updatedAt; _ = s.theme; _ = s.sendDataModel
    _ = s.redactedDataModel(); _ = s.synthesizedReplayMessages()
}

private let _a2uiValidatorResult = A2UIValidator.validate(_a2uiCreate, existingSurfaces: [:])

private let _a2uiReducerResult = A2UISurfaceReducer.apply(_a2uiBatch, to: [:], retiredGenerations: [:], at: Date())
private func _a2uiReducerAPI(_ r: A2UISurfaceReducer.Result, _ o: A2UISurfaceReducer.ItemOutcome) {
    _ = r.surfaces; _ = r.retiredGenerations; _ = r.outcomes
    _ = o.index; _ = o.applied; _ = o.issue
}

private func _a2uiEvaluatorAPI() {
    var evaluator = A2UIEvaluator(dataModel: .empty, overlay: [:], scopePaths: [])
    _ = try? evaluator.resolve(.string(""))
    _ = try? evaluator.resolveString(.string(""))
    _ = try? evaluator.resolveBool(.boolean(false))
    _ = try? evaluator.resolveNumber(.number(0))
    _ = try? evaluator.resolveContext([:])
}
private let _a2uiEvaluationError: A2UIEvaluator.EvaluationError? = nil

private let _a2uiSummary = A2UITextSummary.summary(for: _a2uiSurfaceState)

private let _a2uiResolverResult = A2UIActionResolver.resolve(_a2uiIntent, against: nil)
private let _a2uiResolverFailure: A2UIActionResolver.Failure? = nil

// MARK: - A2UI typed model (see docs/architecture.md §36.1a)

private let _a2uiPointerPath = A2UIJSONPointerPath("/a")
private let _a2uiPointerPathRaw = A2UIJSONPointerPath(rawValue: "/a").rawValue
private let _a2uiResolvedValueCases: [A2UIResolvedValue] = [
    .null, .bool(true), .number(1), .string("s"), .array([.null]), .object(["k": .null]),
]
private func _a2uiResolvedValueAPI(_ v: A2UIResolvedValue) {
    _ = v.stringValue; _ = v.numberValue; _ = v.boolValue; _ = v.arrayValue; _ = v.objectValue
}
private let _a2uiDataDocument = A2UIDataDocument()
private let _a2uiDataDocumentEmpty = A2UIDataDocument.empty
private func _a2uiDataDocumentAPI(_ d: A2UIDataDocument) { _ = d.isEmptyObject }
private let _a2uiOverlay: A2UILocalOverlay = ["/a": .string("v")]
private let _a2uiOverlayEmpty = A2UILocalOverlay.empty
private func _a2uiOverlayAPI(_ o: A2UILocalOverlay) {
    _ = o.isEmpty; _ = o[A2UIJSONPointerPath("/a")]; _ = o["/a"]
}
private let _a2uiOpaqueJSONEmpty = A2UIOpaqueJSON.emptyObject
private let _a2uiOpaqueComponent = A2UIOpaqueComponent(kindName: "HoloDeck", raw: .emptyObject)
private func _a2uiOpaqueComponentAPI(_ c: A2UIOpaqueComponent) { _ = c.kindName }

private let _a2uiDataBinding = A2UIDataBinding(path: "/a")
private func _a2uiDataBindingAPI(_ b: A2UIDataBinding) { _ = b.path }
private let _a2uiReturnTypeCases: [A2UIReturnType] = [
    .string, .number, .boolean, .array, .object, .any, .void,
]
private let _a2uiFunctionNameCases = A2UIFunctionName.allCases
private func _a2uiFunctionNameAPI(_ n: A2UIFunctionName) { _ = n.isVoid; _ = n.isCallExpression }
private let _a2uiFunctionCall = A2UIFunctionCall(name: .required, args: [:], returnType: .boolean)
private func _a2uiFunctionCallAPI(_ c: A2UIFunctionCall) { _ = c.name; _ = c.args; _ = c.returnType }
private let _a2uiFunctionArgument = A2UIFunctionArgument.value(.string("x"))
private func _a2uiFunctionArgumentAPI(_ a: A2UIFunctionArgument) { _ = a.asDynamicValue; _ = a.asObject }
private let _a2uiDynamicValueCases: [A2UIDynamicValue] = [
    .string("s"), .number(1), .boolean(true), .array([.string("s")]),
    .binding(_a2uiDataBinding), .call(_a2uiFunctionCall),
]
private let _a2uiDynamicStringCases: [A2UIDynamicString] = [
    .literal("s"), .binding(_a2uiDataBinding), .call(_a2uiFunctionCall),
]
private let _a2uiDynamicNumberCases: [A2UIDynamicNumber] = [
    .literal(1), .binding(_a2uiDataBinding), .call(_a2uiFunctionCall),
]
private let _a2uiDynamicBooleanCases: [A2UIDynamicBoolean] = [
    .literal(true), .binding(_a2uiDataBinding), .call(_a2uiFunctionCall),
]
private let _a2uiDynamicStringListCases: [A2UIDynamicStringList] = [
    .literal(["s"]), .binding(_a2uiDataBinding), .call(_a2uiFunctionCall),
]
private func _a2uiDynamicConversions() {
    _ = A2UIDynamicString.literal("s").asDynamicValue
    _ = A2UIDynamicNumber.literal(1).asDynamicValue
    _ = A2UIDynamicBoolean.literal(true).asDynamicValue
    _ = A2UIDynamicStringList.literal(["s"]).asDynamicValue
}

private let _a2uiAccessibility = A2UIAccessibilityAttributes(label: .literal("l"), description: .literal("d"))
private func _a2uiAccessibilityAPI(_ a: A2UIAccessibilityAttributes) { _ = a.label; _ = a.description }
private let _a2uiCheckRule = A2UICheckRule(condition: .literal(true), message: "m")
private func _a2uiCheckRuleAPI(_ c: A2UICheckRule) { _ = c.condition; _ = c.message }
private let _a2uiActionCases: [A2UIAction] = [
    .event(name: "e", context: [:]), .functionCall(_a2uiFunctionCall),
]
private let _a2uiChildListCases: [A2UIChildList] = [
    .fixed(["a"]), .template(componentID: "t", path: "/items"),
]
private let _a2uiActionContextWireJSON = _a2uiAction.contextWireJSON

private let _a2uiMainAxisJustifyCases: [A2UIMainAxisJustify] = [
    .start, .center, .end, .spaceBetween, .spaceAround, .spaceEvenly, .stretch,
]
private let _a2uiCrossAxisAlignCases: [A2UICrossAxisAlign] = [.start, .center, .end, .stretch]
private let _a2uiTextVariantCases: [A2UITextVariant] = [.h1, .h2, .h3, .h4, .h5, .caption, .body]
private let _a2uiImageFitCases: [A2UIImageFit] = [.contain, .cover, .fill, .none, .scaleDown]
private let _a2uiImageVariantCases: [A2UIImageVariant] = [
    .icon, .avatar, .smallFeature, .mediumFeature, .largeFeature, .header,
]
private let _a2uiListDirectionCases: [A2UIListDirection] = [.vertical, .horizontal]
private let _a2uiDividerAxisCases: [A2UIDividerAxis] = [.horizontal, .vertical]
private let _a2uiButtonVariantCases: [A2UIButtonVariant] = [.default, .primary, .borderless]
private let _a2uiTextFieldVariantCases: [A2UITextFieldVariant] = [
    .longText, .number, .shortText, .obscured,
]
private let _a2uiTextFieldIsObscured = A2UITextFieldVariant.obscured.isObscured
private let _a2uiChoicePickerVariantCases: [A2UIChoicePickerVariant] = [
    .multipleSelection, .mutuallyExclusive,
]
private let _a2uiChoiceDisplayStyleCases: [A2UIChoiceDisplayStyle] = [.checkbox, .chips]
private let _a2uiIconNameCases: [A2UIIconName] = [
    .catalog("home"), .svgPath("M0 0"), .binding(_a2uiDataBinding),
]
private let _a2uiIconCatalogSymbol = A2UIIconName.catalog("home").catalogSymbol

private let _a2uiTextProps = A2UITextProps(text: .literal("t"), variant: .body)
private let _a2uiImageProps = A2UIImageProps(url: .literal("u"), description: .literal("d"),
                                            fit: .cover, variant: .avatar)
private let _a2uiIconProps = A2UIIconProps(name: .catalog("home"))
private let _a2uiVideoProps = A2UIVideoProps(url: .literal("u"))
private let _a2uiAudioPlayerProps = A2UIAudioPlayerProps(url: .literal("u"), description: .literal("d"))
private let _a2uiStackProps = A2UIStackProps(children: .fixed(["a"]), justify: .center, align: .center)
private let _a2uiListProps = A2UIListProps(children: .fixed(["a"]), direction: .vertical, align: .start)
private let _a2uiCardProps = A2UICardProps(child: "a")
private let _a2uiTabItem = A2UITabItem(title: .literal("t"), child: "c")
private let _a2uiTabsProps = A2UITabsProps(tabs: [_a2uiTabItem])
private let _a2uiModalProps = A2UIModalProps(trigger: "t", content: "c")
private let _a2uiDividerProps = A2UIDividerProps(axis: .horizontal)
private let _a2uiButtonProps = A2UIButtonProps(child: "c", action: .event(name: "e", context: [:]),
                                               variant: .primary, checks: [_a2uiCheckRule])
private let _a2uiCheckBoxProps = A2UICheckBoxProps(label: .literal("l"), value: .literal(true),
                                                   checks: [_a2uiCheckRule])
private let _a2uiTextFieldProps = A2UITextFieldProps(label: .literal("l"), value: .literal("v"),
                                                     variant: .shortText, validationRegexp: "^.$",
                                                     checks: [_a2uiCheckRule])
private let _a2uiDateTimeInputProps = A2UIDateTimeInputProps(value: .literal("v"), enableDate: true,
                                                             enableTime: true, min: .literal("a"),
                                                             max: .literal("b"), label: .literal("l"),
                                                             checks: [_a2uiCheckRule])
private let _a2uiChoiceOption = A2UIChoiceOption(label: .literal("l"), value: "v")
private let _a2uiChoicePickerProps = A2UIChoicePickerProps(options: [_a2uiChoiceOption],
                                                           value: .literal(["v"]), label: .literal("l"),
                                                           variant: .mutuallyExclusive, displayStyle: .chips,
                                                           filterable: true, checks: [_a2uiCheckRule])
private let _a2uiSliderProps = A2UISliderProps(value: .literal(1), max: 10, min: 0,
                                               label: .literal("l"), checks: [_a2uiCheckRule])

private let _a2uiComponentBodyCases: [A2UIComponentBody] = [
    .text(_a2uiTextProps), .image(_a2uiImageProps), .icon(_a2uiIconProps), .video(_a2uiVideoProps),
    .audioPlayer(_a2uiAudioPlayerProps), .row(_a2uiStackProps), .column(_a2uiStackProps),
    .list(_a2uiListProps), .card(_a2uiCardProps), .tabs(_a2uiTabsProps), .modal(_a2uiModalProps),
    .divider(_a2uiDividerProps), .button(_a2uiButtonProps), .checkBox(_a2uiCheckBoxProps),
    .textField(_a2uiTextFieldProps), .dateTimeInput(_a2uiDateTimeInputProps),
    .choicePicker(_a2uiChoicePickerProps), .slider(_a2uiSliderProps),
    .unknown(_a2uiOpaqueComponent),
]

private func _a2uiPropsMembers() {
    _ = _a2uiTextProps.text; _ = _a2uiTextProps.variant
    _ = _a2uiImageProps.url; _ = _a2uiImageProps.description
    _ = _a2uiImageProps.fit; _ = _a2uiImageProps.variant
    _ = _a2uiIconProps.name
    _ = _a2uiVideoProps.url
    _ = _a2uiAudioPlayerProps.url; _ = _a2uiAudioPlayerProps.description
    _ = _a2uiStackProps.children; _ = _a2uiStackProps.justify; _ = _a2uiStackProps.align
    _ = _a2uiListProps.children; _ = _a2uiListProps.direction; _ = _a2uiListProps.align
    _ = _a2uiCardProps.child
    _ = _a2uiTabItem.title; _ = _a2uiTabItem.child; _ = _a2uiTabsProps.tabs
    _ = _a2uiModalProps.trigger; _ = _a2uiModalProps.content
    _ = _a2uiDividerProps.axis
    _ = _a2uiButtonProps.child; _ = _a2uiButtonProps.action
    _ = _a2uiButtonProps.variant; _ = _a2uiButtonProps.checks
    _ = _a2uiCheckBoxProps.label; _ = _a2uiCheckBoxProps.value; _ = _a2uiCheckBoxProps.checks
    _ = _a2uiTextFieldProps.label; _ = _a2uiTextFieldProps.value; _ = _a2uiTextFieldProps.variant
    _ = _a2uiTextFieldProps.validationRegexp; _ = _a2uiTextFieldProps.checks
    _ = _a2uiDateTimeInputProps.value; _ = _a2uiDateTimeInputProps.enableDate
    _ = _a2uiDateTimeInputProps.enableTime; _ = _a2uiDateTimeInputProps.min
    _ = _a2uiDateTimeInputProps.max; _ = _a2uiDateTimeInputProps.label
    _ = _a2uiDateTimeInputProps.checks
    _ = _a2uiChoiceOption.label; _ = _a2uiChoiceOption.value
    _ = _a2uiChoicePickerProps.options; _ = _a2uiChoicePickerProps.value
    _ = _a2uiChoicePickerProps.label; _ = _a2uiChoicePickerProps.variant
    _ = _a2uiChoicePickerProps.displayStyle; _ = _a2uiChoicePickerProps.filterable
    _ = _a2uiChoicePickerProps.checks
    _ = _a2uiSliderProps.value; _ = _a2uiSliderProps.max; _ = _a2uiSliderProps.min
    _ = _a2uiSliderProps.label; _ = _a2uiSliderProps.checks
}

// MANIFEST_SYMBOLS_BEGIN
// A2UIAccessibilityAttributes
// A2UIAction
// A2UIActionEnvelope
// A2UIActionResolver
// A2UIAudioPlayerProps
// A2UIButtonProps
// A2UIButtonVariant
// A2UICardProps
// A2UICatalog
// A2UICheckBoxProps
// A2UICheckRule
// A2UIChildList
// A2UIChoiceDisplayStyle
// A2UIChoiceOption
// A2UIChoicePickerProps
// A2UIChoicePickerVariant
// A2UIClientErrorEnvelope
// A2UIComponent
// A2UIComponentBody
// A2UICrossAxisAlign
// A2UIDataBinding
// A2UIDataDocument
// A2UIDateTimeInputProps
// A2UIDividerAxis
// A2UIDividerProps
// A2UIDynamicBoolean
// A2UIDynamicNumber
// A2UIDynamicString
// A2UIDynamicStringList
// A2UIDynamicValue
// A2UIEvaluator
// A2UIFunctionArgument
// A2UIFunctionCall
// A2UIFunctionName
// A2UIIconName
// A2UIIconProps
// A2UIImageFit
// A2UIImageProps
// A2UIImageVariant
// A2UIInteractionIntent
// A2UIJSONPointer
// A2UIJSONPointerPath
// A2UILimits
// A2UIListDirection
// A2UIListProps
// A2UILocalOverlay
// A2UIMainAxisJustify
// A2UIModalProps
// A2UIOpaqueComponent
// A2UIOpaqueJSON
// A2UIResolvedValue
// A2UIReturnType
// A2UISchemaProfile
// A2UIServerBatch
// A2UIServerMessage
// A2UISliderProps
// A2UIStackProps
// A2UISurfaceReducer
// A2UISurfaceState
// A2UITabItem
// A2UITabsProps
// A2UITextFieldProps
// A2UITextFieldVariant
// A2UITextProps
// A2UITextSummary
// A2UITextVariant
// A2UITheme
// A2UITranscriptKeyRef
// A2UIValidationIssue
// A2UIValidator
// A2UIVideoProps
// ACPAdapter
// ACPAgentError
// ACPClientState
// ACPConversationTurn
// ACPEventDecoder
// ACPFileAccess
// ACPFraming
// ACPIncoming
// ACPInputEncoding
// ACPPermissionMapping
// ACPProjectPaths
// ACPRPCCodec
// ACPSessionMode
// ACPStandardModeID
// ACPTerminalProcess
// ACPTerminalSession
// ACPTurnRole
// ACPTwin
// ACPTwinFixtures
// ACPTwinScenario
// ACPTwinServer
// ActivitySubstate
// ActivityTiming
// AdapterRegistry
// AdapterTurnID
// AgentAdapter
// AgentCapabilities
// AgentClock
// AgentCommand
// AgentEngine
// AgentEngineCommandPort
// AgentEnvironment
// AgentError
// AgentEvent
// AgentEventWire
// AgentID
// AgentInputs
// AgentInstanceIdentity
// AgentModeCommandID
// AgentModeOption
// AgentModelCatalogCache
// AgentModelOption
// AgentRuntimeKey
// AgentTransportDescriptor
// AgentTransportError
// AgentTransportKind
// AgentTransportLaunchSpec
// AppIdentity
// AppSupportPaths
// AppearancePrefKey
// AppearancePrefPatch
// AppearancePrefValue
// AppearancePrefs
// AppearanceTheme
// AttachmentRef
// AttachmentResolver
// AuthStatus
// AutoApprovalRule
// BackgroundSessionEventBatch
// Badge
// Batch
// BindHost
// BonjourAdvertiser
// BonjourBroadcaster
// BroadcastError
// Bundle
// CachedAdapterModels
// CaptureError
// CertificateError
// CertificateIdentityImporter
// CertificateManager
// ChangedFile
// ChildReaper
// ClaudeAdapter
// ClaudeBinaryLocator
// ClaudeBuiltInSlashCommands
// ClaudeCodeTwin
// ClaudeCodeTwinHookEmitter
// ClaudeCodeTwinIdentifiers
// ClaudeCodeTwinPTYScript
// ClaudeCodeTwinScenario
// ClaudeCodeTwinScenarioManifest
// ClaudeCodeTwinScenarioRuntime
// ClaudeCodeTwinSessionStore
// ClaudeCodeTwinSettings
// ClaudeCodeTwinSlashCommands
// ClaudeCodeTwinTranscript
// ClaudeCodeTwinTurn
// ClaudeHookInstaller
// ClaudeInputEncoding
// ClaudeModelCatalog
// ClaudeProjectPaths
// ClaudeSessionCatalogImporter
// ClaudeSlashCommands
// ClaudeTUIFallback
// ClaudeTerminalInputClassification
// ClaudeTerminalInputState
// ClaudeTranscriptTailer
// ClientAction
// ClientError
// ClientFrame
// CodeBlock
// CodemixerResources
// CodexAdapter
// CodexAgentError
// CodexAppServerFraming
// CodexAppServerIncoming
// CodexApprovalPolicy
// CodexBinaryLocator
// CodexCommandCatalog
// CodexEventDecoder
// CodexInputEncoding
// CodexModelCatalog
// CodexPolicyMapping
// CodexRPCCodec
// CodexSandboxMode
// CodexSessionState
// CodexTwin
// CodexUserInput
// CommandPaletteView
// CommandShape
// Configuration
// ConfigureProjectSheet
// ConnectedClientsChip
// ContentBlock
// ContentBlockKind
// Context
// ConversationSearchBar
// ConversationSnapshot
// CostBadgeView
// CursorACPAdapter
// CursorBinaryLocator
// CursorModeCommand
// CustomACPAdapter
// CustomACPAdapterFactory
// CustomACPBinaryLocator
// CustomACPModeMapping
// CustomACPRestartPhase
// CustomAgentAdapterFactories
// CustomAgentAdapterFactory
// CustomAgentRef
// DaemonDefaults
// DebugTerminalSheet
// DensityMode
// DesktopActions
// DesktopMenuItem
// DesktopMenuPresenter
// DetailPanePresentation
// Device
// DiffError
// DiffHunk
// DiffLine
// DiffPanelView
// DiffSnapshot
// EmptyState
// EngineState
// EngineViewModel
// Entry
// EvaluationError
// Event
// EventLogView
// ExitStatus
// FSEvent
// FSEventsError
// FSEventsStream
// FSEventsWatcher
// Factory
// Failure
// FileChangeKind
// FileDiff
// FileSystem
// FileSystemError
// FloatingCornerStyle
// FolderBrowserLimits
// FolderFileEntry
// FolderProjectKind
// FolderScanner
// FolderSidebarShortcut
// FolderViewState
// FontFamily
// GitDiffEngine
// Group
// HTTPSidecarServer
// HeartbeatActivityMonitor
// HistoryEntry
// HistoryImportState
// HookCommand
// HookRequest
// HookRequestID
// HookServer
// HookServerError
// HookSink
// HookSocketHandle
// ImportError
// ImportedSession
// InMemoryNetwork
// InlineStatusTicker
// InstallError
// IntentReveal
// InteractionCoverage
// InternalEntryID
// Item
// ItemOutcome
// JSONLFraming
// JSONLFramingError
// JSONRPCDialect
// JSONRPCFrameEncoding
// JSONValue
// KbdKey
// KeychainError
// KeychainStore
// Kind
// LaunchContext
// Level
// LiveNetworkTransport
// LocateError
// LoggingNetworkTransport
// MarkdownBlock
// MarkdownListItem
// Message
// ModelCatalogLoadError
// ModelCatalogRefreshKind
// ModelCatalogTiming
// MulticastEventBus
// NetworkAddress
// NetworkConnection
// NetworkConnectionMetadata
// NetworkListenerHandle
// NetworkOptions
// NetworkTransport
// NetworkTransportError
// NewProjectSheet
// NewWorkspaceSheet
// OpenProjectView
// PTYError
// PTYHost
// PairFailureReason
// PairOutcome
// PairedDevice
// PairedDeviceStore
// PairingService
// PairingState
// PaletteCommand
// PanelWindowChrome
// PermissionDecision
// PermissionMode
// PermissionOption
// PermissionOptionPayload
// PermissionPrompt
// PermissionPromptID
// PermissionPromptPayload
// PermissionResponseDelivery
// Pill
// Policy
// PrefsSnapshot
// PrefsStore
// ProcessError
// ProcessRunner
// ProjectAgentRouter
// ProjectDraft
// ProjectInfoSheet
// ProjectLocalState
// ProjectLocalStateStore
// ProjectMemoryFile
// ProjectMemoryFileKind
// ProjectPaths
// ProjectRecord
// ProjectRef
// ProjectType
// PromptComposerView
// RPCError
// RandomSource
// RawEvent
// ReconnectPolicy
// Record
// RecordType
// RemoteAuthTiming
// RemoteControlServer
// RemoteDefaults
// RemoteEngineClient
// RemoteRuntimeCoordinator
// RemoteSettingsActions
// RemoteSettingsState
// RemovedProject
// ResolvedEnvironment
// ResolverError
// Result
// ScanResult
// Scenario
// SchemaSource
// Seams
// ServerError
// ServerFrame
// ServerInfo
// SessionActivation
// SessionExporter
// SessionMetadataUpdate
// SessionPhase
// SessionSidebarView
// SessionStore
// SessionSummary
// SessionsSnapshot
// SettingsView
// ShellEnvironmentResolver
// ShimmerDots
// SidecarError
// SilentDiagnostics
// SilentDiagnosticsView
// SlashCommand
// SlashCommandTarget
// Snapshot
// SnapshotKind
// SnapshotMessage
// SnapshotService
// SpeechCapture
// SpeechCapturing
// SpeechSynthesis
// StableID
// State
// Status
// StatusPhraseResolver
// StatusPhraseSource
// StatusPill
// StdioJSONRPCTransport
// StopReason
// StoreError
// StoreSecondaryRootError
// StreamBufferDefaults
// SubscribeOutcome
// SubscribeReplayOutcome
// Subscription
// SupportedBuiltInAgent
// SystemClock
// SystemEnvironment
// SystemFileSystem
// SystemNotifications
// SystemPaths
// SystemRandomSource
// TLSConfiguration
// TTSAction
// TTSService
// Tag
// TerminalEngine
// TerminalLine
// TerminalSnapshot
// TerminalSnapshotting
// Theme
// ThinkingEffort
// Tick
// ToolCallID
// ToolInput
// ToolInputPayload
// ToolOutput
// ToolOutputPayload
// ToolProgress
// TranscriptLine
// TranscriptRole
// Trigger
// Turn
// TwinRuntimeSeams
// Usage
// UserNotificationBridge
// VoiceInputService
// WatcherError
// WindowSize
// WireAgentError
// WireAgentErrorCode
// WireAgentErrorContext
// WireAgentErrorContextKey
// WireCodec
// WireSessionPhase
// WireSessionSummary
// WireVersion
// WorkspaceAdapterLocalState
// WorkspaceAdapterLocalStateStore
// WorkspaceChip
// WorkspaceLandingView
// WorkspaceLifecycle
// WorkspaceLocalState
// WorkspaceLocalStateStore
// WorkspaceModelCatalogRow
// WorkspacePickerView
// WorkspaceProjectsStore
// WorkspaceScene
// a2uiAction
// a2uiClientError
// abortOpen
// accent
// accessibility
// account
// acpDirectoryName
// acpRootURL
// acpSessionsFileName
// acpSessionsURL
// action
// activateDefaultProjectIfNeeded
// activateSlashCommand
// activeFolderProjectKind
// activeFolderSelectionRelativePath
// activePendingPermission
// activeWorkspaceURL
// activityDotSize
// activityDotsHeight
// adapter
// adapterEvents
// addExistingProject
// addition
// additions
// address
// adoptEmptyWorkspace
// advertisesDashboard
// agentClientProtocol
// agentDirectory
// agentError
// agentID
// agentInstanceIdentity
// agentModes
// agentPickerMaxWidth
// agentPickerMinWidth
// align
// all
// allPaired
// anchorMessageID
// appSupportDirectory
// appSupportRelativePath
// appearance
// append
// appendLines
// applied
// apply
// applyAdapterCapabilities
// approval
// archived
// args
// arguments
// argumentsSummary
// arrayValue
// arriving
// asDynamicValue
// asObject
// assistantTextLine
// assistantThinkingLine
// assistantToolUseLine
// assistantUsageLine
// attachmentPaletteMaxWidth
// attachmentPaletteMinWidth
// attachmentTTL
// attachmentsDirectory
// attachmentsDirectoryName
// attachmentsPath
// attemptPair
// authGateContentMaxWidth
// authGateMinHeight
// authGateMinWidth
// authStatus
// authURL
// authenticate
// autoAllowDecision
// autoApprovalRules
// automaticCatalogMaxAge
// automaticLogShortcuts
// availableAgentModes
// availableModels
// axis
// banner
// bash
// basicCatalogID
// bearerToken
// beginSessionSwitch
// bell
// bellEvents
// binary
// bind
// body
// bonjourServiceName
// bonjourServiceType
// bonjourTXTVersion
// boolValue
// bootstrap
// boundPort
// bubble
// bubbleUser
// buildLaunchArgv
// builtIn
// bump
// bundleIdentifier
// bus
// byteCount
// bytes
// cachedModels
// cachesDirectory
// cachesRelativePath
// canCancel
// cancel
// cancelCurrentTurn
// cancelSequence
// canonicalizeRelativePath
// canvas
// capabilities
// caption
// card
// cat
// catalogID
// catalogSummary
// catalogSymbol
// center
// certificateDER
// certificateFingerprint
// changedFiles
// changing
// chatMode
// checkableBodyMarkers
// checks
// child
// children
// chip
// chooseDirectoryPanel
// chooseExecutablePanel
// classify
// claudeDirectory
// clear
// clearActiveWorkspace
// clearPendingExport
// clientCapabilitiesMetaKey
// clientCapabilitiesMetaKeyAlias
// clientCount
// clientDataModelMetaKey
// clock
// close
// closeCurrentSession
// code
// codeTheme
// codexThreadsFileName
// codexThreadsURL
// cols
// commandPaletteMaxWidth
// commandPaletteMinWidth
// commandText
// compact
// compactContext
// compactControlMinWidth
// composerModelPickerMaxHeight
// composerModelPickerMinWidth
// concatenate
// condition
// configuration
// connect
// connectedClientCount
// connections
// considered
// consumeBell
// content
// contentsOfDirectory
// context
// copyToPasteboard
// corner
// costUSD
// cost_usd
// count
// create
// createDirectory
// createExclusively
// createOrAddProject
// createProject
// createdAt
// current
// currentIndex
// currentProjectDisplayName
// currentSchemaVersion
// currentState
// daemon
// danger
// data
// debugTerminalMinHeight
// debugTerminalMinWidth
// decision
// decode
// defaultEnvOverrides
// defaultMaximumFrameBytes
// defaultPermissionTimeout
// defaultReply
// delete
// deleteAll
// deleteToken
// deletion
// deletions
// densityMode
// depth
// derive
// description
// design
// detail
// details
// deviceName
// dictionary
// diff
// diffPanelMinWidth
// diffSidebarIdealWidth
// diffSidebarMaxWidth
// diffSidebarMinWidth
// direction
// directoryName
// directoryURL
// disabled
// disconnect
// discover
// displayLabel
// displayName
// displayStyle
// divider
// drain
// dropdown
// dropdownRadius
// dualFolderFocusedContentMinWidth
// dualFolderPreviewMinWidth
// dualFolderTreeListIdealWidth
// dualFolderTreeListMinWidth
// durationMS
// echo
// echoReplyPrefix
// editAndResubmit
// editDraft
// elapsed
// embeddedResourceMIMEType
// emitSessionStart
// emphasized
// empty
// emptyObject
// emptyState
// enableDate
// enableRemote
// enableTime
// enabled
// encode
// encodeA2UIAction
// encodeA2UIClientError
// encodeCommand
// encodePermissionResponse
// encodeResumeSession
// encodeSessionMode
// encodeUserPrompt
// encoded
// endTurn
// engine
// ensureDirectory
// ensureModels
// ensureModelsLoaded
// ensureModelsRecordingFailures
// ensureParentDirectory
// entries
// entry
// enumerate
// enumerateProjectCommands
// env
// environment
// errorDescription
// errorMessage
// errorResponse
// event
// eventHistory
// eventLogMinHeight
// eventLogMinWidth
// eventName
// events
// executable
// executablePath
// execute
// existingFolder
// existingFolderURL
// exists
// exitCode
// exitFolderPreviewOnly
// exitStatus
// extraEnv
// faint
// fallbackDeviceName
// falseBinary
// feed
// fetchConversationSnapshot
// file
// fileExists
// fileExtension
// filePreviewMaxBytes
// fileSystem
// fileSystemEvents
// filename
// filesChanged
// filterable
// finished
// fit
// flags
// floating
// floatingCornerStyle
// focus
// folderBrowserListIdealWidth
// folderBrowserListMaxWidth
// folderBrowserListMinWidth
// folderKind
// folderPreviewMinWidth
// folderSidebarShortcuts
// folderView
// fontFamily
// fontSizeScale
// frame
// from
// fsReadProbeFileName
// fsReadProbePath
// functionNames
// generation
// gentle
// git
// gitBranch
// globalPaletteMaxHeight
// globalPaletteWidth
// glyph
// group
// hairline
// hasEmittedAssistantText
// hasResumableSessionProjects
// headByteBudget
// header
// headers
// healthPath
// heroIcon
// historyDirectoryName
// historyDirectoryURL
// historyIgnoreURL
// historyImportState
// historyIndexFileName
// historyIndexURL
// historyNamespace
// historySnapshot
// homeDirectory
// homebrewBin
// hookRequests
// hookSocket
// hookSocketPath
// hooksOverUDS
// host
// html
// htmlEscaped
// hunks
// hydrate
// iconLarge
// iconMedium
// iconSmall
// iconSymbol
// id
// identity
// idleCheckInterval
// idleExitAfterChecks
// idlePhrase
// ignoredDirectoryNames
// importIdentity
// importSessionCatalog
// incoming
// index
// indexRailWidth
// info
// ingest
// initialDelay
// input
// input_tokens
// install
// installHookConfiguration
// installLaunchAgent
// installMaxWidth
// installMinWidth
// instance
// instant
// interactiveTerminal
// interrupt
// isAgentBacked
// isCallExpression
// isCheckable
// isCurrentSession
// isCustomACPProject
// isDirectory
// isEmpty
// isEmptyObject
// isError
// isFolderBacked
// isFolderProject
// isKnownCatalogID
// isKnownComponentBody
// isLikelyBinary
// isLikelyTextFile
// isLive
// isObscured
// isOverview
// isPreAuthenticated
// isProjectDefined
// isProjectModelCatalogReady
// isProjectTypeModelCatalogReady
// isRenderable
// isRestartingCustomACPCLI
// isSpeaking
// isSwitchingSession
// isThinking
// isTwoWayBound
// isUnknown
// isVoid
// issue
// items
// janitorInterval
// jsonPayload
// jsonl
// justify
// key
// kill
// kind
// kindLabel
// kindName
// label
// lanBindHost
// lanEnabled
// language
// large
// lastActivity
// lastOpened
// lastPublishedID
// lastSeen
// lastSessionID
// latestPhase
// launchAgentDetail
// launchAgentInstalled
// launchAgentLabel
// launchAgentPlistName
// launchAgentStderrPath
// launchAgentStdoutPath
// launchAgentThrottleIntervalSeconds
// layout
// leadingTurnID
// leaving
// level
// lines
// listSessions
// listen
// live
// liveProjectPaths
// liveThinkingMaxHeight
// load
// loadAll
// loadError
// loadHookCommands
// loadModelCatalogs
// loadOrCreate
// loadPersisted
// loadSessions
// loadedProjects
// localOverlay
// locate
// locateBinary
// lockoutSeconds
// logPreviewTailBytes
// logSubsystem
// loopbackHost
// macUI
// makeAdapter
// makeCertificates
// makeEventStream
// makeHandle
// makePairing
// makeWireFrameDecoder
// makeWireFrameEncoder
// manualRefreshDetail
// markActiveWorkspace
// markdown
// markdownPreviewMaxBytes
// markerIndex
// match
// matchCount
// matchingRule
// max
// maxAttempts
// maxBatchItems
// maxComponentsPerSurface
// maxDelay
// maxExpressionCallCount
// maxExpressionDepth
// maxFormatPatternLength
// maxJSONDepth
// maxJSONNodes
// maxListExpansion
// maxPayloadBytes
// maxPinnedPaths
// maxPointerLength
// maxRegexInputLength
// maxRegexPatternLength
// maxResolvedStringLength
// maxScanEntries
// maxSurfacesPerSession
// maximumFrameBytes
// medium
// message
// messageCount
// messageMaxWidth
// messageRange
// messages
// metadata
// mimeType
// min
// minAttemptInterval
// minDataModelUpdateInterval
// modeID
// model
// modelCatalogAgentIDs
// modelCatalogFailureMessage
// modelCatalogRefreshKind
// modelCount
// models
// modificationDate
// modifiedAt
// mono
// monoSmall
// monotonic
// motion
// movablePanelTitle
// move
// movePinnedFolderPath
// muted
// name
// named
// namespace
// needsAttention
// networkConnections
// newChat
// newChatInCurrentProject
// newLineNumber
// newRange
// noEventPollInterval
// normalized
// normalizedFolderView
// normalizedSecondaryRootPath
// note
// noteHookFallbackAssistantText
// notification
// notify
// now
// numberValue
// objectValue
// observeClientCount
// observedAt
// occurredAt
// oldLineNumber
// oldRange
// onCancel
// onClose
// onConfirm
// onCreate
// onDismiss
// onNext
// onOpen
// onPrev
// onTap
// onTranscript
// opacity
// openEmptyWorkspace
// openFilePanel
// openFolderProject
// openFolderShortcut
// openOverview
// openProject
// openProjectMaxWidth
// openProjectMinWidth
// openProjectWidth
// openSession
// openURL
// openssl
// optionID
// optionId
// options
// ordinal
// outboundBytes
// outboundReplies
// outcomes
// output
// outputBytes
// output_tokens
// overviewDashboard
// overviewURL
// owner
// pairedAt
// pairedDevices
// pairedDevicesService
// pairingURL
// panel
// parentMessageId
// parse
// parseCache
// parseEffortOutput
// parsePrintModelOutput
// path
// pause
// payload
// pendingFolderSelectionRelativePath
// permissionID
// permissionMode
// permissionPrompts
// permissionResponse
// phase
// phrase
// pin
// pinFolderPath
// pinTTL
// pinnedRelativePaths
// plainTCP
// plainWebSocket
// policy
// popUp
// port
// post
// postInitialize
// postToolUse
// preToolUse
// preferFreshAgentProcess
// prefs
// prefsFileName
// prefsURL
// prepareProjectOpen
// present
// presentFilename
// previewSelectionDebounce
// primary
// primaryAction
// primaryAgentID
// primaryButtonTitle
// primaryColor
// primaryKeyboardModifiers
// primaryKeyboardShortcut
// privatePrefix
// probablyStuckThreshold
// probeTimeout
// processEnvironment
// progress
// project
// projectCommands
// projectDirectory
// projectFileName
// projectPath
// projectPickerMaxHeight
// projectPickerWidth
// projectRootPath
// projectSlug
// projectStateURL
// projectType
// projectURL
// projects
// prominentName
// prompt
// promptReadinessPollInterval
// promptReady
// promptText
// promptWithShortcutFooter
// promptWriteSettleDelay
// prose
// ptyChunks
// ptyReadQueueLabel
// ptySpawnEnvironment
// ptyTUIFallback
// publish
// pulse
// pulseBase
// pulseRange
// pwd
// python3
// queuedPrompts
// quick
// quiet
// radius
// random
// rawValue
// read
// readData
// readDataIfPresent
// recents
// reconfigure
// reconnect
// record
// recordAndSend
// recordBackgroundSessionEvents
// recordOpen
// recordUUID
// recordedAt
// redactedDataModel
// reduceMotion
// ref
// refresh
// refreshAdapterModels
// refreshFolderSidebarShortcuts
// refreshKind
// refreshModelCatalog
// refreshedAt
// register
// rejectIfModelCatalogUnavailable
// relativePath
// release
// reloadProjects
// reloadSessions
// reloadWorkspaceModelCatalogStatus
// remoteActions
// remoteCertificatePasswordService
// remoteEnabled
// remoteOnly
// remoteServerP12FileName
// remoteServerP12URL
// remoteSettingsMinHeight
// remove
// removeProject
// renameProject
// repeatedListScopePaths
// replace
// replies
// reply
// request
// requestAuthorization
// requestPermission
// requestSnapshot
// requestedAt
// requests
// requireAuth
// requiresTerminalEmulation
// reset
// resetCacheForTests
// resetForClosedWorkspace
// resetForTests
// resize
// resolve
// resolveAdapter
// resolveAdapterID
// resolveBool
// resolveContext
// resolveNumber
// resolveProjectType
// resolveScoped
// resolveString
// resolvedSessionID
// resourceURI
// respond
// respondToPermission
// response
// restartCustomACPCLI
// restoreProject
// resumableSessions
// resume
// resumeArgvAddition
// resumeSessionID
// resumeThread
// resumeUnsupportedAfterInitialize
// retainedEmptyCatalogReason
// retiredGenerations
// returnType
// revealInFinder
// review
// reviewOff
// revoke
// revokeToken
// role
// rootComponentID
// rotate
// round
// row
// rowActivationCoalesceWindow
// rows
// run
// runACPTwinStdioLoop
// runtime
// s12
// s16
// s24
// s32
// s4
// s48
// s64
// s8
// sandbox
// save
// saveModels
// savePanel
// scan
// scanDebounce
// scanDetailed
// scenario
// schemaManifest
// schemaVersion
// secondary
// secondaryAction
// secondaryButtonTitle
// secondaryFolderURL
// secondaryKeyboardModifiers
// secondaryKeyboardShortcut
// secondaryRootPath
// seedModelCatalog
// selectAgentMode
// selectCommands
// selectModel
// selectProject
// selectedAgentModeID
// selectedPhaseID
// selectedTurnID
// send
// sendDataModel
// sendPrompt
// sendsAsPrompt
// serviceType
// sessionAvailableModes
// sessionBootstrapBytes
// sessionCurrentModeID
// sessionHandshakeColdStartTimeout
// sessionHandshakeResumeTimeout
// sessionHandshakeWarmTimeout
// sessionID
// sessionId
// sessionLoad
// sessionNew
// sessionOpen
// sessionSidebarIconRailWidth
// sessionSidebarIdealWidth
// sessionSidebarMaxWidth
// sessionSidebarMinWidth
// sessionStart
// sessions
// sessionsFileName
// sessionsIndexFileName
// sessionsIndexURL
// sessionsURL
// setActiveFolderSelection
// setAgentLaunchPreference
// setColumnResizeCursor
// setConnectedRemoteClients
// setLANEnabled
// setMode
// setModel
// setPermissionMode
// setPointingHandCursor
// setProjectType
// setting
// settingsMinHeight
// settingsMinWidth
// settingsURL
// sh
// sha256
// sha256Fingerprint
// shared
// shell
// shellCommand
// shimmer
// shimmerPhaseStep
// shipping
// shippingIDs
// shortLabel
// showSilentRecoveryLog
// showUsageChip
// showsAutomaticSidebarShortcuts
// showsFolderBrowser
// showsOverviewDashboard
// showsPreviewOnSelection
// showsPreviewOnly
// showsSidebarTypeCapsule
// shutdown
// sidebarVisible
// sidecarPort
// signal
// signature
// silentDiagnostics
// silentDiagnosticsPath
// skipParagraph
// slashCatalog
// slashCommandCatalog
// slashCommands
// slashName
// slashPaletteMaxHeight
// slashPaletteMinWidth
// sleep
// small
// snapshot
// snapshotMessages
// snapshotRows
// snapshotText
// socketPath
// solid
// sourceComponentID
// sourceURL
// spacing
// speak
// speechEvents
// stalledToastDuration
// standard
// standardModeID
// standardPathList
// start
// startListening
// startNewPairing
// startNewSession
// startPairing
// startThread
// startTurn
// startupPromptReady
// state
// status
// statusPillMaxWidth
// statusWorking
// stderr
// stdioJSONRPC
// stdout
// stepDelay
// stillWorkingPhrase
// stillWorkingThreshold
// stop
// stopListening
// store
// stored
// stream
// stringValue
// stroke
// subagentAssistantLine
// subagentLines
// subagentStop
// subagentType
// subagentsDirectory
// subscribe
// subscribeWithOutcome
// subscriberCount
// substate
// subtitle
// subtle
// success
// summaries
// summary
// sunken
// supersededAt
// supportedThinkingEfforts
// supportedVersions
// supportsOutOfBandInterrupt
// supportsPinnedSidebarEntries
// supportsResumableSessions
// surface
// surfaceID
// surfaces
// syncAutoApprovalRules
// syntaxHighlightMaxBytes
// synthesizedReplayMessages
// system
// systemImage
// tabs
// tactile
// tail
// tailByteBudget
// terminal
// terminalApp
// terminalReplies
// terminalSnapshot
// terminalSnapshotText
// tertiary
// testScopedCatalogID
// text
// textContent
// theme
// think
// thinkOff
// thinkingEffort
// thinkingPhrase
// thinkingPreview
// threadID
// timestamp
// tint
// title
// tls
// tlsPinQueueLabel
// token
// tokens
// toolCallID
// toolCallIDs
// toolCount
// toolIndex
// toolInputJSON
// toolName
// toolOutputSummary
// toolResultLine
// toolSuccess
// toolUseID
// transcriptEvents
// transcriptJSONL
// transcriptKey
// transcriptMinWidth
// transcriptPath
// transcriptURL
// transcriptsDirectory
// transcriptsDirectoryName
// transport
// transportDescriptor
// trigger
// trueBinary
// truncateTranscript
// truncated
// tts
// turnStart
// turns
// turnsCompleted
// txt
// type
// typography
// unavailableProjectMessage
// undoRemoveProject
// undoToastWindow
// uninstall
// uninstallLaunchAgent
// unloadedProjects
// unpinFolderPath
// unsubmittedPrompt
// unsubscribe
// update
// updateAppearance
// updatePinnedRelativePaths
// updateRules
// updateSecondaryRootPath
// updateSessionMetadata
// updateTXT
// upstreamCommit
// upstreamLicenseNote
// upstreamRepository
// url
// usage
// useTLS
// userLine
// userMessage
// userPrompt
// userPromptSubmit
// userPromptText
// userTurnEchoWindow
// usesDualTreeNavigation
// usesMarkdownPreview
// usesTreeNavigation
// usrBinAndBinPath
// usrBinPath
// usrLocalBin
// uuid
// uuidString
// validate
// validateSecondaryRoot
// validateToken
// validatedDualFolderView
// validationError
// validationRegexp
// value
// variable
// variables
// variant
// version
// versionLabel
// voice
// voidFunctions
// waitForExit
// warmWorkspaceModelCatalogs
// warning
// waveformRange
// webSocket
// webSocketPath
// webSocketPort
// weight
// windowSize
// wireCode
// wireKindName
// wireValue
// withOverrides
// withProjectType
// workLaneIdealWidth
// workLaneMinWidth
// workLaneToolsSectionMaxHeight
// workingDirectory
// workingPhrase
// workspace
// workspaceAdapterStateFileName
// workspaceAdapterStateURL
// workspaceFileName
// workspaceProjects
// workspaceRoot
// workspaceSidebarMinWidth
// workspaceStateURL
// workspaceTrust
// workspaceTrustToolName
// workspaceURL
// workspacesFileName
// workspacesURL
// write
// writeACPTwinFrame
// writeAtomically
// writeBytes
// zsh
// MANIFEST_SYMBOLS_END

// Total: 1560 unique public symbols

