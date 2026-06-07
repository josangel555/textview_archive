import Foundation

/// Leading-edge frame-throttle DECISION logic (pure; no timers, no actor).
///
/// The terminal coalesces a burst of PTY output into at most one re-render
/// per frame. The throttle that drives that must be **leading-edge** for
/// interactive latency: the first event after an idle gap has to paint
/// IMMEDIATELY, otherwise every keystroke echo is delayed a whole frame
/// before it appears — the "typing is slow" symptom of a purely
/// trailing-edge throttle (sleep first, then emit).
///
/// This struct holds only the decision state so it stays headlessly
/// testable, decoupled from the `Task.sleep` plumbing in `TerminalModel`.
/// The owner drives the clock:
///   1. On each event, call `requestFrame()` and emit a frame iff it
///      returns `.emitNow` (this also opens a cooldown window).
///   2. When the cooldown you opened elapses, call `cooldownElapsed()`;
///      emit one trailing frame iff it returns `true` (flushing whatever
///      arrived mid-cooldown) — which itself opens a fresh window.
public struct FrameThrottle: Sendable {
    /// True while inside the min-interval window after a frame was emitted.
    private var inCooldown = false
    /// True when output arrived during a cooldown and a catch-up frame is
    /// owed when that cooldown ends.
    private var trailingPending = false

    public init() {}

    public enum Decision: Sendable, Equatable {
        /// Emit a frame now (and start a cooldown window).
        case emitNow
        /// Suppressed — coalesced into the in-flight cooldown's trailing frame.
        case coalesced
    }

    /// An event (PTY output / resize) wants to show a frame.
    public mutating func requestFrame() -> Decision {
        if inCooldown {
            trailingPending = true
            return .coalesced
        }
        inCooldown = true
        return .emitNow
    }

    /// The cooldown opened by the last emitted frame has elapsed. Returns
    /// `true` when a trailing frame is owed (output landed mid-cooldown):
    /// the caller emits it and the throttle stays in cooldown for that
    /// frame's own window. Returns `false` when nothing accumulated — the
    /// throttle goes idle, so the next `requestFrame()` is a fresh leading
    /// edge that emits immediately.
    public mutating func cooldownElapsed() -> Bool {
        if trailingPending {
            trailingPending = false
            return true                 // stay in cooldown for the trailing frame
        }
        inCooldown = false
        return false
    }

    /// Inspection: currently within a cooldown window (no new leading edge
    /// would fire). Test-facing.
    public var isThrottling: Bool { inCooldown }
}
