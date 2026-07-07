//! `mdv-serve` — the machine-API daemon binary (TSK-653): a thin main() over
//! the `mdvcore_serve` library (see `src/lib.rs` for the protocol surface).
//! The ssh tunnel is the auth/confidentiality boundary (owner ruling
//! 2026-06-12) — this binary only ever binds a filesystem socket path (or
//! inherits one from launchd, TSK-1553).

use std::os::unix::net::UnixListener;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

use mdvcore_serve::serve::handle_connection;
use mdvcore_serve::{fs, lifecycle, transcript_list};

/// Concurrent-connection cap (each connection = one thread).
const MAX_CONNECTIONS: usize = 8;

static INFLIGHT: AtomicUsize = AtomicUsize::new(0);

/// Activity GENERATION — bumped on every accept and every disconnect. The
/// idle ticker doesn't read a wall clock (the clippy Clock-port discipline:
/// time is a parameter); its own 60 s sleeps ARE the clock — it accumulates
/// idle time only across ticks where this generation did not move.
static ACTIVITY_GEN: AtomicU64 = AtomicU64::new(0);

fn main() {
    let mut socket_path: Option<String> = None;
    let mut root: Option<String> = None;
    let mut claude_dir: Option<String> = None;
    let mut args = std::env::args().skip(1);
    while let Some(flag) = args.next() {
        match (flag.as_str(), args.next()) {
            ("--socket", Some(v)) => socket_path = Some(v),
            ("--root", Some(v)) => root = Some(v),
            ("--claude-dir", Some(v)) => claude_dir = Some(v),
            _ => {
                eprintln!("usage: mdv-serve --socket <path> [--root <dir>] [--claude-dir <dir>]");
                std::process::exit(2);
            }
        }
    }
    let Some(socket_path) = socket_path else {
        eprintln!("usage: mdv-serve --socket <path> [--root <dir>] [--claude-dir <dir>]");
        std::process::exit(2);
    };
    let fs_ctx = match fs::FsCtx::new(root.as_deref()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("mdv-serve: --root: {e}");
            std::process::exit(1);
        }
    };
    let transcript_ctx = transcript_list::TranscriptCtx::new(claude_dir.as_deref());
    // TSK-1553 (daemon s1): under a LaunchAgent, launchd owns the socket
    // (the plist `Sockets` key, name "mdv-serve") and hands us the listening
    // fd — single-instance guaranteed by launchd. A plain CLI run gets no
    // activation fds and falls back to self-binding — today's path, unchanged.
    let activated = mdvcore_ffi::launchd::launchd_activation_listeners("mdv-serve")
        .into_iter()
        .next();
    let (listener, origin) = match lifecycle::select_listener(activated, || {
        // A stale socket file from a previous run refuses the bind; remove it
        // (the path is ours by contract — launchd-owned paths never get here).
        let _ = std::fs::remove_file(&socket_path);
        UnixListener::bind(&socket_path)
    }) {
        Ok(pair) => pair,
        Err(e) => {
            eprintln!("mdv-serve: bind {socket_path}: {e}");
            std::process::exit(1);
        }
    };
    if origin == lifecycle::ListenerOrigin::Launchd {
        eprintln!("mdv-serve: launchd-activated listener (socket owned by launchd)");
    }

    // TSK-1554 (daemon s2): the per-minute idle ticker — ONLY for a
    // launchd-activated run, where an idle exit(0) is safe by design (the
    // next connect makes launchd respawn us on the socket it owns). A
    // SELF-BOUND run never self-exits: nothing would respawn it, and the
    // socket file would be left dangling. dirty_sessions is 0 today —
    // mdv-serve carries no stateful doc sessions yet (that's the doc.*
    // family, S8/TSK-1523); when it does, the count plugs in here and the
    // flush closure becomes the snapshot write. The whole eligibility path
    // (pins, threshold, flush-failure abort) is host-tested in
    // lifecycle::idle_tick; this loop's own 60 s sleeps are its clock
    // (idle accumulates only across ticks where ACTIVITY_GEN didn't move —
    // a disconnect resets the count, so idleness runs from the last
    // disconnect, not the last accept).
    if origin == lifecycle::ListenerOrigin::Launchd {
        std::thread::spawn(move || {
            const TICK_MS: u64 = 60_000;
            let mut last_generation = ACTIVITY_GEN.load(Ordering::SeqCst);
            let mut idle_ms: u64 = 0;
            loop {
                std::thread::sleep(std::time::Duration::from_millis(TICK_MS));
                let generation = ACTIVITY_GEN.load(Ordering::SeqCst);
                if generation == last_generation {
                    idle_ms = idle_ms.saturating_add(TICK_MS);
                } else {
                    last_generation = generation;
                    idle_ms = 0;
                }
                let state = lifecycle::IdleState {
                    connections: INFLIGHT.load(Ordering::SeqCst),
                    dirty_sessions: 0,
                    idle_ms,
                };
                if lifecycle::idle_tick(state, lifecycle::IDLE_THRESHOLD_MS, || true) {
                    eprintln!(
                        "mdv-serve: idle {idle_ms} ms with no connections; exiting (launchd re-arms)"
                    );
                    std::process::exit(0);
                }
            }
        });
    }

    // TSK-1555 (daemon s3): the retire watcher — an ACCEPTED daemon.retire
    // (a newer client's version-skew handover, arbitrated in
    // handle_connection) flags lifecycle::retire_requested; this thread
    // notices and exits 0 so launchd respawns the UPDATED binary on the
    // requester's retry connect. A flag + watcher rather than in-handler
    // exit keeps the accept path testable. Runs on BOTH origins (retire is
    // an EXPLICIT request, unlike the time-based idle exit).
    std::thread::spawn(|| loop {
        std::thread::sleep(std::time::Duration::from_millis(250));
        if lifecycle::retire_requested() {
            eprintln!("mdv-serve: retire accepted (version handover); exiting for respawn");
            std::process::exit(0);
        }
    });

    eprintln!("mdv-serve: listening on {socket_path}");
    for conn in listener.incoming() {
        let Ok(stream) = conn else { continue };
        ACTIVITY_GEN.fetch_add(1, Ordering::SeqCst);
        if INFLIGHT.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
            INFLIGHT.fetch_sub(1, Ordering::SeqCst);
            drop(stream); // over cap: refuse by hangup (client retries)
            continue;
        }
        let ctx = fs_ctx.clone();
        let tctx = transcript_ctx.clone();
        std::thread::spawn(move || {
            let _ = handle_connection(&stream, &ctx, &tctx);
            INFLIGHT.fetch_sub(1, Ordering::SeqCst);
            // Idle counts from the last DISCONNECT: bump the generation so
            // the ticker restarts its idle accumulation.
            ACTIVITY_GEN.fetch_add(1, Ordering::SeqCst);
        });
    }
}
