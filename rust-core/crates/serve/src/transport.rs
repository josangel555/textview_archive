//! `CoreTransport` — the InProcess | Socket seam (DAEMON_LIFECYCLE_DESIGN.md
//! D7, TSK-1557). A front-end (mdv-tui, mdv-web thin-client mode) calls core
//! methods through this ONE trait; whether the call executes in-process
//! (today's direct path) or crosses the mdv-serve socket is selected by
//! `MDV_REMOTE_SOCKET` — the exact seam the Swift App already has
//! (CoreTransport, TSK-652), now for the rust front-ends. Wire behavior is
//! byte-identical by construction: BOTH arms route through the SAME
//! [`crate::serve::dispatch`] the daemon's connection loop uses.

use crate::envelope::{self, Frame, WireError};
use crate::fs::FsCtx;
use crate::serve::dispatch;
use crate::transcript_list::TranscriptCtx;
use crate::{read_frame, write_frame};
use std::os::unix::net::UnixStream;

/// A transport-level failure: either the METHOD failed (a wire error the
/// server/dispatch reported — same shape on both arms) or the CHANNEL failed
/// (socket IO — only the Socket arm can produce it).
#[derive(Debug)]
pub enum TransportFault {
    /// The method ran and reported a protocol-level error.
    Wire(WireError),
    /// The channel itself failed (connect/read/write) — Socket arm only.
    Io(std::io::Error),
}

/// The shell-agnostic core-call seam: invoke `method` with a request `body`
/// (the unframed msgpack payload; empty for body-less methods like `ping`),
/// get the response body back.
pub trait CoreTransport {
    /// Invoke one core method. `aux` is the bulk side-channel some methods
    /// (e.g. `indent_detect`) use for large payloads; pass `&[]` otherwise.
    fn call(&mut self, method: &str, body: &[u8], aux: &[u8]) -> Result<Vec<u8>, TransportFault>;
}

/// Today's path: the method dispatches directly in this process — no socket,
/// no daemon. Identical semantics to the Socket arm because it calls the SAME
/// `dispatch` the server's connection loop calls.
pub struct InProcess {
    fs_ctx: FsCtx,
    transcript_ctx: TranscriptCtx,
    next_id: u64,
}

impl InProcess {
    /// An in-process transport with no fs root / claude dir (engine methods +
    /// ping; fs-family methods report their normal "fs disabled" wire error).
    pub fn new() -> Result<Self, TransportFault> {
        let fs_ctx = FsCtx::new(None).map_err(TransportFault::Io)?;
        Ok(Self { fs_ctx, transcript_ctx: TranscriptCtx::new(None), next_id: 0 })
    }
}

impl CoreTransport for InProcess {
    fn call(&mut self, method: &str, body: &[u8], aux: &[u8]) -> Result<Vec<u8>, TransportFault> {
        self.next_id += 1;
        match dispatch(self.next_id, method, body, aux, &self.fs_ctx, &self.transcript_ctx) {
            Frame::Response { body: Some(out), error: None, .. } => Ok(out),
            Frame::Response { error: Some(e), .. } => Err(TransportFault::Wire(e)),
            _ => Err(TransportFault::Wire(WireError {
                code: "transport_error".into(),
                text: "in-process dispatch returned a non-response frame".into(),
            })),
        }
    }
}

/// The remote path: a connected mdv-serve socket (hello already exchanged —
/// [`Socket::connect`] performs it). Requests/responses are the same
/// envelope frames the daemon speaks; subscriptions/push are out of scope
/// for this seam (request/response only).
pub struct Socket {
    stream: UnixStream,
    next_id: u64,
}

impl Socket {
    /// Connect to a running mdv-serve at `path` and perform the hello
    /// (wire-version handshake). A skewed server answers the hello with
    /// `wire_version_skew` — surfaced as [`TransportFault::Wire`].
    pub fn connect(path: &str) -> Result<Self, TransportFault> {
        #[derive(serde::Serialize)]
        struct HelloRequest {
            wire_version: u64,
        }
        let stream = UnixStream::connect(path).map_err(TransportFault::Io)?;
        let mut sock = Self { stream, next_id: 0 };
        let hello = mdvcore_core::wire::encode_frame(&HelloRequest {
            wire_version: u64::from(mdvcore_ffi::MDV_WIRE_VERSION),
        })
        .map(crate::serve::unframe_or_empty)
        .unwrap_or_default();
        sock.call("hello", &hello, &[])?;
        Ok(sock)
    }
}

