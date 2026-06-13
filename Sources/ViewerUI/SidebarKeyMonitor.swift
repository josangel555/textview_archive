import AppKit
import SwiftUI

/// Marker for custom `NSView`s that consume raw key events (Return / arrows)
/// themselves and must NOT have those keys stolen by the app-wide sidebar key
/// monitor. `NSText` subclasses are already exempt (text editing); this covers
/// non-`NSText` focusable views like the embedded terminal grid, whose Return
/// must reach the PTY rather than driving sidebar navigation.
protocol SidebarKeyMonitorExempt: AnyObject {}

/// Installs an NSEvent local monitor for arrow / Enter keys while the sidebar
/// is visible. The monitor only intercepts when the key window's first
/// responder is **not** a text-editing view (NSTextView, NSSearchField,
/// NSTextField) AND not a `SidebarKeyMonitorExempt` view (e.g. the terminal) —
/// that way users can still type and use cursor keys inside the command
/// palette, NSTextView source pane, the terminal, etc. (CRIT-6.)
struct SidebarKeyMonitor: NSViewRepresentable {
    let isActive: Bool
    let handle: (Key) -> Bool

    enum Key {
        case up, down, left, right, ret, escape, f2
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

    @MainActor
    final class Coordinator {
        var monitor: Any?
        var handler: ((Key) -> Bool)?

        func setActive(_ active: Bool) {
            if active && monitor == nil {
                // The local event monitor is called by AppKit on the main
                // thread; assert that so we can call main-actor isolated
                // helpers. Pull `keyCode` out of `event` before entering
                // the inner scope so we don't have to cross NSEvent over
                // an isolation boundary (NSEvent isn't Sendable in some
                // Swift toolchains).
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    let keyCode = event.keyCode
                    let consume: Bool = MainActor.assumeIsolated {
                        guard let self else { return false }
                        if Self.shouldYieldToFirstResponder() { return false }
                        guard let key = Self.key(for: keyCode) else { return false }
                        return self.handler?(key) == true
                    }
                    return consume ? nil : event
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
            case KeyCode.f2:           return .f2
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
            static let f2:          UInt16 = 120
        }

        /// If a text-editing field is focused, let it handle arrows / enter.
        /// `NSText` is the AppKit base class for all text-editing responders
        /// (NSTextView for plain content; the window's field editor for
        /// NSTextField / NSSearchField).
        ///
        /// Marked `@MainActor` — touches `NSApp` / `keyWindow` / first
        /// responder which are all main-actor isolated under Swift 6.3.
        /// Callers (the event monitor closure) are on the main thread by
        /// AppKit contract; declare it explicitly so the checker agrees.
        @MainActor
        private static func shouldYieldToFirstResponder() -> Bool {
            let fr = NSApp.keyWindow?.firstResponder
            // Text editors (NSTextView / field editor) AND custom raw-key views
            // (the terminal grid) own their key events — don't steal Return/arrows.
            return fr is NSText || fr is SidebarKeyMonitorExempt
        }

        deinit {
            // `monitor` is @MainActor state; the Coordinator is owned by
            // a SwiftUI representable and deinit normally runs on main.
            // Hop explicitly to satisfy the checker — both the read and
            // the AppKit call have to be inside the isolation scope.
            MainActor.assumeIsolated {
                if let m = monitor { NSEvent.removeMonitor(m) }
            }
        }
    }
}
