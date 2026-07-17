import AppKit
import SwiftUI

/// AppKit chrome helpers for floating panels.
///
/// Prefer SwiftUI `Window` / `Settings` scenes for movable titled panels —
/// macOS `.sheet` presentations are document-modal and do not honor
/// `NSWindow.isMovable`. Utility panels keep a titled drag region but hide
/// the traffic-light buttons (close / minimise / zoom).
public enum PanelWindowChrome {

    /// Sets `window`'s title when non-empty, ensures it is movable, and hides
    /// the standard title-bar buttons. Dismiss via in-panel actions (Done /
    /// Cancel) or `⌘W`.
    @MainActor
    public static func apply(to window: NSWindow?, title: String?) {
        guard let window else { return }
        if let title, !title.isEmpty {
            window.title = title
            window.titleVisibility = .visible
        }
        window.isMovable = true
        // Keep closable for ⌘W even though the traffic-light button is hidden.
        window.styleMask.insert(.closable)
        window.styleMask.remove(.miniaturizable)
        for button in [NSWindow.ButtonType.closeButton,
                       .miniaturizeButton,
                       .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
    }

    /// Centers `window` on its screen (or the main screen).
    @MainActor
    public static func center(_ window: NSWindow?) {
        window?.center()
    }
}

/// Invisible bridge that finds the hosting `NSWindow` and applies panel chrome.
struct PanelWindowChromeInstaller: NSViewRepresentable {
    var title: String?

    final class Coordinator {
        var didCenter = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        // New hosting = new presentation; allow one center pass.
        context.coordinator.didCenter = false
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Hosting window is often nil on the first SwiftUI update.
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            PanelWindowChrome.apply(to: window, title: title)
            if !context.coordinator.didCenter {
                PanelWindowChrome.center(window)
                context.coordinator.didCenter = true
            }
        }
    }
}

extension View {
    /// Titled, movable, screen-centered panel chrome without traffic-light buttons.
    public func movablePanelTitle(_ title: String? = nil) -> some View {
        background(PanelWindowChromeInstaller(title: title))
    }
}
