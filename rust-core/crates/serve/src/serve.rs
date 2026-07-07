//! Connection handling + method dispatch (protocol v1).

use std::os::unix::net::UnixStream;

use mdvcore_core::{cm_edit, diff, find_engine, fuzzy, indent, markdown, transcript, wire};
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
        // TSK-543: delta apply — returns only the changed region, not the buffer.
        "cm_apply_delta" => Some(cm_edit::apply_delta_wire),
        "diff_parse" => Some(diff::parse_wire),
        "diff_hunk_marks" => Some(diff::hunk_marks_wire),
        "fuzzy_rank" => Some(fuzzy::rank_wire),
        "find_search" => Some(find_engine::search_wire),
        // WIRE-BOUNDARY redaction (TSK-658): the server FORCES redaction
        // regardless of the request flag — nothing unredacted leaves the
        // machine. The in-process FFI keeps caller choice (local trust).
        "transcript_parse" => Some(transcript::parse_wire_forced_redaction),
        "markdown_render" => Some(markdown::render_wire),
        // TSK-660: tree-sitter highlight runs (UTF-16 offsets, app
        // TokenKind vocabulary) — MDV_CAP_HIGHLIGHT.
        "highlight_runs" => Some(mdvcore_highlight::runs::runs_wire),
        _ => None,
    }
}

/// Serve one connection: hello first (wire-version hard-close), then a
/// DUPLEX loop (TSK-662): requests answer inline while a per-connection
/// watcher thread pushes subscription events; both share the write side
/// behind a mutex. Subscriptions die with the connection (§5). Returns on
/// EOF / IO error / protocol violation.
pub fn handle_connection(
    stream: &UnixStream,
    fs_ctx: &FsCtx,
    transcript_ctx: &TranscriptCtx,
) -> std::io::Result<()> {
    let mut reader = stream;
    let writer = std::sync::Mutex::new(stream.try_clone()?);
    let write_locked = |frame: &Frame| -> std::io::Result<()> {
        let Ok(mut w) = writer.lock() else {
            return Err(std::io::Error::other("writer lock poisoned"));
        };
        write_frame(&mut &*w, &envelope::encode(frame))
    };

    // --- hello (must be the first frame) ---
    let Some(first) = read_frame(&mut reader)? else { return Ok(()) };
    let hello = match envelope::decode(&first) {
        Ok(Frame::Request { id, method, body, .. }) if method == "hello" => (id, body),
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
        let _ = write_locked(&resp);
        return Ok(());
    }
    // MDV_CAPABILITIES already carries MDV_CAP_INDENT (it is a staticlib
    // engine family); the server now actually serves indent_detect over the
    // wire (TSK-651) so the advertised bit is no longer aspirational.
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
    write_locked(&Frame::Response { id: hello.0, body: Some(hello_body), error: None })?;

    // --- watcher thread (the push half, §5) ---
    // One per connection; ticks at MIN_TICK_MS and lets the hub's per-sub
    // debounce accounting decide what is due. Event writes serialize with
    // response writes through the same mutex (a fresh stream clone).
    // Spawned unconditionally: transcript.follow (TSK-663) works without a
    // served fs root; an idle hub is one sleeping thread.
    let hub = std::sync::Arc::new(crate::watch::WatchHub::new(fs_ctx));
    let watcher = {
        let hub_t = std::sync::Arc::clone(&hub);
        let event_stream = std::sync::Mutex::new(stream.try_clone()?);
        std::thread::spawn(move || {
            let step = crate::watch::MIN_TICK_MS;
            while !hub_t.stopped() {
                std::thread::sleep(std::time::Duration::from_millis(step));
                let mut failed = false;
                hub_t.tick(step, &mut |frame| {
                    if failed {
                        return;
                    }
                    let Ok(mut w) = event_stream.lock() else {
                        failed = true;
                        return;
                    };
                    if write_frame(&mut &*w, &envelope::encode(&frame)).is_err() {
                        // Peer gone — the request loop will notice EOF and
                        // stop the hub; just stop emitting.
                        failed = true;
                    }
                });
                if failed {
                    break;
                }
            }
        })
    };

    // --- request loop ---
    let result = (|| -> std::io::Result<()> {
        while let Some(bytes) = read_frame(&mut reader)? {
            let frame = match envelope::decode(&bytes) {
                Ok(f) => f,
                Err(_) => return Ok(()), // malformed envelope: hang up
            };
            let Frame::Request { id, method, body, aux } = frame else {
                continue; // responses/events from a client are ignored in v1
            };
            let resp = match method.as_str() {
                "fs.watch" => match hub.watch(fs_ctx, &body) {
                    Ok(out) => Frame::Response { id, body: Some(out), error: None },
                    Err(e) => Frame::Response { id, body: None, error: Some(e) },
                },
                "fs.unwatch" | "transcript.unfollow" => match hub.unwatch(&body) {
                    Ok(out) => Frame::Response { id, body: Some(out), error: None },
                    Err(e) => Frame::Response { id, body: None, error: Some(e) },
                },
                "transcript.follow" => match hub.follow(transcript_ctx, &body) {
                    Ok(out) => Frame::Response { id, body: Some(out), error: None },
                    Err(e) => Frame::Response { id, body: None, error: Some(e) },
                },
                _ => dispatch(id, &method, &body, &aux, fs_ctx, transcript_ctx),
            };
            write_locked(&resp)?;
        }
        Ok(())
    })();

    // Subscriptions die with the connection.
    hub.stop();
    let _ = watcher.join();
    result
}

