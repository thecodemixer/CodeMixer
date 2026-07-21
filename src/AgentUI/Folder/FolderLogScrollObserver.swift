import AppKit
import SwiftUI

/// Pauses folder-log follow when the user scrolls the preview.
struct FolderLogScrollObserver: NSViewRepresentable {
    var onUserScroll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUserScroll: onUserScroll)
    }

    func makeNSView(context: Context) -> NSView {
        let view = FolderLogScrollProbeView()
        view.onHierarchyChanged = { [weak coordinator = context.coordinator] probe in
            coordinator?.attach(to: Self.nearestScrollView(from: probe))
        }
        context.coordinator.attach(to: Self.nearestScrollView(from: view))
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onUserScroll = onUserScroll
        context.coordinator.attach(to: Self.nearestScrollView(from: nsView))
    }

    static func nearestScrollView(from view: NSView) -> NSScrollView? {
        if let enclosing = view.enclosingScrollView { return enclosing }
        var current: NSView? = view
        while let node = current {
            if let scroll = node as? NSScrollView { return scroll }
            current = node.superview
        }
        return nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var onUserScroll: () -> Void
        private weak var scrollView: NSScrollView?
        private var eventMonitor: Any?
        private var observing = false

        init(onUserScroll: @escaping () -> Void) {
            self.onUserScroll = onUserScroll
        }

        func attach(to scrollView: NSScrollView?) {
            if self.scrollView === scrollView, scrollView != nil {
                installMonitorIfNeeded()
                return
            }
            detach()
            guard let scrollView else { return }
            self.scrollView = scrollView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleLiveScroll(_:)),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            observing = true
            installMonitorIfNeeded()
        }

        private func detach() {
            if observing {
                NotificationCenter.default.removeObserver(self)
                observing = false
            }
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            scrollView = nil
        }

        private func installMonitorIfNeeded() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .keyDown]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        private func handle(_ event: NSEvent) {
            guard let scrollView, event.window === scrollView.window else { return }
            if event.type == .scrollWheel {
                onUserScroll()
                return
            }
            guard event.type == .keyDown else { return }
            let codes: Set<UInt16> = [115, 116, 119, 121] // Home / PageUp / End / PageDown
            if codes.contains(event.keyCode) {
                onUserScroll()
            }
        }

        @objc private func handleLiveScroll(_ note: Notification) {
            onUserScroll()
        }

        // Cleanup happens from MainActor update/detach paths; avoid nonisolated
        // deinit access to the non-Sendable monitor token under Swift 6.
    }
}

private final class FolderLogScrollProbeView: NSView {
    var onHierarchyChanged: ((NSView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onHierarchyChanged?(self)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onHierarchyChanged?(self)
    }
}
