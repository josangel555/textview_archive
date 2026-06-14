import AppKit
import SwiftUI
import ViewerCore

/// App-wide monitor for the IntelliJ-style **double-Shift → command palette**
/// gesture (TSK-707). Mirrors `SidebarKeyMonitor`: an otherwise-empty
/// `NSViewRepresentable` that installs a local `NSEvent` monitor and routes the
/// firing decision through a pure, unit-testable core
/// (``DoubleTapModifierDetector`` + ``DoubleShiftMonitor/detectorEvent`` here).
/// It is purely OBSERVATIONAL — it never consumes the event, so Shift keeps
/// working normally for typing/selection.
struct DoubleShiftMonitor: NSViewRepresentable {
    /// Whether the gesture is armed (mounted-but-inactive simply removes the
    /// monitor). Always true today; a future preference can gate it.
    let isActive: Bool
    /// Invoked on the main actor when a clean double-tap completes.
    let onFire: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onFire = onFire
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onFire = onFire
        context.coordinator.setActive(isActive)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Pure mapping from a raw event to a ``DoubleTapModifierDetector/Event``.
    /// Extracted so the monitor's wiring is host-testable without a window:
    ///   - a non-modifier key-down (`isFlagsChanged == false`) is a `reset`
    ///     (it breaks a clean double-tap — this is what stops typing capitals
    ///     from firing);
    ///   - a bare Shift down/up (no Command/Option/Control) is
    ///     `modifierDown`/`modifierUp`;
    ///   - Shift pressed together with another modifier (a chord) resets;
    ///   - an unrelated change with Shift state unchanged (e.g. a Caps-Lock
    ///     toggle) is ignored (`nil` — no state change).
    /// `deviceFlags` must already be masked to `deviceIndependentFlagsMask`.
    static func detectorEvent(
        isFlagsChanged: Bool,
        deviceFlags: NSEvent.ModifierFlags,
        wasShiftDown: Bool,
        timestamp: TimeInterval
    ) -> DoubleTapModifierDetector.Event? {
        guard isFlagsChanged else { return .reset }
        let chordMods: NSEvent.ModifierFlags = [.command, .option, .control]
        let otherMods = deviceFlags.intersection(chordMods)
        let shiftDown = deviceFlags.contains(.shift)
        if shiftDown != wasShiftDown {
            if shiftDown {
                return otherMods.isEmpty ? .modifierDown(at: timestamp) : .reset
            }
            return .modifierUp
        }
        return otherMods.isEmpty ? nil : .reset
    }

    @MainActor
    final class Coordinator {
        var monitor: Any?
        var onFire: (() -> Void)?
        private var detector = DoubleTapModifierDetector()
        private var wasShiftDown = false

        func setActive(_ active: Bool) {
            if active && monitor == nil {
                detector.reset()
                wasShiftDown = false
                monitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.keyDown, .flagsChanged]
                ) { [weak self] event in
                    // Pull primitives out of the (non-Sendable) NSEvent before
                    // entering the isolation scope — same pattern as
                    // SidebarKeyMonitor.
                    let isFlags = event.type == .flagsChanged
                    let device = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    let ts = event.timestamp
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        let ev = DoubleShiftMonitor.detectorEvent(
                            isFlagsChanged: isFlags,
                            deviceFlags: device,
                            wasShiftDown: self.wasShiftDown,
                            timestamp: ts
                        )
                        if isFlags { self.wasShiftDown = device.contains(.shift) }
                        if let ev, self.detector.handle(ev) {
                            self.onFire?()
                        }
                    }
                    // Always pass the event through — observation only.
                    return event
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
