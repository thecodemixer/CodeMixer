import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AgentCore
import AgentProtocol

/// The bottom composer.
///
/// Responsibilities: free-form text input, mode toggles (`/think`, `/review`),
/// voice dictation, slash-command palette (leading `/` opens it), @-file picker
/// (trailing `@word` opens it), file/image drag-and-drop, and send/cancel.
///
/// When `model.editDraft` is non-nil the composer pre-fills and routes through
/// `editAndResubmitLast`. When `model.canCancel` is true the send button
/// morphs to a full-width red Stop bar.
public struct PromptComposerView: View {
    @Bindable public var model: EngineViewModel
    public var voice: VoiceInputService?

    @State private var draft: String = ""
    @State private var isEditMode: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var showSlashPalette: Bool = false
    @State private var slashPaletteSelection: Int = 0
    @State private var showFilePicker: Bool = false
    @State private var filePickerQuery: String = ""
    @State private var selectedModelID: String = ""
    @State private var fileIndex = ComposerWorkspaceFileIndex()
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: EngineViewModel, voice: VoiceInputService? = nil) {
        self.model = model
        self.voice = voice
    }

    public var body: some View {
        VStack(spacing: Theme.spacing.s12) {
            if let prompt = model.pendingPermission {
                PermissionPromptView(prompt: prompt) { decision in
                    model.respondToPermission(id: prompt.id, decision: decision)
                }
            }

            if isEditMode {
                HStack(spacing: Theme.spacing.s8) {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(Theme.signal.info)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text("Editing last message")
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.signal.info)
                    Spacer()
                    Button("Cancel") {
                        isEditMode = false
                        draft = ""
                    }
                    .font(Theme.typography.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.text.tertiary)
                }
                .padding(.horizontal, Theme.spacing.s4)
                .transition(.opacity)
            }

            VStack(spacing: Theme.spacing.s8) {
                if showSlashPalette {
                    SlashPaletteView(
                        query: PromptComposerDraftLogic.slashQuery(from: draft),
                        commands: model.slashCommands,
                        selectedIndex: $slashPaletteSelection,
                        onSelect: activateSlashCommand,
                        onDismiss: { showSlashPalette = false }
                    )
                    .padding(.horizontal, Theme.spacing.s12)
                    .padding(.top, Theme.spacing.s12)
                    .transition(.opacity)
                }

                VStack(spacing: Theme.spacing.s8) {
                    // File-picker popover is anchored to the text field.
                    TextField(promptPlaceholder,
                              text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Theme.typography.body)
                        .padding(.horizontal, Theme.spacing.s12)
                        .padding(.top, Theme.spacing.s12)
                        .padding(.bottom, Theme.spacing.s4)
                        .focused($focused)
                        .onSubmit(handleSubmit)
                        .onChange(of: draft, handleDraftChange)
                        .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isDropTargeted,
                                perform: handleDrop)
                        .onPasteCommand(of: [UTType.fileURL, UTType.image], perform: handlePaste)
                        .accessibilityLabel("Prompt input")
                        .popover(isPresented: $showFilePicker,
                                 attachmentAnchor: .point(.top),
                                 arrowEdge: .bottom) {
                            FilePickerView(
                                query: filePickerQuery,
                                files: fileIndex.files,
                                onSelect: { path in
                                    insertAtPath(path)
                                    showFilePicker = false
                                    focused = true
                                }
                            )
                        }
                        .layoutPriority(1)
                        .disabled(model.isComposerLockedForSessionResume)

                    HStack(alignment: .bottom, spacing: Theme.spacing.s8) {
                        ComposerModeModelMenus(model: model,
                                               selectedModelID: $selectedModelID)

                        Spacer()

                        composerMenu

                        Button(action: openFilePicker) {
                            Image(systemName: "paperclip")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.text.secondary)
                        .accessibilityLabel("Attach file")

                        micButton

                        actionButton
                    }
                    .padding(.horizontal, Theme.spacing.s12)
                    .padding(.bottom, Theme.spacing.s8)
                    .disabled(model.isComposerLockedForSessionResume)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.corner.medium)
                    .fill(Theme.surface.bubble)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.corner.medium)
                            .stroke(isDropTargeted
                                    ? Theme.signal.info.opacity(Theme.opacity.divider)
                                    : Color.clear, lineWidth: Theme.stroke.focus)
                    )
            )
            .animation(Theme.motion.resolve(Theme.motion.arriving, reduceMotion: reduceMotion),
                       value: showSlashPalette)
        }
        .padding(.horizontal, Theme.spacing.s16)
        .padding(.top, Theme.spacing.s16)
        .padding(.bottom, Theme.spacing.s8)
        .background(Theme.surface.panel)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: model.editDraft) { _, newDraft in
            guard let newDraft else { return }
            draft = newDraft
            isEditMode = true
            model.editDraft = nil
            focused = true
        }
        .onChange(of: model.workspace) { _, workspace in
            guard let workspace else { return }
            fileIndex.refresh(workspace: workspace)
        }
        .onChange(of: voice?.latestTranscript) { _, transcript in
            guard let transcript, !transcript.isEmpty else { return }
            draft += (draft.isEmpty ? "" : " ") + transcript
            focused = true
        }
        .onAppear {
            if selectedModelID.isEmpty, let first = model.availableModels.first {
                selectedModelID = first.id
            }
            if let workspace = model.workspace { fileIndex.refresh(workspace: workspace) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                focused = true
            }
        }
        .onChange(of: model.availableModels.map(\.id)) { _, ids in
            guard let first = ids.first else {
                selectedModelID = ""
                return
            }
            if selectedModelID.isEmpty || !ids.contains(selectedModelID) {
                selectedModelID = first
            }
        }
    }

    // MARK: - Action button (morph)

    @ViewBuilder
    private var actionButton: some View {
        ComposerActionButton(canCancel: model.canCancel,
                             isEditMode: isEditMode,
                             isSendDisabled: model.isComposerLockedForSessionResume
                                 || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                             submit: handleSubmit,
                             cancel: cancel)
    }

    private var promptPlaceholder: String {
        if model.isComposerLockedForSessionResume {
            return "Starting session…"
        }
        return isEditMode ? "Edit your message…" : "Ask…"
    }

    private func handleDraftChange(_: String, _ new: String) {
        let triggers = PromptComposerDraftLogic.paletteTriggers(for: new,
                                                                 showSlashPalette: showSlashPalette,
                                                                 showFilePicker: showFilePicker)
        if triggers.showSlashPalette && !showSlashPalette {
            slashPaletteSelection = 0
        }
        showSlashPalette = triggers.showSlashPalette
        showFilePicker = triggers.showFilePicker
        filePickerQuery = triggers.filePickerQuery
    }

    private func handleSubmit() {
        if showSlashPalette {
            let query = PromptComposerDraftLogic.slashQuery(from: draft)
            let filtered = PromptComposerDraftLogic.filteredSlashCommands(
                from: model.slashCommands,
                query: query
            )
            if filtered.indices.contains(slashPaletteSelection) {
                activateSlashCommand(filtered[slashPaletteSelection])
                return
            }
        }
        submit()
    }

    private func activateSlashCommand(_ command: SlashCommand) {
        model.activateSlashCommand(command)
        draft = ""
        showSlashPalette = false
        slashPaletteSelection = 0
        focused = true
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        ComposerAttachmentHandling.handleDrop(providers,
                                              workspace: model.workspace,
                                              insertFileURL: insertFileURL,
                                              insertImage: insertImage)
    }

    private func handlePaste(_ providers: [NSItemProvider]) {
        _ = handleDrop(providers)
    }

    private func insertFileURL(_ url: URL) {
        let ref = PromptComposerDraftLogic.fileReference(for: url, workspace: model.workspace)
        insertToken(ref)
    }

    private func insertImage(_ image: NSImage) {
        guard let path = ComposerAttachmentHandling.persistPastedImage(image, sessionID: model.sessionID) else {
            return
        }
        insertToken("@" + path)
    }

    private func insertToken(_ token: String) {
        PromptComposerDraftLogic.insertToken(token, into: &draft)
        focused = true
    }

    private func insertAtPath(_ path: String) {
        PromptComposerDraftLogic.insertAtPath(path, into: &draft)
    }

    // MARK: - Actions

    private func submit() {
        guard !model.isComposerLockedForSessionResume else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let command = PromptComposerDraftLogic.exactSlashCommand(in: model.slashCommands, draft: text) {
            draft = ""
            isEditMode = false
            model.activateSlashCommand(command)
            focused = true
            return
        }
        draft = ""
        if isEditMode, let bubbleID = model.lastUserBubbleID {
            model.editAndResubmit(targetBubbleID: bubbleID, text: text, attachments: [])
        } else {
            model.sendPrompt(text, attachments: [])
        }
        isEditMode = false
        focused = true
    }

    private func cancel() {
        model.cancelCurrentTurn()
    }

    // MARK: - Mic button + waveform

    @ViewBuilder
    private var composerMenu: some View {
        Menu {
            Button("Attach File or Image", systemImage: "plus") {
                openFilePicker()
            }
            Button("Insert @-File Reference", systemImage: "at") {
                filePickerQuery = ""
                showFilePicker = true
                focused = true
            }
            Button("Open Slash Commands", systemImage: "terminal") {
                if !draft.hasPrefix("/") { draft = "/" + draft }
                slashPaletteSelection = 0
                showSlashPalette = true
                focused = true
            }
            Button("Insert Newline", systemImage: "return") {
                draft += "\n"
                focused = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(Theme.text.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("More composer actions")
        .accessibilityLabel("More composer actions")
    }

    @ViewBuilder
    private var micButton: some View {
        ComposerMicButton(voice: voice, toggle: micToggle)
    }

    private func micToggle() {
        guard let voice else { return }
        if voice.isListening {
            voice.stopListening()
        } else {
            Task { await voice.startListening() }
        }
    }

    // MARK: - File attachment picker

    private func openFilePicker() {
        for url in DesktopActions.openFilePanel(allowedTypes: [.item]) {
            insertFileURL(url)
        }
    }
}

#if DEBUG
#Preview("Composer – Light") {
    PromptComposerView(model: .previewConversation)
        .frame(width: 640)
        .preferredColorScheme(.light)
}

#Preview("Composer – Dark") {
    PromptComposerView(model: .previewConversation)
        .frame(width: 640)
        .preferredColorScheme(.dark)
}
#endif