pub(crate) fn dispatch(
    id: u64,
    method: &str,
    body: &[u8],
    aux: &[u8],
    fs_ctx: &FsCtx,
    transcript_ctx: &TranscriptCtx,
) -> Frame {
    if method == "ping" {
        return Frame::Response { id, body: Some(Vec::new()), error: None };
    }
    // RAW-OUTPUT aux method (TSK-651): indent detection. The source text rides
    // the `aux` bulk side-channel (frame-cap-exempt); `req` carries only
    // {sample_lines}. Unlike the framed engine methods, the result is the tiny
    // raw UTF-8 string ("Tabs", "Spaces (4)", "—") — NOT a msgpack frame — so
    // it is placed in the response body VERBATIM (no unframe), byte-identical
    // to `indent::detect_wire_aux(req, aux)` called directly.
    if method == "indent_detect" {
        let framed_req = frame_bytes(body);
        return match indent::detect_wire_aux(&framed_req, aux) {
            Ok(raw) => Frame::Response { id, body: Some(raw), error: None },
            Err(_) => Frame::Response {
                id,
                body: None,
                error: Some(WireError {
                    code: "wire_error".into(),
                    text: format!("method '{method}' rejected the request frame"),
                }),
            },
        };
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
pub(crate) fn frame_bytes(body: &[u8]) -> Vec<u8> {
    let n = u32::try_from(body.len()).unwrap_or(u32::MAX);
    let mut out = Vec::with_capacity(body.len().saturating_add(4));
    out.extend_from_slice(&n.to_le_bytes());
    out.extend_from_slice(body);
    out
}

/// Strip the u32-LE prefix from a `*_wire` result (empty on malformed —
/// the wire fns never produce malformed frames).
pub(crate) fn unframe_or_empty(framed: Vec<u8>) -> Vec<u8> {
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

    /// Build a request frame with an empty aux side-channel (the common
    /// case). Keeps the aux-field addition (TSK-651) from rippling across
    /// every test call site.
    fn req(id: u64, method: &str, body: Vec<u8>) -> Frame {
        Frame::Request { id, method: method.into(), body, aux: vec![] }
    }

    /// Build a request frame WITH an aux bulk side-channel.
    fn req_aux(id: u64, method: &str, body: Vec<u8>, aux: Vec<u8>) -> Frame {
        Frame::Request { id, method: method.into(), body, aux }
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
    fn fs_watch_pushes_events_over_the_socket_and_unwatch_silences() {
        // TSK-662 end-to-end: hello → fs.watch → file churn → pushed Event
        // frames (monotonic seq, root-relative paths) → fs.unwatch → quiet.
        #[allow(clippy::unwrap_used, reason = "test setup")]
        let dir = {
            let d = std::env::temp_dir()
                .join(format!("mdv-serve-watch-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&d);
            std::fs::create_dir_all(&d).unwrap();
            d.canonicalize().unwrap()
        };
        let (client, server) = connected_pair();
        let dir_t = dir.clone();
        let h = std::thread::spawn(move || {
            #[allow(clippy::unwrap_used, reason = "test setup")]
            let ctx = FsCtx::new(Some(dir_t.to_str().unwrap())).unwrap();
            let tctx = TranscriptCtx::new(Some("/nonexistent"));
            let _ = handle_connection(&server, &ctx, &tctx);
        });

        send(&client, &req(1, "hello", hello_body()));
        let Frame::Response { id: 1, body: Some(_), error: None } = recv(&client) else {
            #[allow(clippy::panic, reason = "test assertion")]
            {
                panic!("hello must succeed");
            }
        };

        #[derive(serde::Serialize)]
        struct WatchReq<'a> {
            paths: Vec<&'a str>,
            recursive: bool,
            debounce_ms: u64,
        }
        #[allow(clippy::unwrap_used, reason = "test fixture")]
        let body = unframe_or_empty(
            wire::encode_frame(&WatchReq {
                paths: vec!["."],
                recursive: false,
                debounce_ms: 30,
            })
            .unwrap(),
        );
        send(&client, &req(2, "fs.watch", body));
        let Frame::Response { id: 2, body: Some(resp), error: None } = recv(&client) else {
            #[allow(clippy::panic, reason = "test assertion")]
            {
                panic!("fs.watch must succeed");
            }
        };
        #[derive(serde::Deserialize)]
        struct WatchResp {
            sub: u64,
        }
        #[allow(clippy::unwrap_used, reason = "test fixture")]
        let sub_id = {
            let mut framed = u32::try_from(resp.len()).unwrap().to_le_bytes().to_vec();
            framed.extend_from_slice(&resp);
            wire::decode_frame::<WatchResp>(&framed).unwrap().sub
        };

        // Touch a file: the watcher thread must PUSH an event (no request
        // outstanding). Allow a couple of poll windows for it to arrive.
        #[allow(clippy::unwrap_used, reason = "test io")]
        {
            std::fs::write(dir.join("born.txt"), "x").unwrap();
            client
                .set_read_timeout(Some(std::time::Duration::from_secs(5)))
                .unwrap();
        }
        let Frame::Event { sub, seq, kind, body } = recv(&client) else {
            #[allow(clippy::panic, reason = "test assertion")]
            {
                panic!("expected a pushed event frame");
            }
        };
        assert_eq!((sub, seq, kind.as_str()), (sub_id, 1, "created"));
        #[derive(serde::Deserialize)]
        struct EvtBody {
            path: String,
        }
        #[allow(clippy::unwrap_used, reason = "test fixture")]
        let evt: EvtBody = {
            let mut framed = u32::try_from(body.len()).unwrap().to_le_bytes().to_vec();
            framed.extend_from_slice(&body);
            wire::decode_frame(&framed).unwrap()
        };
        assert_eq!(evt.path, "born.txt", "event paths are root-relative");

        // Unwatch, then churn again: NOTHING may arrive (read times out).
        #[derive(serde::Serialize)]
        struct UnReq {
            sub: u64,
        }
        #[allow(clippy::unwrap_used, reason = "test fixture")]
        let body = unframe_or_empty(wire::encode_frame(&UnReq { sub: sub_id }).unwrap());
        send(&client, &req(3, "fs.unwatch", body));
        let Frame::Response { id: 3, error: None, .. } = recv(&client) else {
            #[allow(clippy::panic, reason = "test assertion")]
            {
                panic!("fs.unwatch must succeed");
            }
        };
        #[allow(clippy::unwrap_used, reason = "test io")]
        {
            std::fs::write(dir.join("silent.txt"), "y").unwrap();
            client
                .set_read_timeout(Some(std::time::Duration::from_millis(250)))
                .unwrap();
        }
        let got = crate::read_frame(&mut &client).ok().flatten();
        assert!(got.is_none(), "no frames after unwatch (got {got:?})");

        // EOF → request loop exits → hub stops → watcher joins. (An
        // earlier draft held a try_clone here — the server never saw EOF
        // and join() hung the whole suite. One fd, one drop.)
        drop(client);
        #[allow(clippy::unwrap_used, reason = "test teardown")]
        h.join().unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn highlight_runs_is_dispatched_with_app_contract_output() {
        // TSK-660: the remote path serves the same wire fn the FFI exports.
        let f = method_fn("highlight_runs").expect("highlight_runs must be registered");
        #[allow(clippy::unwrap_used, reason = "test fixture")]
        let frame = wire::encode_frame(&mdvcore_highlight::runs::RunsRequest {
            text: "fn main() {}".into(),
            lang: "rust".into(),
        })
        .unwrap();
        #[allow(clippy::unwrap_used, reason = "test assertion")]
        let out = f(&frame).unwrap();
        #[allow(clippy::unwrap_used, reason = "test assertion")]
        let resp: mdvcore_highlight::runs::RunsResponse = wire::decode_frame(&out).unwrap();
        assert!(resp.supported);
        assert!(resp.runs.iter().any(|r| r.kind == "keyword"));
        // And the hello mask advertises the bit (it rides MDV_CAPABILITIES).
        assert_ne!(MDV_CAPABILITIES & mdvcore_ffi::MDV_CAP_HIGHLIGHT, 0);
    }

    #[test]
    fn indent_detect_dispatch_is_byte_identical_to_detect_wire_aux() {
        // TSK-651: indent_detect is the first RAW-OUTPUT aux method on the wire.
        // The text rides `aux`; `req` carries {sample_lines}; the response body
        // is the raw UTF-8 string, byte-identical to indent::detect_wire_aux.
        let text = "    a\n    b\n"; // 4-space indent
        #[allow(clippy::unwrap_used, reason = "test fixture")]
        let req_body = unframe_or_empty(
            wire::encode_frame(&indent::DetectAuxRequest { sample_lines: 50 }).unwrap(),
        );
        #[allow(clippy::unwrap_used, reason = "test setup")]
        let ctx = FsCtx::new(None).unwrap();
        let tctx = TranscriptCtx::new(Some("/nonexistent"));
        let frame = dispatch(9, "indent_detect", &req_body, text.as_bytes(), &ctx, &tctx);
        let Frame::Response { id: 9, body: Some(out), error: None } = frame else {
            #[allow(clippy::panic, reason = "test assertion")]
            {
                panic!("indent_detect must dispatch to a body response");
            }
        };
        // Raw bytes — NOT a frame. Byte-identical to calling the wire fn direct.
        let direct = indent::detect_wire_aux(&frame_bytes(&req_body), text.as_bytes())
            .expect("detect_wire_aux must succeed");
        assert_eq!(out, direct, "wire body must equal the direct *_wire result");
        assert_eq!(String::from_utf8(out).ok().as_deref(), Some("Spaces (4)"));
    }

    #[test]
    fn indent_detect_end_to_end_over_the_socket_carries_aux() {
        // The aux carrier must survive a real hello → indent_detect round-trip:
        // if the text didn't ride `aux`, detect would see empty input → "—".
        let (client, server) = connected_pair();
        let h = serve_on(server);
        send(&client, &req(1, "hello", hello_body()));
        let Frame::Response { id: 1, body: Some(hello_resp), error: None } = recv(&client) else {
            #[allow(clippy::panic, reason = "test assertion")]
            {
                panic!("hello must succeed");
            }
        };
        // The hello mask must advertise MDV_CAP_INDENT now that it is served.
        #[derive(serde::Deserialize)]
        struct Hello {
            capabilities: u64,
        }
        #[allow(clippy::unwrap_used, reason = "test decode")]
        let hello: Hello = wire::decode_frame(&frame_bytes(&hello_resp)).unwrap();
        assert_ne!(hello.capabilities & mdvcore_ffi::MDV_CAP_INDENT, 0, "indent bit must be advertised");

        #[allow(clippy::unwrap_used, reason = "test fixture")]
        let req_body = unframe_or_empty(
            wire::encode_frame(&indent::DetectAuxRequest { sample_lines: 50 }).unwrap(),
        );
        send(&client, &req_aux(2, "indent_detect", req_body, b"\tx\n\ty\n".to_vec()));
        let Frame::Response { id: 2, body: Some(out), error: None } = recv(&client) else {
            #[allow(clippy::panic, reason = "test assertion")]
            {
                panic!("indent_detect must succeed over the wire");
            }
        };
        // Tab indent over the aux channel ⇒ "Tabs" (NOT "—", which is what an
        // empty/dropped aux would produce — that is the teeth).
        assert_eq!(String::from_utf8(out).ok().as_deref(), Some("Tabs"));

        drop(client);
        let _ = h.join();
    }

    #[test]
    fn hello_then_engine_call_end_to_end() {
        let (client, server) = connected_pair();
        let h = serve_on(server);

        send(&client, &req(1, "hello", hello_body()));
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
        send(&client, &req(2, "find_search", body));
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
        send(&client, &req(1, "hello", body));
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
        send(&client, &req(1, "hello", hello_body()));
        let _ = recv(&client);

        send(&client, &req(5, "ping", vec![]));
        let Frame::Response { id: 5, error: None, .. } = recv(&client) else {
            #[allow(clippy::panic, reason = "test assertion")]
            {
                panic!("ping must succeed");
            }
        };

        send(&client, &req(6, "no.such", vec![]));
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
        send(&client, &req(1, "ping", vec![]));
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
