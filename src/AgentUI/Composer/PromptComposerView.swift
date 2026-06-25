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
    @State private var thinkOn: Bool = false
    @State private var reviewOn: Bool = false
    @State private var isEditMode: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var showSlashPalette: Bool = false
    @State private var showFilePicker: Bool = false
    @State private var filePickerQuery: String = ""
    @State private var showMemoryTip: Bool = false
    @State private var selectedModel = ComposerModelCatalog.defaultOption
    @State private var workspaceFiles: [String] = []
    @State private var modeMenuAnchor: NSView?
    @State private var modelMenuAnchor: NSView?
    @FocusState private var focused: Bool

    public init(model: EngineViewModel, voice: VoiceInputService? = nil) {
        self.model = model
        self.voice = voice
    }

    @ViewBuilder
    private var modeMenu: some View {
        Button {
            showModeMenu()
        } label: {
            modeMenuLabel
                .background(MenuAnchorView { modeMenuAnchor = $0 })
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Mode \(thinkOn ? "Think" : (reviewOn ? "Review" : "Agent"))")
    }

    @ViewBuilder
    private var modelMenu: some View {
        Button {
            showModelMenu()
        } label: {
            modelMenuLabel
                .background(MenuAnchorView { modelMenuAnchor = $0 })
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Model \(selectedModel.label)")
    }

    private var modeMenuLabel: some View {
        HStack(spacing: Theme.spacing.s4) {
            Image(systemName: "infinity")
                .accessibilityHidden(true)
            Text(thinkOn ? "Think" : (reviewOn ? "Review" : "Agent"))
            Image(systemName: "chevron.down")
                .accessibilityHidden(true)
                .font(Theme.typography.iconSmall)
                .foregroundStyle(Theme.text.tertiary.opacity(Theme.opacity.secondary))
        }
        .padding(.horizontal, Theme.spacing.s8)
        .padding(.top, Theme.spacing.s4)
        .padding(.bottom, CGFloat.zero)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner.small)
                .fill(Theme.surface.card.opacity(Theme.opacity.emphasized))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.corner.small)
                        .stroke(Theme.surface.divider, lineWidth: Theme.stroke.hairline)
                )
        )
        .foregroundStyle(Theme.text.secondary)
    }

    private var modelMenuLabel: some View {
        HStack(spacing: Theme.spacing.s4) {
            Text(selectedModel.label)
                .font(Theme.typography.label)
            Image(systemName: "chevron.down")
                .accessibilityHidden(true)
                .font(Theme.typography.iconSmall)
                .foregroundStyle(Theme.text.tertiary.opacity(Theme.opacity.secondary))
        }
        .padding(.top, Theme.spacing.s4)
        .padding(.bottom, CGFloat.zero)
        .padding(.horizontal, Theme.spacing.s4)
        .contentShape(Rectangle())
        .foregroundStyle(Theme.text.secondary)
    }

    private func showModeMenu() {
        DesktopMenuPresenter.popUp(items: [
            DesktopMenuItem(title: "Agent") {
                thinkOn = false
                reviewOn = false
                model.send(.toggleThinkMode(enabled: false))
                model.send(.toggleReviewMode(enabled: false))
            },
            DesktopMenuItem(title: "Think") {
                thinkOn = true
                reviewOn = false
                model.send(.toggleThinkMode(enabled: true))
            },
            DesktopMenuItem(title: "Review") {
                thinkOn = false
                reviewOn = true
                model.send(.toggleReviewMode(enabled: true))
            },
        ], from: modeMenuAnchor)
    }

    private func showModelMenu() {
        DesktopMenuPresenter.popUp(items: ComposerModelCatalog.options.map { option in
            DesktopMenuItem(title: option.label) {
                selectedModel = option
                model.send(.selectModel(id: option.id))
            }
        }, from: modelMenuAnchor)
    }

    public var body: some View {
        VStack(spacing: Theme.spacing.s12) {
            if let prompt = model.pendingPermission {
                PermissionPromptView(prompt: prompt) { decision in
                    model.send(.respondToPermission(id: prompt.id, decision: decision))
                }
            }

            if isEditMode {
                HStack(spacing: Theme.spacing.s8) {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(Theme.signal.info)
                        .imageScale(.small)
                        .accessibilityLabel("Editing last message")
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
                // File-picker popover is anchored to the text field.
                TextField(isEditMode ? "Edit your message…" : "Ask Claude…",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.typography.body)
                    .padding(.horizontal, Theme.spacing.s12)
                    .padding(.top, Theme.spacing.s12)
                    .padding(.bottom, Theme.spacing.s4)
                    .focused($focused)
                    .onSubmit(submit)
                    .onChange(of: draft, handleDraftChange)
                    .onDrop(of: [UTType.fileURL, UTType.image], isTargeted: $isDropTargeted,
                            perform: handleDrop)
                    .onPasteCommand(of: [UTType.fileURL, UTType.image], perform: handlePaste)
                    .accessibilityLabel("Prompt input")
                    .popover(isPresented: $showSlashPalette,
                             attachmentAnchor: .point(.top),
                             arrowEdge: .bottom) {
                        SlashPaletteView(
                            query: slashQuery,
                            commands: model.slashCommands,
                            onSelect: { command in
                                if command.isProjectDefined {
                                    model.send(.runCustomCommand(path: command.name, args: []))
                                    draft = ""
                                } else {
                                    model.send(.runSlashCommand(name: command.name, args: []))
                                    draft = ""
                                }
                                showSlashPalette = false
                                focused = true
                            }
                        )
                    }
                    .popover(isPresented: $showFilePicker,
                             attachmentAnchor: .point(.top),
                             arrowEdge: .bottom) {
                        FilePickerView(
                            query: filePickerQuery,
                            files: workspaceFiles,
                            onSelect: { path in
                                insertAtPath(path)
                                showFilePicker = false
                                focused = true
                            }
                        )
                    }
                    .layoutPriority(1)

                HStack(alignment: .bottom, spacing: Theme.spacing.s8) {
                    HStack(spacing: Theme.spacing.s24) {
                        modeMenu
                        modelMenu
                    }

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
            refreshWorkspaceFiles(workspace)
        }
        .onChange(of: voice?.latestTranscript) { _, transcript in
            guard let transcript, !transcript.isEmpty else { return }
            draft += (draft.isEmpty ? "" : " ") + transcript
            focused = true
        }
        .onAppear {
            if let workspace = model.workspace { refreshWorkspaceFiles(workspace) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                focused = true
            }
        }
    }

    // MARK: - Action button (morph)

    @ViewBuilder
    private var actionButton: some View {
        ComposerActionButton(canCancel: model.canCancel,
                             isEditMode: isEditMode,
                             isSendDisabled: draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                             submit: submit,
                             cancel: cancel)
    }

    // MARK: - Draft changes → palette triggers

    private var slashQuery: String {
        // Everything after the leading "/"
        draft.hasPrefix("/") ? String(draft.dropFirst()) : ""
    }

    private func handleDraftChange(_: String, _ new: String) {
        // Slash palette: leading "/" with no space yet.
        let slashMatch = new.hasPrefix("/") && !new.contains(" ")
        if slashMatch != showSlashPalette { showSlashPalette = slashMatch }

        // @-file picker: draft ends with "@" followed by optional non-space chars.
        if let match = new.lastMatch(of: /(?:^|\s)@(\S*)$/) {
            filePickerQuery = String(match.1)
            if !showFilePicker { showFilePicker = true }
        } else if showFilePicker {
            showFilePicker = false
        }
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in self.insertFileURL(url) }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                    guard let image = item as? NSImage else { return }
                    Task { @MainActor in self.insertImage(image) }
                }
                handled = true
            }
        }
        return handled
    }

    private func handlePaste(_ providers: [NSItemProvider]) {
        _ = handleDrop(providers)
    }

    private func insertFileURL(_ url: URL) {
        let ref: String
        if let workspace = model.workspace,
           url.path.hasPrefix(workspace.path) {
            ref = "@" + url.path.replacingOccurrences(of: workspace.path + "/", with: "")
        } else {
            ref = "@" + url.path
        }
        insertToken(ref)
    }

    private func insertImage(_ image: NSImage) {
        let sessionID = model.sessionID ?? "unknown"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer/\(sessionID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".png"
        let dest = dir.appendingPathComponent(name)
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: dest)
            insertToken("@" + dest.path)
        }
    }

    private func insertToken(_ token: String) {
        draft += (draft.isEmpty ? "" : "\n") + token
        focused = true
    }

    private func insertAtPath(_ path: String) {
        // Replace the trailing @query token.
        if let range = draft.range(of: #"(?:^|\s)@\S*$"#,
                                   options: [.regularExpression, .backwards]) {
            let prefix = draft[..<range.lowerBound]
            let sep = draft[range.lowerBound] == " " ? " " : ""
            draft = String(prefix) + sep + "@" + path
        } else {
            draft += "@" + path
        }
    }

    // MARK: - Workspace file listing

    private func refreshWorkspaceFiles(_ workspace: URL) {
        Task.detached(priority: .utility) {
            let files = listWorkspaceFiles(in: workspace)
            await MainActor.run { self.workspaceFiles = files }
        }
    }

    // MARK: - Actions

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
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
        model.send(.cancelCurrentTurn)
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
                showSlashPalette = true
                focused = true
            }
            Button("Insert Newline", systemImage: "return") {
                draft += "\n"
                focused = true
            }
            Divider()
            Button("Memory — Coming in v1.1", systemImage: "number") {
                showMemoryTip.toggle()
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(Theme.text.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("More composer actions")
        .accessibilityLabel("More composer actions")
        .popover(isPresented: $showMemoryTip) {
            Text("Memory features are coming in v1.1")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)
                .padding(Theme.spacing.s12)
                .frame(minWidth: Theme.layout.commandPaletteMinWidth)
        }
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

private struct MenuAnchorView: NSViewRepresentable {
    let resolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { resolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { resolve(nsView) }
    }
}