impl CoreTransport for Socket {
    fn call(&mut self, method: &str, body: &[u8], aux: &[u8]) -> Result<Vec<u8>, TransportFault> {
        self.next_id += 1;
        let frame = Frame::Request {
            id: self.next_id,
            method: method.to_owned(),
            body: body.to_vec(),
            aux: aux.to_vec(),
        };
        write_frame(&mut &self.stream, &envelope::encode(&frame)).map_err(TransportFault::Io)?;
        let Some(raw) = read_frame(&mut &self.stream).map_err(TransportFault::Io)? else {
            return Err(TransportFault::Io(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                "server closed before responding",
            )));
        };
        match envelope::decode(&raw) {
            Ok(Frame::Response { body: Some(out), error: None, .. }) => Ok(out),
            Ok(Frame::Response { error: Some(e), .. }) => Err(TransportFault::Wire(e)),
            _ => Err(TransportFault::Wire(WireError {
                code: "transport_error".into(),
                text: "unexpected frame in response position".into(),
            })),
        }
    }
}

/// The env-selected seam: `MDV_REMOTE_SOCKET=<path>` → the Socket arm
/// (connect + hello); unset → InProcess. This is how mdv-tui (and mdv-web
/// thin-client mode, daemon s6) pick their transport without code changes.
pub fn from_env() -> Result<Box<dyn CoreTransport>, TransportFault> {
    match std::env::var("MDV_REMOTE_SOCKET") {
        Ok(path) if !path.is_empty() => Ok(Box::new(Socket::connect(&path)?)),
        _ => Ok(Box::new(InProcess::new()?)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::serve::handle_connection;

    /// THE contract: the same assertions run against BOTH transports — the
    /// trait's whole point is that a front-end cannot tell them apart.
    fn assert_contract(t: &mut dyn CoreTransport) {
        // ping: empty body, succeeds.
        #[allow(clippy::unwrap_used, reason = "test assertion")]
        let pong = t.call("ping", &[], &[]).unwrap();
        assert!(pong.is_empty(), "ping answers with an empty body");

        // An unknown method is a WIRE error (the method failed), not an IO
        // fault (the channel is fine) — on both arms.
        let outcome = t.call("no.such.method", &[], &[]);
        let is_wire_with_code =
            matches!(&outcome, Err(TransportFault::Wire(e)) if !e.code.is_empty());
        assert!(
            is_wire_with_code,
            "unknown method must be a Wire fault with a code, got {outcome:?}"
        );

        // The channel survives the method error: ping still works after.
        #[allow(clippy::unwrap_used, reason = "test assertion")]
        let again = t.call("ping", &[], &[]).unwrap();
        assert!(again.is_empty(), "transport usable after a method error");
    }

    #[test]
    fn in_process_transport_meets_the_contract() {
        #[allow(clippy::unwrap_used, reason = "test setup")]
        let mut t = InProcess::new().unwrap();
        assert_contract(&mut t);
    }

    #[test]
    fn socket_transport_meets_the_same_contract() {
        // A real mdv-serve connection loop on a socketpair — byte-identical
        // wire, hello included (Socket::connect performs it).
        #[allow(clippy::unwrap_used, reason = "test setup")]
        let (client, server) = UnixStream::pair().unwrap();
        let handle = std::thread::spawn(move || {
            #[allow(clippy::unwrap_used, reason = "test setup")]
            let fs_ctx = FsCtx::new(None).unwrap();
            let tctx = TranscriptCtx::new(None);
            let _ = handle_connection(&server, &fs_ctx, &tctx);
        });

        // Socket::connect needs a path; drive the hello by hand over the
        // pair instead (same code path as connect after the dial).
        #[derive(serde::Serialize)]
        struct HelloRequest {
            wire_version: u64,
        }
        let mut sock = Socket { stream: client, next_id: 0 };
        #[allow(clippy::unwrap_used, reason = "test setup")]
        let hello_body = mdvcore_core::wire::encode_frame(&HelloRequest {
            wire_version: u64::from(mdvcore_ffi::MDV_WIRE_VERSION),
        })
        .map(crate::serve::unframe_or_empty)
        .unwrap();
        #[allow(clippy::unwrap_used, reason = "hello must succeed")]
        let hello_resp = sock.call("hello", &hello_body, &[]).unwrap();
        assert!(!hello_resp.is_empty(), "hello answers with the capability frame");

        assert_contract(&mut sock);

        drop(sock); // closes the client half; the server loop EOFs out
        let _ = handle.join();
    }

    #[test]
    fn from_env_defaults_to_in_process() {
        // The suite doesn't set MDV_REMOTE_SOCKET; default must be InProcess
        // (a Socket would try to connect and fail).
        #[allow(clippy::unwrap_used, reason = "test assertion")]
        let mut t = from_env().unwrap();
        #[allow(clippy::unwrap_used, reason = "test assertion")]
        let pong = t.call("ping", &[], &[]).unwrap();
        assert!(pong.is_empty());
    }
}
