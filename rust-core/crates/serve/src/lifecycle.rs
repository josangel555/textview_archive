//! DAEMON_LIFECYCLE_DESIGN.md D3 — idle-exit with the dirty guard (TSK-1554).
//!
//! `mdv-serve` should not linger forever after its clients go away, but it
//! must NEVER exit while unsaved work exists. This module is the PURE decision
//! over a snapshot of liveness inputs (connection count, dirty-session count,
//! idle duration) — the per-minute tick loop, the actual snapshot flush, and
//! `std::process::exit` are the caller's job (the s2 wiring). Injecting the
//! idle duration + threshold keeps this sans-clock and fully host-tested.
//!
//! The consumer (the tick loop) is a separate slice; until it lands these are
//! referenced only by tests.
#![allow(dead_code)]

/// The design's idle threshold: 15 minutes with no connections and no dirty
/// sessions before the daemon is eligible to flush + exit.
pub const IDLE_THRESHOLD_MS: u64 = 15 * 60 * 1000;

/// A snapshot of the daemon's liveness inputs at one tick.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IdleState {
    /// Currently-attached client connections.
    pub connections: usize,
    /// Sessions with unsaved (dirty) content.
    pub dirty_sessions: usize,
    /// Milliseconds since the last activity (connection or request).
    pub idle_ms: u64,
}

/// The tick decision — stay (with a reason) or become eligible to exit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdleDecision {
    /// Keep running — a client is attached.
    StayConnected,
    /// Keep running — a dirty session PINS the process. The
    /// `dirty ⇒ pinned` law (doc_registry eviction) extended to process
    /// lifetime: an idle exit must never drop unpersisted work.
    StayDirty,
    /// Keep running — idle, but not yet past the threshold.
    StayNotIdleYet,
    /// Eligible to exit: no connections, no dirty sessions, idle past the
    /// threshold. The caller MUST flush snapshots first, then feed the flush
    /// outcome to [`resolve_exit`].
    ReadyToFlush,
}

/// The pure per-tick decision. Precedence: a live connection wins, then a
/// dirty session (the pin), then the idle-threshold check.
pub fn idle_decision(state: IdleState, threshold_ms: u64) -> IdleDecision {
    if state.connections > 0 {
        IdleDecision::StayConnected
    } else if state.dirty_sessions > 0 {
        IdleDecision::StayDirty
    } else if state.idle_ms < threshold_ms {
        IdleDecision::StayNotIdleYet
    } else {
        IdleDecision::ReadyToFlush
    }
}

/// The post-flush resolution. After [`IdleDecision::ReadyToFlush`] the caller
/// flushes snapshots and calls this with the result: a FAILED flush (e.g.
/// disk full) ABORTS the exit — the process stays alive rather than exit
/// having dropped state it could not persist.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExitResolution {
    /// Flush succeeded — exit 0.
    Exit,
    /// Flush failed — abort the exit, keep running (re-check next tick).
    AbortFlushFailed,
}

/// Resolve the exit after the flush attempt.
pub fn resolve_exit(flush_ok: bool) -> ExitResolution {
    if flush_ok {
        ExitResolution::Exit
    } else {
        ExitResolution::AbortFlushFailed
    }
}

// ---------------------------------------------------------------------------
// daemon.retire — version-skew handover (DAEMON_LIFECYCLE_DESIGN.md D4,
// TSK-1555)
// ---------------------------------------------------------------------------

/// The `daemon.retire` accept/refuse decision. Scenario: the app updates, its
/// NEWER client dials the still-running OLDER daemon, the hello reports wire
/// skew — instead of a dead end, the new client asks the daemon to RETIRE
/// (flush all sessions, close the listener, exit 0) so the client's retry
/// connect makes launchd spawn the UPDATED binary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RetireDecision {
    /// Retire: flush everything, close the listener, exit 0. The requester
    /// (and any same-expectation stragglers) re-dial and reach the new binary.
    Accept,
    /// Refuse: the requester is NOT newer than this daemon. An OLDER client
    /// meeting a NEWER daemon keeps the existing hello hard-close (the
    /// upgrade direction only ever retires forward — an old binary must not
    /// be able to shoot down a new daemon).
    RefuseNotNewer,
    /// Refuse: another attached client expects a DIFFERENT wire version than
    /// the requester (first-writer-wins — the attached population using this
    /// daemon at its current version keeps it; stragglers re-dial when their
    /// own connection closes naturally).
    RefuseConflictingClients,
}

