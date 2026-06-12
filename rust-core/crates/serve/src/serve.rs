//! Connection handling + method dispatch (protocol v1).

use std::os::unix::net::UnixStream;

use mdvcore_core::{cm_edit, diff, find_engine, fuzzy, markdown, transcript, wire};
use mdvcore_ffi::{MDV_CAPABILITIES, MDV_CAP_FS, MDV_CAP_GIT, MDV_CAP_SEARCH, MDV_CAP_TRANSCRIPT_LIST, MDV_WIRE_VERSION};

use crate::fs::FsCtx;
use crate::transcript_list::TranscriptCtx;

use crate::envelope::{self, Frame, WireError};
use crate::{read_frame, write_frame};

/// 16 MiB — the existing wire ceiling (`MDV_STATUS_TOO_LARGE` class).
pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;

type WireFn = fn(&[u8]) -> Result<Vec<u8>, wire::WireFault>;

/// The engine dispatch table — the same `*_wire` functions the FFI exports
/// call, invoked directly (no FFI hop server-side). Adding a family =
/// adding rows (and flipping its capability bit in the hello mask).
fn method_fn(name: &str) -> Option<WireFn> {
    match name {
        "cm_apply" => Some(cm_edit::apply_wire),
        "diff_parse" => Some(diff::parse_wire),
        "diff_hunk_marks" => Some(diff::hunk_marks_wire),
        "fuzzy_rank" => Some(fuzzy::rank_wire),
        "find_search" => Some(find_engine::search_wire),
        // WIRE-BOUNDARY redaction (TSK-658): the server FORCES redaction
        // regardless of the request flag — nothing unredacted leaves the
        // machine. The in-process FFI keeps caller choice (local trust).
        "transcript_parse" => Some(transcript::parse_wire_forced_redaction),
        "markdown_render" => Some(markdown::render_wire),
        _ => None,
    }
}

/// Serve one connection: hello first (wire-version hard-close), then a
/// request loop. Returns on EOF / IO error / protocol violation.
pub fn handle_connection(
    stream: &UnixStream,
    fs_ctx: &FsCtx,
    transcript_ctx: &TranscriptCtx,
) -> std::io::Result<()> {
    let mut reader = stream;
    let mut writer = stream;

    // --- hello (must be the first frame) ---
    let Some(first) = read_frame(&mut reader)? else { return Ok(()) };
    let hello = match envelope::decode(&first) {
        Ok(Frame::Request { id, method, body }) if method == "hello" => (id, body),
        _ => return Ok(()), // anything else first = protocol violation, hang up
    };
    let client_version = hello_wire_version(&hello.1);
    if client_version != Some(u64::from(MDV_WIRE_VERSION)) {
        // Version skew is a HARD CLOSE (the ABI-skew rule, networked) — but
        // tell the client why first.
        let resp = Frame::Response {
            id: hello.0,
            body: None,
            error: Some(WireError {
                code: "wire_version_skew".into(),
                text: format!(
                    "server speaks wire v{MDV_WIRE_VERSION}, client sent {client_version:?}"
                ),
            }),
        };
        let _ = write_frame(&mut writer, &envelope::encode(&resp));
        return Ok(());
    }
    let mut capabilities = MDV_CAPABILITIES | MDV_CAP_TRANSCRIPT_LIST;
    if fs_ctx.enabled() {
        capabilities |= MDV_CAP_FS | MDV_CAP_GIT | MDV_CAP_SEARCH;
    }
    let hello_body = wire::encode_frame(&HelloResponse {
        wire_version: u64::from(MDV_WIRE_VERSION),
        capabilities,
        server: concat!("mdv-serve/", env!("CARGO_PKG_VERSION")).to_owned(),
    })
    .map(unframe_or_empty)
    .unwrap_or_default();
    write_frame(
        &mut writer,
        &envelope::encode(&Frame::Response { id: hello.0, body: Some(hello_body), error: None }),
    )?;

    // --- request loop ---
    while let Some(bytes) = read_frame(&mut reader)? {
        let frame = match envelope::decode(&bytes) {
            Ok(f) => f,
            Err(_) => return Ok(()), // malformed envelope: hang up
        };
        let Frame::Request { id, method, body } = frame else {
            continue; // responses/events from a client are ignored in v1
        };
        let resp = dispatch(id, &method, &body, fs_ctx, transcript_ctx);
        write_frame(&mut writer, &envelope::encode(&resp))?;
    }
    Ok(())
}

