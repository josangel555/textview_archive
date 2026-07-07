//! `mdvcore-serve` — the machine-API daemon library (TSK-653/TSK-1557),
//! implementing `docs/REMOTE_PROTOCOL.md` v1: u32-LE length-prefixed
//! MessagePack envelopes over a UNIX socket.
//!
//! Split lib/bin (DAEMON_LIFECYCLE_DESIGN.md D7): the `mdv-serve` binary is a
//! thin main() over this library, and CLIENTS (mdv-tui, mdv-web thin-client
//! mode) import the same envelope + the [`transport`] seam — one protocol
//! implementation, no client-side duplication to drift.

pub mod envelope;
pub mod fs;
pub mod git;
pub mod lifecycle;
pub mod search;
pub mod serve;
pub mod transcript_list;
pub mod transport;
pub mod watch;

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;

/// Read one length-prefixed frame (None = clean EOF before a frame started).
pub fn read_frame(stream: &mut &UnixStream) -> std::io::Result<Option<Vec<u8>>> {
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
pub fn write_frame(stream: &mut &UnixStream, body: &[u8]) -> std::io::Result<()> {
    let len = u32::try_from(body.len())
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "frame too large"))?;
    stream.write_all(&len.to_le_bytes())?;
    stream.write_all(body)?;
    stream.flush()
}