/// Decide a `daemon.retire` request. `requester` / `server` are wire
/// versions; `other_clients` are the wire versions of the OTHER currently
/// attached connections (the requester excluded).
pub fn retire_decision(requester: u64, server: u64, other_clients: &[u64]) -> RetireDecision {
    if requester <= server {
        return RetireDecision::RefuseNotNewer;
    }
    if other_clients.iter().any(|&v| v != requester) {
        return RetireDecision::RefuseConflictingClients;
    }
    RetireDecision::Accept
}

#[cfg(test)]
mod tests {
    use super::*;

    fn st(conn: usize, dirty: usize, idle_ms: u64) -> IdleState {
        IdleState { connections: conn, dirty_sessions: dirty, idle_ms }
    }

    #[test]
    fn connection_pins_even_when_idle_past_threshold() {
        let d = idle_decision(st(1, 0, IDLE_THRESHOLD_MS * 10), IDLE_THRESHOLD_MS);
        assert_eq!(d, IdleDecision::StayConnected);
    }

    #[test]
    fn dirty_pins_even_when_idle_and_unconnected() {
        // No connections, idle way past threshold, but a dirty session → stay.
        let d = idle_decision(st(0, 1, IDLE_THRESHOLD_MS * 10), IDLE_THRESHOLD_MS);
        assert_eq!(d, IdleDecision::StayDirty);
    }

    #[test]
    fn connection_wins_over_dirty() {
        // Both present → the connection reason is reported (either would stay).
        let d = idle_decision(st(2, 3, 0), IDLE_THRESHOLD_MS);
        assert_eq!(d, IdleDecision::StayConnected);
    }

    #[test]
    fn idle_but_not_yet_past_threshold_stays() {
        let d = idle_decision(st(0, 0, IDLE_THRESHOLD_MS - 1), IDLE_THRESHOLD_MS);
        assert_eq!(d, IdleDecision::StayNotIdleYet);
    }

    #[test]
    fn eligible_at_exactly_threshold() {
        let d = idle_decision(st(0, 0, IDLE_THRESHOLD_MS), IDLE_THRESHOLD_MS);
        assert_eq!(d, IdleDecision::ReadyToFlush);
    }

    #[test]
    fn flush_success_exits_failure_aborts() {
        assert_eq!(resolve_exit(true), ExitResolution::Exit);
        assert_eq!(resolve_exit(false), ExitResolution::AbortFlushFailed);
    }

    #[test]
    fn threshold_is_fifteen_minutes() {
        assert_eq!(IDLE_THRESHOLD_MS, 900_000);
    }

    // --- daemon.retire (TSK-1555) ---

    #[test]
    fn retire_newer_client_alone_accepts() {
        // The upgrade handover: client v3 meets daemon v2, no other clients.
        assert_eq!(retire_decision(3, 2, &[]), RetireDecision::Accept);
    }

    #[test]
    fn retire_same_version_refuses() {
        // No skew → nothing to hand over; a same-version retire is refused.
        assert_eq!(retire_decision(2, 2, &[]), RetireDecision::RefuseNotNewer);
    }

    #[test]
    fn retire_older_client_refuses() {
        // Older-client-newer-daemon keeps the hard-close; an old binary must
        // not be able to shoot down a new daemon.
        assert_eq!(retire_decision(1, 2, &[]), RetireDecision::RefuseNotNewer);
    }

    #[test]
    fn retire_with_conflicting_attached_client_refuses() {
        // A v2 client is still attached and happy — first-writer-wins; the
        // v3 requester must wait for it to drain.
        assert_eq!(
            retire_decision(3, 2, &[2]),
            RetireDecision::RefuseConflictingClients
        );
    }

    #[test]
    fn retire_with_same_expectation_stragglers_accepts() {
        // Every other attached client ALSO expects v3 (they're all the
        // updated binary re-dialing) → retire proceeds; they re-dial on close.
        assert_eq!(retire_decision(3, 2, &[3, 3]), RetireDecision::Accept);
    }

    #[test]
    fn retire_mixed_population_refuses() {
        assert_eq!(
            retire_decision(3, 2, &[3, 2, 3]),
            RetireDecision::RefuseConflictingClients
        );
    }
}