fn dispatch(
    id: u64,
    method: &str,
    body: &[u8],
    fs_ctx: &FsCtx,
    transcript_ctx: &TranscriptCtx,
) -> Frame {
    if method == "ping" {
        return Frame::Response { id, body: Some(Vec::new()), error: None };
    }
    if method.starts_with("fs.") {
        return match fs_ctx.dispatch(method, body) {
            Ok(out) => Frame::Response { id, body: Some(out), error: None },
            Err(e) => Frame::Response { id, body: None, error: Some(e) },
        };
    }
    if method == "transcript.list" {
        return match transcript_ctx.list() {
            Ok(out) => Frame::Response { id, body: Some(out), error: None },
            Err(e) => Frame::Response { id, body: None, error: Some(e) },
        };
    }
    if method.starts_with("search.") {
        return match crate::search::dispatch(fs_ctx, method, body) {
            Ok(out) => Frame::Response { id, body: Some(out), error: None },
            Err(e) => Frame::Response { id, body: None, error: Some(e) },
        };
    }
    if method.starts_with("git.") {
        return match crate::git::dispatch(fs_ctx, method, body) {
            Ok(out) => Frame::Response { id, body: Some(out), error: None },
            Err(e) => Frame::Response { id, body: None, error: Some(e) },
        };
    }
    let Some(f) = method_fn(method) else {
        return Frame::Response {
            id,
            body: None,
            error: Some(WireError {
                code: "unknown_method".into(),
                text: format!("no method '{method}'"),
            }),
        };
    };
    // The *_wire fns take FRAMED bytes (u32-LE prefix + body) — the FFI
    // callers frame client-side; here the envelope carries the UNFRAMED
    // body, so frame/unframe around the call.
    let framed = frame_bytes(body);
    match f(&framed) {
        Ok(out) => Frame::Response { id, body: Some(unframe_or_empty(out)), error: None },
        Err(_) => Frame::Response {
            id,
            body: None,
            error: Some(WireError {
                code: "wire_error".into(),
                text: format!("method '{method}' rejected the request frame"),
            }),
        },
    }
}

/// u32-LE length prefix (the `wire::encode_frame` convention).
fn frame_bytes(body: &[u8]) -> Vec<u8> {
    let n = u32::try_from(body.len()).unwrap_or(u32::MAX);
    let mut out = Vec::with_capacity(body.len().saturating_add(4));
    out.extend_from_slice(&n.to_le_bytes());
    out.extend_from_slice(body);
    out
}

/// Strip the u32-LE prefix from a `*_wire` result (empty on malformed —
/// the wire fns never produce malformed frames).
fn unframe_or_empty(framed: Vec<u8>) -> Vec<u8> {
    framed.get(4..).map(<[u8]>::to_vec).unwrap_or_default()
}

#[derive(serde::Serialize)]
struct HelloResponse {
    wire_version: u64,
    capabilities: u64,
    server: String,
}

