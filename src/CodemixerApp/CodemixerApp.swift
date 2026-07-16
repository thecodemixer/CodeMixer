import SwiftUI
import AgentCore
import AgentUI
import AgentRemoteControl

/// macOS app entry point. Owns one `AgentEngine` per workspace, a single
/// `EngineViewModel` bound to it, and an in-process `RemoteControlServer`
/// so paired mobile clients can drive the same engine over Wi-Fi.
@main
struct CodemixerApp: App {

    @State private var bootstrap = Bootstrap()

    init() {
        // Reap zombie children (PTY workers, openssl, git) early.
        ChildReaper.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView(bootstrap: bootstrap)
                .frame(minWidth: 1024, minHeight: 640)
                .task { await bootstrap.start() }
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { bootstrap.showProjectPicker = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Cancel Turn") { bootstrap.viewModel?.send(.cancelCurrentTurn) }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(bootstrap.viewModel?.canCancel != true)
            }
            CommandGroup(after: .saveItem) {
                Button("Export as Markdown…") { bootstrap.exportSession(as: .markdown) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export as JSONL…") { bootstrap.exportSession(as: .jsonl) }
                Button("Export as HTML…") { bootstrap.exportSession(as: .html) }
            }
            CommandGroup(replacing: .help) {
                Button("Show Event Log") { bootstrap.showEventLog = true }
            }
        }
    }
}
