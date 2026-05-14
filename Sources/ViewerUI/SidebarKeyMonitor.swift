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
                    guard let key = Self.key(for: event.keyCode) else { return event }
                    if self.handler?(key) == true { return nil }
                    return event
                }
            } else if !active, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        private static func key(for code: UInt16) -> Key? {
            switch code {
            case KeyCode.up:           return .up
            case KeyCode.down:         return .down
            case KeyCode.left:         return .left
            case KeyCode.right:        return .right
            case KeyCode.ret,
                 KeyCode.numpadEnter:  return .ret
            case KeyCode.escape:       return .escape
            default:                   return nil
            }
        }

        /// macOS hardware key codes (kVK_*). Naming them avoids the
        /// magic-number switch that used to be inline.
        private enum KeyCode {
            static let up:          UInt16 = 126
            static let down:        UInt16 = 125
            static let left:        UInt16 = 123
            static let right:       UInt16 = 124
            static let ret:         UInt16 = 36
            static let numpadEnter: UInt16 = 76
            static let escape:      UInt16 = 53
        }

        /// If a text-editing field is focused, let it handle arrows / enter.
        /// `NSText` is the AppKit base class for all text-editing responders
        /// (NSTextView for plain content; the window's field editor for
        /// NSTextField / NSSearchField).
        private static func shouldYieldToFirstResponder() -> Bool {
            NSApp.keyWindow?.firstResponder is NSText
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}
