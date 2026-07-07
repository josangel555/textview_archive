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

/// One composed tick of the idle-exit loop: decide, and when eligible run
/// `flush` — returns `true` (caller exits 0) only when the decision said
/// [`IdleDecision::ReadyToFlush`] AND the flush succeeded. A failed flush
/// aborts (per [`resolve_exit`]); every stay-reason returns `false`. The
/// per-minute ticker in `main` is a thin loop over this, so the whole
/// exit-eligibility path is host-tested here.
pub fn idle_tick(
    state: IdleState,
    threshold_ms: u64,
    flush: impl FnOnce() -> bool,
) -> bool {
    match idle_decision(state, threshold_ms) {
        IdleDecision::ReadyToFlush => resolve_exit(flush()) == ExitResolution::Exit,
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// Listener acquisition — launchd activation vs self-bind
// (DAEMON_LIFECYCLE_DESIGN.md D2, TSK-1553)
// ---------------------------------------------------------------------------

/// Where the listening socket came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListenerOrigin {
    /// launchd owns the socket (the plist `Sockets` key) and handed us the
    /// already-listening fd — single-instance is guaranteed by launchd.
    Launchd,
    /// We bound the socket path ourselves — the dev/CLI/Linux path
    /// (today's behavior, unchanged).
    SelfBind,
}

/// The fd-inheritance branch: prefer a launchd-activated listener; fall back
/// to `bind` (self-binding) only when activation yielded nothing. Injectable
/// on both sides, so the precedence is host-tested with real listeners on
/// temp paths — no launchd required.
pub fn select_listener(
    launchd: Option<std::os::unix::net::UnixListener>,
    bind: impl FnOnce() -> std::io::Result<std::os::unix::net::UnixListener>,
) -> std::io::Result<(std::os::unix::net::UnixListener, ListenerOrigin)> {
    if let Some(l) = launchd {
        return Ok((l, ListenerOrigin::Launchd));
    }
    bind().map(|l| (l, ListenerOrigin::SelfBind))
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

// --- the retire wiring state (TSK-1555 tail) ---

use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

/// Wire versions of the currently-attached (hello-accepted) connections —
/// the `other_clients` input to [`retire_decision`]. Connections register
/// after a successful hello and deregister on close.
static CLIENT_VERSIONS: Mutex<Vec<u64>> = Mutex::new(Vec::new());

/// Set once a `daemon.retire` was ACCEPTED; the binary's watcher thread
/// polls this and exits 0 (launchd then respawns the updated binary on the
/// next connect). A flag + watcher rather than in-handler `process::exit` so
/// the accept path stays TESTABLE (a test asserting the flag doesn't kill
/// the test process).
pub(crate) static RETIRE_REQUESTED: AtomicBool = AtomicBool::new(false);

/// Record an attached client's hello wire version.
pub fn register_client(version: u64) {
    if let Ok(mut v) = CLIENT_VERSIONS.lock() {
        v.push(version);
    }
}

/// Remove ONE instance of an attached client's version (connection closed).
pub fn deregister_client(version: u64) {
    if let Ok(mut v) = CLIENT_VERSIONS.lock()
        && let Some(i) = v.iter().position(|&x| x == version)
    {
        v.swap_remove(i);
    }
}

/// The versions of the currently-attached connections.
pub fn attached_versions() -> Vec<u64> {
    CLIENT_VERSIONS.lock().map(|v| v.clone()).unwrap_or_default()
}

/// Flag the accepted retire (the watcher exits the process).
pub fn request_retire() {
    RETIRE_REQUESTED.store(true, Ordering::SeqCst);
}

/// Whether an accepted retire is pending (polled by the binary's watcher).
pub fn retire_requested() -> bool {
    RETIRE_REQUESTED.load(Ordering::SeqCst)
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

    // --- idle_tick composition (TSK-1554 wiring) ---

    #[test]
    fn tick_exits_only_on_ready_plus_successful_flush() {
        // Eligible + flush ok → exit.
        assert!(idle_tick(st(0, 0, IDLE_THRESHOLD_MS), IDLE_THRESHOLD_MS, || true));
        // Eligible but the flush FAILS (disk full) → abort, stay.
        assert!(!idle_tick(st(0, 0, IDLE_THRESHOLD_MS), IDLE_THRESHOLD_MS, || false));
    }

    #[test]
    fn tick_never_runs_flush_when_pinned() {
        // A connection/dirty pin must not even ATTEMPT the flush.
        let mut flushed = false;
        assert!(!idle_tick(st(1, 0, IDLE_THRESHOLD_MS), IDLE_THRESHOLD_MS, || {
            flushed = true;
            true
        }));
        assert!(!flushed, "flush must not run while a connection pins the process");
        let mut flushed2 = false;
        assert!(!idle_tick(st(0, 3, IDLE_THRESHOLD_MS), IDLE_THRESHOLD_MS, || {
            flushed2 = true;
            true
        }));
        assert!(!flushed2, "flush must not run while dirty sessions pin the process");
    }

    // --- listener acquisition (TSK-1553) ---

    fn temp_sock(tag: &str) -> std::path::PathBuf {
        // Unique per process; short enough for the sun_path limit.
        std::env::temp_dir().join(format!("mdv-1553-{}-{tag}.sock", std::process::id()))
    }

    #[test]
    fn launchd_listener_wins_and_bind_is_not_called() {
        let a = temp_sock("a");
        let _ = std::fs::remove_file(&a);
        let launchd = std::os::unix::net::UnixListener::bind(&a).unwrap();
        let mut bind_ran = false;
        let (l, origin) = select_listener(Some(launchd), || {
            bind_ran = true;
            Err(std::io::Error::other("must not run"))
        })
        .unwrap();
        assert!(!bind_ran, "bind must not run when launchd handed us a listener");
        assert_eq!(origin, ListenerOrigin::Launchd);
        assert!(l.local_addr().is_ok());
        let _ = std::fs::remove_file(&a);
    }

    #[test]
    fn no_activation_falls_back_to_self_bind() {
        let b = temp_sock("b");
        let _ = std::fs::remove_file(&b);
        let path = b.clone();
        let (l, origin) =
            select_listener(None, || std::os::unix::net::UnixListener::bind(&path)).unwrap();
        assert_eq!(origin, ListenerOrigin::SelfBind);
        assert!(l.local_addr().is_ok());
        let _ = std::fs::remove_file(&b);
    }

    #[test]
    fn bind_failure_propagates_when_no_activation() {
        let err = select_listener(None, || {
            Err(std::io::Error::other("bind refused"))
        });
        assert!(err.is_err());
    }
}
