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

    static func persistPastedImage(_ image: NSImage, sessionID: String?) -> String? {
        let sessionID = sessionID ?? "unknown"
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer/\(sessionID)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(UUID().uuidString + ".png")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        try? png.write(to: dest)
        return dest.path
    }

    static func openCodeSnippet(_ code: String, fileExtension: String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer-snippets", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("snippet-\(UUID().uuidString).\(fileExtension)")
        try? code.write(to: file, atomically: true, encoding: .utf8)
        openURL(file)
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

    /// Shows the native pointing-hand cursor while the pointer is over an
    /// actionable control (close buttons, links). Call with `false` on leave.
    @MainActor
    public static func setPointingHandCursor(_ hovering: Bool) {
        if hovering {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
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

// MARK: - NSMenu presenter for composer dropdowns

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

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @MainActor @objc private func run() { handler() }
}
