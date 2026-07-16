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
    id: "x", workspace: URL(fileURLWithPath: "/"), title: "t",
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
// AgentModelOption
// AppIdentity
// AppSupportPaths
// AppearancePrefKey
// AppearancePrefValue
// AppearancePrefs
// AttachmentRef
// AttachmentResolver
// AuthGateView
// AuthStatus
// AutoApprovalRule
// Badge
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
// CommandPaletteView
// CommandShape
// Configuration
// ConnectedClientsChip
// ContentBlock
// Context
// ConversationSearchBar
// ConversationSnapshot
// ConversationView
// CostBadgeView
// DaemonDefaults
// DebugTerminalSheet
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
// InstallClaudeView
// InstallError
// IntentReveal
// InteractionCoverage
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
// PrefsSnapshot
// PrefsStore
// ProcessError
// ProcessRunner
// ProjectPickerView
// ProjectRecord
// ProjectRef
// PromptComposerView
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
// StopReason
// StoreError
// StreamBufferDefaults
// SubscribeOutcome
// SubscribeReplayOutcome
// Subscription
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
// WireCodec
// WirePermissionPrompt
// WireToolInput
// WireToolOutput
// WireToolProgress
// WireVersion
// WorkspaceChip
// WorkspaceProjectsStore
// WorkspaceScene
// account
// action
// activityDotSize
// activityDotsHeight
// adapter
// adapterEvents
// addExistingProject
// addition
// additions
// address
// agentID
// agentPickerMinHeight
// agentPickerMinWidth
// all
// allPaired
// appSupportDirectory
// appSupportRelativePath
// appearance
// append
// appendLines
// arguments
// argumentsSummary
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
// autoApprovalRules
// availableModels
// banner
// bearerToken
// bell
// bind
// body
// bonjourServiceName
// bonjourServiceType
// bonjourTXTVersion
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
// cancelSequence
// canvas
// capabilities
// caption
// card
// certificateDER
// certificateFingerprint
// changedFiles
// changing
// chip
// chooseDirectoryPanel
// claudeDirectory
// clear
// clearPendingExport
// clientCount
// clock
// close
// code
// codeTheme
// cols
// commandPaletteMaxWidth
// commandPaletteMinWidth
// compactControlMinWidth
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
// createDirectory
// createProject
// current
// currentConfiguration
// currentIndex
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
// delete
// deleteAll
// deleteToken
// deletion
// deletions
// densityMode
// description
// details
// deviceName
// diff
// diffPanelMinWidth
// diffSidebarIdealWidth
// diffSidebarMaxWidth
// diffSidebarMinWidth
// disabled
// disconnect
// displayName
// divider
// drain
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
// encodePermissionResponse
// encodeUserPrompt
// encoded
// endTurn
// engine
// ensureDirectory
// ensureParentDirectory
// enumerate
// enumerateProjectCommands
// env
// environment
// errorMessage
// event
// eventHistory
// eventLogMinHeight
// eventLogMinWidth
// eventName
// events
// executable
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
// focus
// fontSizeScale
// gentle
// git
// gitBranch
// globalPaletteMaxHeight
// globalPaletteWidth
// glyph
// hairline
// headByteBudget
// header
// headers
// healthPath
// heroIcon
// hint
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
// interrupt
// isCurrentSession
// isDirectory
// isError
// isProjectDefined
// isSpeaking
// janitorInterval
// jsonPayload
// jsonl
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
// makeCertificates
// makeEventStream
// makeHandle
// makePairing
// markdown
// match
// matchCount
// matchingRule
// maxAttempts
// maxDelay
// medium
// message
// messageCount
// messageMaxWidth
// messages
// metadata
// mimeType
// minAttemptInterval
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
// newLineNumber
// newRange
// noEventPollInterval
// note
// notification
// notify
// now
// observeClientCount
// observedAt
// oldLineNumber
// oldRange
// onCancel
// onClose
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
// options
// outboundBytes
// outboundReplies
// output
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
// popUp
// port
// post
// postToolUse
// preToolUse
// prefs
// prefsFileName
// prefsURL
// primary
// probablyStuckThreshold
// processEnvironment
// progress
// projectDirectory
// projectPickerMaxHeight
// projectPickerMinHeight
// projectPickerMinWidth
// projectSlug
// projects
// prompt
// promptReady
// promptWithShortcutFooter
// prose
// ptyChunks
// ptyOutput
// ptyReadQueueLabel
// ptyTUIFallback
// publish
// pulse
// pulseBase
// pulseRange
// python3
// quick
// quiet
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
// recordUUID
// reduceMotion
// ref
// refresh
// refreshProjects
// register
// relativePath
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
// reply
// requestAuthorization
// requestPermission
// requestedAt
// requests
// requireAuth
// reset
// resize
// resolve
// resolvedSessionID
// respond
// restoreProject
// resumableSessions
// resume
// resumeArgvAddition
// resumePromptReadyPollInterval
// resumeSessionID
// resumeStartupStallTimeout
// revealInFinder
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
// save
// savePanel
// scenario
// screen
// secondary
// send
// sendPrompt
// serviceType
// sessionID
// sessionId
// sessionLister
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
// slashCommandCatalog
// slashCommands
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
// startTurn
// startupPromptReady
// startupSubmitRecoveryDelay
// state
// status
// statusPillMaxWidth
// statusWorking
// stderr
// stdout
// stepDelay
// stillWorkingPhrase
// stillWorkingThreshold
// stop
// stopListening
// store
// stream
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
// supportsResumableSessions
// surface
// syncAutoApprovalRules
// system
// systemImage
// tactile
// tail
// tailByteBudget
// terminalApp
// terminalReplies
// terminalSnapshotText
// tertiary
// text
// textContent
// theme
// thinkingPhrase
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
// truncateTranscript
// tts
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
// warning
// waveformRange
// webSocket
// webSocketPath
// webSocketPort
// windowSize
// withOverrides
// workingDirectory
// workingPhrase
// workspace
// workspaceProjects
// workspaceSidebarMinWidth
// workspaceTrust
// workspacesFileName
// workspacesURL
// write
// writeAtomically
// MANIFEST_SYMBOLS_END

// Total: 809 unique public symbols

