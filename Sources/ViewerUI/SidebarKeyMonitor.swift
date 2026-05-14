import AppKit
import SwiftUI

/// Installs an NSEvent local monitor for arrow / Enter keys while the sidebar
/// is visible. The monitor only intercepts when the key window's first
/// responder is **not** a text-editing view (NSTextView, NSSearchField,
/// NSTextField) — that way users can still type and use cursor keys inside
/// the command palette, NSTextView source pane, etc. (CRIT-6.)
struct SidebarKeyMonitor: NSViewRepresentable {
    let isActive: Bool
    let handle: (Key) -> Bool

    enum Key {
        case up, down, left, right, ret, escape
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.handler = handle
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handle
        context.coordinator.setActive(isActive)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
        var handler: ((Key) -> Bool)?

        func setActive(_ active: Bool) {
            if active && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    if Self.shouldYieldToFirstResponder() { return event }
                    let key: Key
                    switch event.keyCode {
                    case 126: key = .up
                    case 125: key = .down
                    case 123: key = .left
                    case 124: key = .right
                    case 36, 76: key = .ret
                    case 53: key = .escape
                    default: return event
                    }
                    if self.handler?(key) == true { return nil }
                    return event
                }
            } else if !active, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        /// If a text-editing field is focused, let it handle arrows / enter.
        private static func shouldYieldToFirstResponder() -> Bool {
            guard let responder = NSApp.keyWindow?.firstResponder else { return false }
            return responder is NSTextView
                || responder is NSTextField
                || responder.isKind(of: NSSearchField.self)
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}
