import Foundation

/// Detects an IntelliJ-style "double-tap a modifier" gesture — double-Shift
/// opens the command palette (TSK-707).
///
/// Pure and host-testable: it consumes a stream of modifier/key transitions
/// carrying monotonic timestamps and reports the instant a clean double-tap
/// completes. The AppKit `flagsChanged` monitor (`DoubleShiftMonitor` in
/// ViewerUI) feeds it real `NSEvent` transitions; keeping the firing logic
/// here means it can be unit-tested without a window, an event loop, or a
/// clock.
///
/// The gesture is: the tracked modifier (Shift) goes **down → up → down**, with
/// the two key-DOWN edges no more than ``interval`` apart, and with **nothing
/// in between** — no other key, no other modifier. That last rule
/// (``Event/reset``) is what keeps the gesture from mis-firing during normal
/// typing: pressing Shift to type a capital letter immediately sees the letter
/// key (a `reset`), so the sequence never reaches a second clean tap.
public struct DoubleTapModifierDetector {
    /// Maximum seconds between the two taps' key-DOWN edges. A second press
    /// later than this is treated as a fresh first tap, not a completion.
    public let interval: TimeInterval

    /// Transitions the detector understands. The monitor maps raw events to
    /// these: a *bare* Shift press/release becomes `modifierDown`/`modifierUp`;
    /// anything else that would break a clean double-tap (a non-modifier key,
    /// another modifier joining, Shift pressed together with another modifier)
    /// becomes `reset`.
    public enum Event: Equatable {
        /// The tracked modifier went down, alone, at `time` (seconds, monotonic).
        case modifierDown(at: TimeInterval)
        /// The tracked modifier was released.
        case modifierUp
        /// Anything that breaks a clean double-tap — resets to the start.
        case reset
    }

    private enum State: Equatable {
        case idle
        /// First tap's key is currently held (pressed at `at`, not yet released).
        case firstDown(at: TimeInterval)
        /// First tap completed cleanly (down→up); awaiting the second press.
        case firstReleased(firstDownAt: TimeInterval)
    }

    private var state: State = .idle

    public init(interval: TimeInterval = 0.30) {
        self.interval = interval
    }

    /// Feed one transition. Returns `true` exactly once, on the second clean
    /// key-DOWN within ``interval`` of the first. On fire the detector resets,
    /// so a triple-tap fires only once (the third press starts a fresh first
    /// tap).
    public mutating func handle(_ event: Event) -> Bool {
        switch event {
        case .reset:
            state = .idle
            return false

        case .modifierDown(let now):
            if case .firstReleased(let firstDownAt) = state, now - firstDownAt <= interval {
                state = .idle
                return true
            }
            // Otherwise this press starts (or restarts) the gesture.
            state = .firstDown(at: now)
            return false

        case .modifierUp:
            if case .firstDown(let downAt) = state {
                // A clean first tap: nothing interrupted between down and up.
                state = .firstReleased(firstDownAt: downAt)
            } else {
                state = .idle
            }
            return false
        }
    }

    /// Reset to the initial state (e.g. when the monitor is (re)installed or
    /// the key window changes).
    public mutating func reset() {
        state = .idle
    }
}