/// Pull `wire_version` out of the hello request body (a msgpack map) using
/// the envelope cursor's tolerant reader via a tiny local parse.
fn hello_wire_version(body: &[u8]) -> Option<u64> {
    #[derive(serde::Deserialize)]
    struct HelloRequest {
        wire_version: u64,
    }
    let framed = frame_bytes(body);
    wire::decode_frame::<HelloRequest>(&framed)
        .ok()
        .map(|h| h.wire_version)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::envelope::{decode, encode};
    use std::io::Write as _;

    fn connected_pair() -> (UnixStream, UnixStream) {
        #[allow(clippy::unwrap_used, reason = "test setup")]
        UnixStream::pair().unwrap()
    }

    fn hello_body() -> Vec<u8> {
        #[derive(serde::Serialize)]
        struct H {
            wire_version: u64,
            client: String,
        }
        #[allow(clippy::unwrap_used, reason = "test fixture")]
        let framed = wire::encode_frame(&H {
            wire_version: u64::from(MDV_WIRE_VERSION),
            client: "test".into(),
        })
        .unwrap();
        unframe_or_empty(framed)
    }

    fn send(stream: &UnixStream, frame: &Frame) {
        let mut w = stream;
        #[allow(clippy::unwrap_used, reason = "test io")]
        crate::write_frame(&mut w, &encode(frame)).unwrap();
    }

    fn recv(stream: &UnixStream) -> Frame {
        let mut r = stream;
        #[allow(clippy::unwrap_used, reason = "test io")]
        decode(&crate::read_frame(&mut r).unwrap().unwrap()).unwrap()
    }

    fn serve_on(server: UnixStream) -> std::thread::JoinHandle<()> {
        std::thread::spawn(move || {
            #[allow(clippy::unwrap_used, reason = "test setup")]
            let ctx = FsCtx::new(None).unwrap();
            let tctx = TranscriptCtx::new(Some("/nonexistent"));
            let _ = handle_connection(&server, &ctx, &tctx);
        })
    }

    #[test]
    fn hello_then_engine_call_end_to_end() {
        let (client, server) = connected_pair();
        let h = serve_on(server);

        send(&client, &Frame::Request { id: 1, method: "hello".into(), body: hello_body() });
        let Frame::Response { id: 1, body: Some(_), error: None } = recv(&client) else {
            #[allow(clippy::panic, reason = "test assertion")]
            {
                panic!("hello must succeed");
            }
        };

        // A REAL engine call over the socket: find_search.
        #[derive(serde::Serialize)]
        struct Req<'a> {
            text: &'a str,
            pattern: &'a str,
            kind: &'a str,
            case_sensitive: bool,
            whole_word: bool,
        }
        #[allow(clippy::unwrap_used, reason = "test fixture")]
        let body = unframe_or_empty(
            wire::encode_frame(&Req {
                text: "hello world",
                pattern: "world",
                kind: "literal",
                case_sensitive: false,
                whole_word: false,
            })
            .unwrap(),
        );
        send(&client, &Frame::Request { id: 2, method: "find_search".into(), body });
        let Frame::Response { id: 2, body: Some(resp), error: None } = recv(&client) else {
            #[allow(clippy::panic, reason = "test assertion")]
            {
                panic!("find_search must succeed");
            }
        };
        #[derive(serde::Deserialize)]
        struct Resp {
            matches: Vec<M>,
        }
        #[derive(serde::Deserialize)]
        struct M {
            location: u32,
        }
        #[allow(clippy::unwrap_used, reason = "test decode")]
        let decoded: Resp = wire::decode_frame(&frame_bytes(&resp)).unwrap();
        assert_eq!(decoded.matches.len(), 1);
        assert_eq!(decoded.matches.first().map(|m| m.location), Some(6));

        drop(client);
        let _ = h.join();
    }

    #[test]
    fn wire_version_skew_hard_closes_with_error() {
        let (client, server) = connected_pair();
        let h = serve_on(server);
        #[derive(serde::Serialize)]
        struct H {
            wire_version: u64,
        }
        #[allow(clippy::unwrap_used, reason = "test fixture")]
        let body = unframe_or_empty(wire::encode_frame(&H { wire_version: 999 }).unwrap());
        send(&client, &Frame::Request { id: 1, method: "hello".into(), body });
        let Frame::Response { error: Some(e), .. } = recv(&client) else {
            #[allow(clippy::panic, reason = "test assertion")]
            {
                panic!("skew must answer with an error");
            }
        };
        assert_eq!(e.code, "wire_version_skew");
        // …and then the connection is CLOSED: the next read sees EOF.
        let mut r = &client;
        #[allow(clippy::unwrap_used, reason = "test io")]
        let eof = crate::read_frame(&mut r).unwrap();
        assert!(eof.is_none(), "connection must hard-close after skew");
        let _ = h.join();
    }

    #[test]
    fn unknown_method_and_ping() {
        let (client, server) = connected_pair();
        let h = serve_on(server);
        send(&client, &Frame::Request { id: 1, method: "hello".into(), body: hello_body() });
        let _ = recv(&client);

        send(&client, &Frame::Request { id: 5, method: "ping".into(), body: vec![] });
        let Frame::Response { id: 5, error: None, .. } = recv(&client) else {
            #[allow(clippy::panic, reason = "test assertion")]
            {
                panic!("ping must succeed");
            }
        };

        send(&client, &Frame::Request { id: 6, method: "no.such".into(), body: vec![] });
        let Frame::Response { id: 6, error: Some(e), .. } = recv(&client) else {
            #[allow(clippy::panic, reason = "test assertion")]
            {
                panic!("unknown method must error");
            }
        };
        assert_eq!(e.code, "unknown_method");

        drop(client);
        let _ = h.join();
    }

    #[test]
    fn non_hello_first_frame_hangs_up() {
        let (client, server) = connected_pair();
        let h = serve_on(server);
        send(&client, &Frame::Request { id: 1, method: "ping".into(), body: vec![] });
        let mut r = &client;
        #[allow(clippy::unwrap_used, reason = "test io")]
        let eof = crate::read_frame(&mut r).unwrap();
        assert!(eof.is_none(), "server must hang up on a non-hello first frame");
        let _ = h.join();
    }

    #[test]
    fn oversized_frame_is_refused() {
        let (client, server) = connected_pair();
        let h = serve_on(server);
        // Hand-write a frame header claiming 17 MiB.
        let mut w = &client;
        #[allow(clippy::unwrap_used, reason = "test io")]
        {
            w.write_all(&(17u32 * 1024 * 1024).to_le_bytes()).unwrap();
            w.write_all(&[0u8; 16]).unwrap();
        }
        let mut r = &client;
        #[allow(clippy::unwrap_used, reason = "test io")]
        let eof = crate::read_frame(&mut r).unwrap();
        assert!(eof.is_none(), "server must drop the connection on an oversized frame");
        let _ = h.join();
    }
}
