import AppKit
import SwiftUI

/// Palette-scoped **Esc → dismiss** monitor (TSK-1592). Mounted (as a
/// zero-size background) ONLY while the command palette is presented, it
/// installs a local key-down monitor that catches a bare Esc and dismisses the
/// palette, then consumes the event.
///
/// Why a monitor instead of the header ✕ button's `.keyboardShortcut(.escape)`:
/// when the palette is in a sub-mode whose query field holds text (e.g. `#`
/// in-file / `@` symbol jump), the focused field editor swallows Esc as
/// `cancelOperation:` before SwiftUI routes it to the button's key-equivalent —
/// so Esc did nothing and the palette stayed open (owner report 2026-07-21: "type
/// `#`, press Esc, it doesn't disappear"). A local `NSEvent` monitor sees the
/// key-down ahead of the field editor, so the dismiss is reliable in every mode.
///
/// Scoped to the presented state so it never shadows Esc elsewhere; it does not
/// conflict with `EscFocusMonitor` (which deliberately no-ops while the palette
/// is up).
struct PaletteEscMonitor: NSViewRepresentable {
    /// Fires on the main actor for a bare Esc while mounted.
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onEscape = onEscape
        context.coordinator.setActive(true)
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.setActive(false)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var monitor: Any?
        var onEscape: (() -> Void)?

        func setActive(_ active: Bool) {
            if active && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    // Esc (keyCode 53), no modifiers.
                    guard event.keyCode == 53,
                          event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
                    else { return event }
                    MainActor.assumeIsolated { self?.onEscape?() }
                    return nil   // consume — the palette owns Esc while presented
                }
            } else if !active, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit {
            MainActor.assumeIsolated {
                if let m = monitor { NSEvent.removeMonitor(m) }
            }
        }
    }
}
