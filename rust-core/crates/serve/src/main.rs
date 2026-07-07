//! `mdv-serve` — the machine-API daemon binary (TSK-653): a thin main() over
//! the `mdvcore_serve` library (see `src/lib.rs` for the protocol surface).
//! The ssh tunnel is the auth/confidentiality boundary (owner ruling
//! 2026-06-12) — this binary only ever binds a filesystem socket path (or
//! inherits one from launchd, TSK-1553).

use std::os::unix::net::UnixListener;
use std::sync::atomic::{AtomicUsize, Ordering};

use mdvcore_serve::serve::handle_connection;
use mdvcore_serve::{fs, lifecycle, transcript_list};

/// Concurrent-connection cap (each connection = one thread).
const MAX_CONNECTIONS: usize = 8;

static INFLIGHT: AtomicUsize = AtomicUsize::new(0);

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
    eprintln!("mdv-serve: listening on {socket_path}");
    for conn in listener.incoming() {
        let Ok(stream) = conn else { continue };
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
        });
    }
}
