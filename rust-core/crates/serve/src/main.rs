//! `mdv-serve` — the machine-API daemon (TSK-653), implementing
//! `docs/REMOTE_PROTOCOL.md` v1: u32-LE length-prefixed MessagePack
//! envelopes over a UNIX socket. The ssh tunnel is the auth/confidentiality
//! boundary (owner ruling 2026-06-12) — this binary only ever binds a
//! filesystem socket path.
//!
//! V1 surface: `hello` (wire-version hard-close + capability mask), `ping`,
//! and the seven stateless engine methods, dispatched DIRECTLY to the same
//! `*_wire` functions the FFI exports call (no FFI hop server-side). The
//! envelope already carries subscription/event fields; the fs family and
//! the push path land with TSK-654.

use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::atomic::{AtomicUsize, Ordering};

mod envelope;
mod fs;
mod git;
mod lifecycle;
mod search;
mod serve;
mod transcript_list;
mod watch;

use serve::handle_connection;

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

/// Read one length-prefixed frame (None = clean EOF before a frame started).
pub(crate) fn read_frame(stream: &mut &UnixStream) -> std::io::Result<Option<Vec<u8>>> {
    let mut len_buf = [0u8; 4];
    match stream.read_exact(&mut len_buf) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }
    let len = u32::from_le_bytes(len_buf) as usize;
    if len > serve::MAX_FRAME_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "frame exceeds the 16 MiB ceiling",
        ));
    }
    let mut body = vec![0u8; len];
    stream.read_exact(&mut body)?;
    Ok(Some(body))
}

/// Write one length-prefixed frame.
pub(crate) fn write_frame(stream: &mut &UnixStream, body: &[u8]) -> std::io::Result<()> {
    let len = u32::try_from(body.len())
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "frame too large"))?;
    stream.write_all(&len.to_le_bytes())?;
    stream.write_all(body)?;
    stream.flush()
}
