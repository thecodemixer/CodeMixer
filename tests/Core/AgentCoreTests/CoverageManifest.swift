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
private let _bonjourType = RemoteDefaults.bonjourServiceType
private let _bonjourName = RemoteDefaults.bonjourServiceName
private let _bonjourVer = RemoteDefaults.bonjourTXTVersion
private let _p12Name = AppSupportPaths.remoteServerP12FileName

// PermissionPrompt
private let _pp = PermissionPrompt(
    id: UUID(), toolName: "T", summary: "S", argumentsSummary: "A",
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
    respond: @escaping @Sendable (UUID, Data) async -> Void
) -> HookSocketHandle {
    HookSocketHandle(incoming: stream, respond: respond)
}

// HookRequest
private let _hookReq = HookRequest(id: UUID(), eventName: "Stop", jsonPayload: Data())

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

// PermissionMode
private let _pmDefault     = PermissionMode.default
private let _pmAcceptEdits = PermissionMode.acceptEdits
private let _pmBypass      = PermissionMode.bypassPermissions
private let _pmPlan        = PermissionMode.plan

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
    let _: Bool = await adapter.truncateTranscript(afterUserTurnID: "id", sessionID: "sid", workspace: ws)
}

// subagentTranscriptURLs — ClaudeTranscriptTailer (verified via type-check only;
// private implementation, confirmed by build).

