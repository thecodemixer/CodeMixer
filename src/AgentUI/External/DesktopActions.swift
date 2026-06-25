import AppKit
import Foundation
import UniformTypeIdentifiers

/// AppKit wrappers for clipboard, Finder, and save-panel actions used by UI views.
public enum DesktopActions {

    public static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public static func openURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    public static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @MainActor
    public static func openFilePanel(allowedTypes: [UTType] = [.item],
                                     allowsMultipleSelection: Bool = true) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = allowedTypes
        return panel.runModal() == .OK ? panel.urls : []
    }

    @MainActor
    public static func chooseDirectoryPanel(prompt: String = "Open") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Presents a save panel and returns the chosen URL, or nil if cancelled.
    @MainActor
    public static func savePanel(nameField: String,
                                 allowedTypes: [UTType],
                                 directoryURL: URL? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = nameField
        panel.allowedContentTypes = allowedTypes
        if let directoryURL { panel.directoryURL = directoryURL }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

public struct DesktopMenuItem {
    public let title: String
    public let action: @MainActor () -> Void

    public init(title: String, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.action = action
    }
}

public enum DesktopMenuPresenter {
    @MainActor
    public static func popUp(items: [DesktopMenuItem], from anchor: NSView?) {
        guard let anchor else { return }
        let menu = NSMenu()
        items.forEach { item in
            menu.addItem(CallbackMenuItem(title: item.title, handler: item.action))
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: anchor.bounds.height),
                   in: anchor)
    }
}

private final class CallbackMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor @objc private func run() {
        handler()
    }
}
