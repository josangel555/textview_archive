import Foundation

/// DAEMON_LIFECYCLE_DESIGN.md D8 — the reconnect timing policy the App's
/// remote-core seam needs (TSK-1556). Today `MCPSocketBridge` hard-codes the
/// same "250 ms → 4 s capped, reconnect forever" schedule inline, and
/// `RemoteCoreAttach` has NO reconnect at all (launch-time-only). This is the
/// pure, host-tested policy both consume: the per-attempt delay (capped
/// exponential) and the degrade decision (fall back to the in-process core
/// only AFTER a bounded window — never silently, per the design).
///
/// Pure value type; the actual sleep/reconnect loop, request queue, and status
/// banner are the caller's (the Swift transport-seam wiring is the tail).
public struct ReconnectBackoff: Equatable, Sendable {
    /// First-attempt delay (ms). Fast enough that an app relaunch reattaches
    /// almost immediately.
    public let baseMs: UInt64
    /// Ceiling (ms). The delay doubles each attempt up to this cap, then holds.
    public let capMs: UInt64
    /// How long (ms of continuous down-time) to keep retrying on the remote
    /// transport before degrading to the in-process core. `nil` = never
    /// degrade (retry forever — the MCP-bridge behavior).
    public let degradeAfterMs: UInt64?

    public init(baseMs: UInt64 = 250, capMs: UInt64 = 4_000, degradeAfterMs: UInt64? = 30_000) {
        self.baseMs = baseMs
        self.capMs = capMs
        self.degradeAfterMs = degradeAfterMs
    }

    /// The delay before reconnect `attempt` (0-indexed): `base · 2^attempt`,
    /// capped at `capMs`. Overflow-safe — a huge attempt count saturates to
    /// the cap instead of wrapping.
    public func delayMs(attempt: Int) -> UInt64 {
        guard attempt > 0 else { return min(baseMs, capMs) }
        // Stop doubling once we'd exceed the cap; also guards against shifting
        // past 64 bits.
        var delay = baseMs
        for _ in 0..<attempt {
            // Saturating double; break as soon as we hit/exceed the cap.
            if delay >= capMs { return capMs }
            delay = delay.multipliedReportingOverflow(by: 2).overflow
                ? capMs
                : min(delay * 2, capMs)
        }
        return delay
    }

    /// Whether to degrade to the in-process core: the remote has been down for
    /// `elapsedMs` continuous, and that meets/exceeds the degrade window.
    /// Always `false` when `degradeAfterMs` is nil (retry forever).
    public func shouldDegradeToLocal(elapsedMs: UInt64) -> Bool {
        guard let window = degradeAfterMs else { return false }
        return elapsedMs >= window
    }
}
