import AppKit
import SwiftUI

/// I-21 S4c — clicking INTO a pane's content focuses that pane. Strip
/// clicks already focus (their actions route through the coordinator),
/// but content clicks never reach a SwiftUI gesture when the pane hosts
/// an AppKit surface (WKWebView / NSTextView eat the event), so this is
/// a local `NSEvent` monitor in the `TabNavKeyMonitor` /
/// `DoubleShiftMonitor` mold: an otherwise-empty representable that
/// OBSERVES mouse-downs (always returns the event — the click still
/// lands wherever it was going) and hit-tests them against the pane
/// content rects recorded in `PaneDropChannel`.
///
/// Mounted only while the window is split (the split render branch), so
/// the monitor never exists — let alone fires — in the un-split world.
struct PaneFocusClickMonitor: NSViewRepresentable {
    let isActive: Bool
    let channel: PaneDropChannel
    let paneIDs: [UUID]
    let focusedPaneID: UUID?
    let onFocus: (UUID) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.hostView = view
        context.coordinator.update(channel: channel, paneIDs: paneIDs,
                                   focusedPaneID: focusedPaneID, onFocus: onFocus)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        context.coordinator.update(channel: channel, paneIDs: paneIDs,
                                   focusedPaneID: focusedPaneID, onFocus: onFocus)
        context.coordinator.setActive(isActive)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Convert a window-space mouse location (bottom-left origin) into
    /// the top-left-origin space SwiftUI's `.global` frames report in.
    /// Pure — host-tested against both flipped and unflipped hosts.
    static func globalPoint(
        locationInWindow: CGPoint, hostIsFlipped: Bool, hostHeight: CGFloat
    ) -> CGPoint {
        hostIsFlipped
            ? locationInWindow
            : CGPoint(x: locationInWindow.x, y: hostHeight - locationInWindow.y)
    }

    @MainActor
    final class Coordinator {
        var monitor: Any?
        weak var hostView: NSView?
        private var channel: PaneDropChannel?
        private var paneIDs: [UUID] = []
        private var focusedPaneID: UUID?
        private var onFocus: ((UUID) -> Void)?

        func update(channel: PaneDropChannel, paneIDs: [UUID],
                    focusedPaneID: UUID?, onFocus: @escaping (UUID) -> Void) {
            self.channel = channel
            self.paneIDs = paneIDs
            self.focusedPaneID = focusedPaneID
            self.onFocus = onFocus
        }

        func setActive(_ active: Bool) {
            if active && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown]
                ) { [weak self] event in
                    // Pull primitives off the (non-Sendable) NSEvent before
                    // entering the isolation scope — TabNavKeyMonitor pattern.
                    let location = event.locationInWindow
                    let windowID = event.window.map(ObjectIdentifier.init)
                    MainActor.assumeIsolated {
                        self?.handleMouseDown(location: location, windowID: windowID)
                    }
                    return event   // observe only — never swallow the click
                }
            } else if !active, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        private func handleMouseDown(location: CGPoint, windowID: ObjectIdentifier?) {
            // Only clicks in OUR window — palettes / viewers / other
            // windows share the app-wide monitor stream.
            guard let host = hostView, let window = host.window,
                  windowID == ObjectIdentifier(window),
                  let content = window.contentView,
                  let channel else { return }
            let p = PaneFocusClickMonitor.globalPoint(
                locationInWindow: location,
                hostIsFlipped: content.isFlipped,
                hostHeight: content.bounds.height)
            if let target = channel.focusTarget(
                at: p, live: Set(paneIDs), focused: focusedPaneID) {
                onFocus?(target)
            }
        }

        deinit {
            MainActor.assumeIsolated {
                if let m = monitor { NSEvent.removeMonitor(m) }
            }
        }
    }
}
