import SwiftUI
import UniformTypeIdentifiers
import AppKit

enum ComposerAttachmentHandling {

    static func handleDrop(_ providers: [NSItemProvider],
                           workspace: URL?,
                           insertFileURL: @escaping (URL) -> Void,
                           insertImage: @escaping (NSImage) -> Void) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in insertFileURL(url) }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.image.identifier) { item, _ in
                    guard let image = item as? NSImage else { return }
                    Task { @MainActor in insertImage(image) }
                }
                handled = true
            }
        }
        return handled
    }

    static func persistPastedImage(_ image: NSImage, sessionID: String?) -> String? {
        DesktopActions.persistPastedImage(image, sessionID: sessionID)
    }
}

struct ComposerMenuAnchorView: NSViewRepresentable {
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
