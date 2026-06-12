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
mod serve;

use serve::handle_connection;

/// Concurrent-connection cap (each connection = one thread).
const MAX_CONNECTIONS: usize = 8;

static INFLIGHT: AtomicUsize = AtomicUsize::new(0);

fn main() {
    let mut args = std::env::args().skip(1);
    let socket_path = match (args.next().as_deref(), args.next()) {
        (Some("--socket"), Some(path)) => path,
        _ => {
            eprintln!("usage: mdv-serve --socket <path>");
            std::process::exit(2);
        }
    };
    // A stale socket file from a previous run refuses the bind; remove it
    // (the path is ours by contract).
    let _ = std::fs::remove_file(&socket_path);
    let listener = match UnixListener::bind(&socket_path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("mdv-serve: bind {socket_path}: {e}");
            std::process::exit(1);
        }
    };
    eprintln!("mdv-serve: listening on {socket_path}");
    for conn in listener.incoming() {
        let Ok(stream) = conn else { continue };
        if INFLIGHT.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
            INFLIGHT.fetch_sub(1, Ordering::SeqCst);
            drop(stream); // over cap: refuse by hangup (client retries)
            continue;
        }
        std::thread::spawn(move || {
            let _ = handle_connection(&stream);
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
