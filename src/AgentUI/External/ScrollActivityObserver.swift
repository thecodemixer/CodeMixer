import AppKit
import SwiftUI

/// Reports only *user-initiated* scroll on the enclosing `NSScrollView`.
///
/// - Wheel / trackpad → definite user scroll (always pauses follow).
/// - Page Up/Down / Home / End → definite user scroll.
/// - Scrollbar thumb live-scroll → possible user scroll (may be ignored briefly
///   while we drive programmatic `scrollTo`).
struct ScrollActivityObserver: NSViewRepresentable {
    var controller: ConversationAutoScrollController

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> NSView {
        let view = ScrollActivityProbeView()
        view.onHierarchyChanged = { [weak coordinator = context.coordinator] probe in
            coordinator?.attach(to: Self.nearestScrollView(from: probe))
        }
        context.coordinator.attach(to: Self.nearestScrollView(from: view))
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.attach(to: Self.nearestScrollView(from: nsView))
    }

    static func nearestScrollView(from view: NSView) -> NSScrollView? {
        if let enclosing = view.enclosingScrollView {
            return enclosing
        }
        var current: NSView? = view
        while let node = current {
            if let scroll = node as? NSScrollView {
                return scroll
            }
            current = node.superview
        }
        return nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var controller: ConversationAutoScrollController

        private weak var scrollView: NSScrollView?
        private var eventMonitor: Any?
        private var didRegisterLiveScrollObserver = false

        init(controller: ConversationAutoScrollController) {
            self.controller = controller
        }

        func attach(to scrollView: NSScrollView?) {
            if self.scrollView === scrollView, scrollView != nil {
                installEventMonitorIfNeeded()
                return
            }
            detach()
            guard let scrollView else { return }

            self.scrollView = scrollView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleLiveScrollStarted(_:)),
                name: NSScrollView.willStartLiveScrollNotification,
                object: scrollView
            )
            didRegisterLiveScrollObserver = true
            installEventMonitorIfNeeded()
        }

        private func detach() {
            if didRegisterLiveScrollObserver {
                NotificationCenter.default.removeObserver(self)
                didRegisterLiveScrollObserver = false
            }
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            scrollView = nil
        }

        private func installEventMonitorIfNeeded() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .keyDown]
            ) { [weak self] event in
                self?.handleEvent(event)
                return event
            }
        }

        private func handleEvent(_ event: NSEvent) {
            guard let scrollView else { return }
            guard event.window === scrollView.window else { return }

            switch event.type {
            case .scrollWheel:
                guard hasMeaningfulScrollDelta(event) else { return }
                guard eventIsOverScrollView(event, scrollView: scrollView) else { return }
                _ = controller.noteDefiniteUserScroll()
            case .keyDown:
                guard isScrollKey(event) else { return }
                guard eventIsOverScrollView(event, scrollView: scrollView)
                        || scrollViewIsInResponderChain(scrollView) else { return }
                _ = controller.noteDefiniteUserScroll()
            default:
                break
            }
        }

        private func hasMeaningfulScrollDelta(_ event: NSEvent) -> Bool {
            // Ignore zero-delta / momentum-end crumbs so we don't flicker.
            hypot(event.scrollingDeltaX, event.scrollingDeltaY) >= 0.5
                || abs(event.deltaX) + abs(event.deltaY) >= 0.5
        }

        private func eventIsOverScrollView(_ event: NSEvent, scrollView: NSScrollView) -> Bool {
            let locationInWindow = event.locationInWindow
            let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
            if frameInWindow.contains(locationInWindow) {
                return true
            }
            if let hit = scrollView.window?.contentView?.hitTest(locationInWindow) {
                if hit === scrollView || hit.isDescendant(of: scrollView) {
                    return true
                }
                if hit.enclosingScrollView === scrollView {
                    return true
                }
            }
            return false
        }

        private func scrollViewIsInResponderChain(_ scrollView: NSScrollView) -> Bool {
            var responder = scrollView.window?.firstResponder
            while let current = responder {
                if current === scrollView { return true }
                if let view = current as? NSView, view.enclosingScrollView === scrollView {
                    return true
                }
                responder = current.nextResponder
            }
            return false
        }

        private func isScrollKey(_ event: NSEvent) -> Bool {
            switch event.keyCode {
            case 115, 119, 116, 121: // Home, End, Page Up, Page Down
                return true
            default:
                return false
            }
        }

        @objc private func handleLiveScrollStarted(_ notification: Notification) {
            _ = controller.notePossibleUserLiveScroll()
        }
    }
}

private final class ScrollActivityProbeView: NSView {
    var onHierarchyChanged: ((ScrollActivityProbeView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onHierarchyChanged?(self)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onHierarchyChanged?(self)
    }

    override func layout() {
        super.layout()
        onHierarchyChanged?(self)
    }
}