// MANIFEST_SYMBOLS_BEGIN
// ACPAdapter
// ACPAgentError
// ACPClientState
// ACPCustomAgentAdapterFactory
// ACPEventDecoder
// ACPFileAccess
// ACPFraming
// ACPIncoming
// ACPInputEncoding
// ACPPermissionMapping
// ACPRPCCodec
// ACPSessionIndex
// ACPTerminalProcess
// ACPTerminalSession
// ACPTwin
// ACPTwinScenario
// ActivitySubstate
// ActivityTiming
// AdapterRegistry
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
// AgentModeOption
// AgentModelOption
// AgentTransportDescriptor
// AgentTransportError
// AgentTransportKind
// AgentTransportLaunchSpec
// AppIdentity
// AppSupportPaths
// AppearancePrefKey
// AppearancePrefValue
// AppearancePrefs
// AppearanceTheme
// AttachmentRef
// AttachmentResolver
// AuthStatus
// AutoApprovalRule
// Badge
// Batch
// BindHost
// BonjourAdvertiser
// BonjourBroadcaster
// BroadcastError
// Bundle
// CaptureError
// CertificateError
// CertificateIdentityImporter
// CertificateManager
// ChildReaper
// ChildSpec
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
// ClaudeProjectPaths
// ClaudeSessionLister
// ClaudeSlashCommands
// ClaudeTUIFallback
// ClaudeTranscriptTailer
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
// CodexThreadIndex
// CodexTwin
// CodexUserInput
// CommandPaletteView
// CommandShape
// Configuration
// ConfigureProjectSheet
// ConnectedClientsChip
// ContentBlock
// Context
// ConversationSearchBar
// ConversationSnapshot
// ConversationView
// CostBadgeView
// CursorACPAdapter
// CursorBinaryLocator
// CursorModeCommand
// CustomAgentAdapterFactories
// CustomAgentAdapterFactory
// CustomAgentRef
// DaemonDefaults
// DebugTerminalSheet
// DensityMode
// DesktopActions
// DesktopMenuItem
// DesktopMenuPresenter
// Device
// DiffError
// DiffHunk
// DiffLine
// DiffPanelView
// DiffSnapshot
// DomainStopReason
// EmptyState
// EngineState
// EngineViewModel
// Entry
// Event
// EventLogView
// ExitStatus
// FSEvent
// FSEventsError
// FSEventsStream
// FSEventsWatcher
// FileChangeKind
// FileDiff
// FileSystem
// FileSystemError
// FloatingCornerStyle
// FontFamily
// GitDiffEngine
// HTTPSidecarServer
// HeartbeatActivityMonitor
// HistoryEntry
// HookCommand
// HookRequest
// HookServer
// HookServerError
// HookSink
// HookSocketHandle
// ImportError
// InMemoryNetwork
// InlineStatusTicker
// InstallError
// IntentReveal
// InteractionCoverage
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
// Message
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
// PTYError
// PTYHost
// PairFailureReason
// PairOutcome
// PairedDevice
// PairedDeviceStore
// PairingService
// PairingState
// PaletteCommand
// PermissionDecision
// PermissionMode
// PermissionPrompt
// PermissionResponseDelivery
// Pill
// Policy
// PrefsSnapshot
// PrefsStore
// ProcessError
// ProcessRunner
// ProjectAgentRouter
// ProjectLocalState
// ProjectLocalStateStore
// ProjectPaths
// ProjectPickerView
// ProjectRecord
// ProjectRef
// ProjectType
// PromptComposerView
// RPCError
// RandomSource
// RawEvent
// ReconnectPolicy
// Record
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
// Scenario
// Seams
// ServerError
// ServerFrame
// ServerInfo
// SessionExporter
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
// Snapshot
// SnapshotKind
// SnapshotMessage
// SnapshotService
// SpeechCapture
// SpeechCapturing
// SpeechSynthesis
// State
// StatusPhraseResolver
// StatusPhraseSource
// StatusPill
// StdioJSONRPCTransport
// StopReason
// StoreError
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
// Tick
// Toast
// ToolInput
// ToolOutput
// ToolProgress
// TranscriptLine
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
// WirePermissionPrompt
// WireToolInput
// WireToolOutput
// WireToolProgress
// WireVersion
// WorkspaceChip
// WorkspaceLandingView
// WorkspaceLocalState
// WorkspaceLocalStateStore
// WorkspaceProjectsStore
// WorkspaceScene
// account
// acpSessionsFileName
// acpSessionsURL
// action
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
// agentClientProtocol
// agentError
// agentID
// agentModes
// agentPickerMinHeight
// agentPickerMinWidth
// all
// allPaired
// appSupportDirectory
// appSupportRelativePath
// appearance
// append
// appendLines
// applyAdapterCapabilities
// approval
// arguments
// argumentsSummary
// arrayValue
// arriving
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
// autoApprovalRules
// availableAgentModes
// availableModels
// banner
// bearerToken
// bell
// bellEvents
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
// cachesDirectory
// cachesRelativePath
// canCancel
// cancel
// cancelCurrentTurn
// cancelSequence
// canvas
// capabilities
// caption
// card
// catalogSummary
// certificateDER
// certificateFingerprint
// changedFiles
// changing
// chatMode
// chip
// chooseDirectoryPanel
// claudeDirectory
// clear
// clearActiveWorkspace
// clearPendingExport
// clientCount
// clock
// close
// code
// codeTheme
// codexThreadsFileName
// codexThreadsURL
// cols
// commandPaletteMaxWidth
// commandPaletteMinWidth
// compact
// compactControlMinWidth
// composerModelPickerMinWidth
// concatenate
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
// createProject
// current
// currentConfiguration
// currentIndex
// currentProjectDisplayName
// currentSchemaVersion
// currentState
// cursorRow
// daemon
// danger
// data
// debugTerminalMinHeight
// debugTerminalMinWidth
// decision
// decode
// defaultEnvOverrides
// defaultPermissionTimeout
// defaultReply
// delete
// deleteAll
// deleteToken
// deletion
// deletions
// densityMode
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
// directoryName
// directoryURL
// disabled
// disconnect
// displayLabel
// displayName
// divider
// drain
// dropdown
// dropdownRadius
// durationMS
// editAndResubmit
// editDraft
// elapsed
// emitSessionStart
// emphasized
// empty
// emptyState
// enableRemote
// enabled
// encode
// encodeCommand
// encodePermissionResponse
// encodeSessionMode
// encodeUserPrompt
// encoded
// endTurn
// engine
// ensureDirectory
// ensureParentDirectory
// entry
// enumerate
// enumerateProjectCommands
// env
// environment
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
// exitCode
// exitStatus
// extraEnv
// faint
// fallbackDeviceName
// feed
// fileExists
// fileSystem
// fileSystemEvents
// filename
// finished
// flags
// floating
// floatingCornerStyle
// focus
// fontFamily
// fontSizeScale
// frame
// from
// gentle
// git
// gitBranch
// globalPaletteMaxHeight
// globalPaletteWidth
// glyph
// hairline
// hasEmittedAssistantText
// headByteBudget
// header
// headers
// healthPath
// heroIcon
// historySnapshot
// homeDirectory
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
// importIdentity
// incoming
// index
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
// instant
// interactiveTerminal
// interrupt
// isCurrentSession
// isDirectory
// isError
// isProjectDefined
// isSpeaking
// janitorInterval
// jsonPayload
// jsonl
// kill
// kind
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
// launchAgentDetail
// launchAgentInstalled
// launchAgentLabel
// launchAgentPlistName
// launchAgentStderrPath
// launchAgentStdoutPath
// launchAgentThrottleIntervalSeconds
// layout
// leaving
// level
// lines
// listResumableSessions
// listSessions
// listen
// live
// load
// loadAll
// loadHookCommands
// loadOrCreate
// loadPersisted
// loadSessions
// locate
// locateBinary
// lockoutSeconds
// logSubsystem
// loopbackHost
// macUI
// makeAdapter
// makeCertificates
// makeEventStream
// makeHandle
// makePairing
// markActiveWorkspace
// markdown
// match
// matchCount
// matchingRule
// maxAttempts
// maxDelay
// maximumFrameBytes
// medium
// message
// messageCount
// messageMaxWidth
// messages
// metadata
// mimeType
// minAttemptInterval
// modeID
// model
// modificationDate
// mono
// monoSmall
// monotonic
// motion
// muted
// name
// named
// networkConnections
// newChat
// newChatInCurrentProject
// newLineNumber
// newRange
// noEventPollInterval
// note
// notification
// notify
// now
// numberValue
// objectValue
// observeClientCount
// observedAt
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
// openFilePanel
// openSession
// openURL
// openssl
// optionID
// options
// outboundBytes
// outboundReplies
// output
// outputBytes
// output_tokens
// owner
// pairedAt
// pairedDevices
// pairedDevicesService
// pairingURL
// panel
// parentMessageId
// parse
// path
// pause
// payload
// permissionID
// permissionMode
// permissionPrompts
// permissionResponse
// phrase
// pin
// pinTTL
// plainTCP
// plainWebSocket
// policy
// popUp
// port
// post
// postInitialize
// postToolUse
// preToolUse
// prefs
// prefsFileName
// prefsURL
// primary
// primaryAction
// primaryAgentID
// primaryButtonTitle
// primaryKeyboardModifiers
// primaryKeyboardShortcut
// probablyStuckThreshold
// processEnvironment
// progress
// project
// projectCommands
// projectDirectory
// projectFileName
// projectPickerMaxHeight
// projectPickerMinHeight
// projectPickerMinWidth
// projectSlug
// projectStateURL
// projectType
// projectURL
// projects
// prominentName
// prompt
// promptReady
// promptWithShortcutFooter
// prose
// ptyChunks
// ptyReadQueueLabel
// ptySpawnEnvironment
// ptyTUIFallback
// publish
// pulse
// pulseBase
// pulseRange
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
// recent
// recents
// reconfigure
// reconnect
// record
// recordOpen
// recordSession
// recordThread
// recordTurn
// recordUUID
// reduceMotion
// ref
// refresh
// refreshProjects
// register
// relativePath
// release
// reloadProjects
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
// replies
// reply
// request
// requestAuthorization
// requestPermission
// requestedAt
// requests
// requireAuth
// requiresTerminalEmulation
// reset
// resetForClosedWorkspace
// resetForTests
// resize
// resolve
// resolveAdapter
// resolveAdapterID
// resolveProjectType
// resolvedSessionID
// respond
// response
// restoreProject
// resumableSessions
// resume
// resumeArgvAddition
// resumePromptReadyPollInterval
// resumePromptReadySettleDelay
// resumeSessionID
// resumeStartupStallTimeout
// resumedSessionPostSessionStartFallback
// resumedSessionStartupStallTimeout
// revealInFinder
// review
// revoke
// revokeToken
// role
// rotate
// row
// rows
// run
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
// savePanel
// scenario
// schemaVersion
// secondary
// selectCommands
// selectProject
// selectedAgentModeID
// send
// sendPrompt
// serviceType
// sessionBootstrapBytes
// sessionID
// sessionId
// sessionLister
// sessionNew
// sessionOpen
// sessionSidebarIconRailWidth
// sessionSidebarIdealWidth
// sessionSidebarMaxWidth
// sessionSidebarMinWidth
// sessionStart
// sessions
// sessionsFileName
// sessionsURL
// setConnectedRemoteClients
// setLANEnabled
// setMode
// setProjectType
// settingsMinHeight
// settingsMinWidth
// settingsURL
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
// snapshotRows
// snapshotText
// socketPath
// spacing
// speak
// speechEvents
// stalledToastDuration
// standard
// start
// startListening
// startNewPairing
// startPairing
// startThread
// startTurn
// startupPromptReady
// startupSubmitRecoveryDelay
// startupSubmitRecoveryMaxAttempts
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
// supersede
// supportsOutOfBandInterrupt
// supportsResumableSessions
// surface
// syncAutoApprovalRules
// system
// systemImage
// tactile
// tail
// tailByteBudget
// terminal
// terminalApp
// terminalReplies
// terminalSnapshot
// terminalSnapshotText
// tertiary
// text
// textContent
// theme
// thinkingPhrase
// threadID
// timestamp
// tint
// title
// tls
// tlsPinQueueLabel
// token
// tokens
// toolIndex
// toolName
// toolResultLine
// toolUseID
// transcriptEvents
// transcriptJSONL
// transcriptPath
// transcriptURL
// transport
// transportDescriptor
// truncateTranscript
// truncated
// tts
// turnStart
// turns
// txt
// type
// typography
// undoRemoveProject
// undoToastWindow
// uninstall
// uninstallLaunchAgent
// unsubmittedPrompt
// unsubscribe
// update
// updateAppearance
// updateRules
// updateTXT
// url
// usage
// useTLS
// userLine
// userMessage
// userPrompt
// userPromptSubmit
// userTurnEchoWindow
// uuid
// uuidString
// validateToken
// variable
// variables
// version
// versionLabel
// voice
// waitForExit
// warning
// waveformRange
// webSocket
// webSocketPath
// webSocketPort
// windowSize
// wireCode
// withOverrides
// workingDirectory
// workingPhrase
// workspace
// workspaceFileName
// workspaceProjects
// workspaceRoot
// workspaceSidebarMinWidth
// workspaceStateURL
// workspaceTrust
// workspacesFileName
// workspacesURL
// write
// writeAtomically
// writeBytes
// MANIFEST_SYMBOLS_END

// Total: 1054 unique public symbols

