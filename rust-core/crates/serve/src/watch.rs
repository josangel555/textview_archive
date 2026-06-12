//! `fs.watch` / `fs.unwatch` push subscriptions (protocol §5, TSK-662).
//!
//! std-only POLLING watcher — the serve crate's zero-external-dep posture
//! is a contract, and std has no native watch API. Each connection owns
//! one watcher thread (spawned in `handle_connection`); every tick it
//! re-snapshots each due subscription's paths (path → mtime+len) and
//! diffs against the previous snapshot. **The tick IS the debounce
//! window**: "at most one `changed` per path per window" holds by
//! construction, not by timer bookkeeping. A rename surfaces as
//! deleted+created (the portable contract allows the degradation).
//!
//! Backpressure (§5): a single tick producing more than
//! [`MAX_EVENTS_PER_TICK`] events drops the WHOLE burst and emits one
//! `resync` event instead — seq stays monotonic with NO gap, so loss is
//! explicit, never inferred. Subscriptions die with the connection.
//!
//! `transcript.follow` (TSK-663) rides the same hub as a second payload:
//! a tail-reader whose events are PARSED, REDACTION-FORCED batches via
//! `transcript::parse_wire_forced_redaction` — never raw JSONL lines,
//! which would bypass the TSK-658 wire-redaction guarantee. Truncation/
//! rotation (or a vanished file) resets the tail and emits `resync`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use crate::envelope::{Frame, WireError};
use crate::fs::{FsCtx, decode_body, encode_body, modified_ms, unauthorized};

/// §5 queue cap: a tick bursting past this collapses into one `resync`.
pub const MAX_EVENTS_PER_TICK: usize = 256;
/// Per-subscription walk cap (the fs-family listing-cap discipline);
/// entries beyond it are not watched.
pub const MAX_WATCHED_ENTRIES: usize = 4096;
/// §5 default debounce window.
pub const DEFAULT_TICK_MS: u64 = 100;
/// Floor for a client-supplied `debounce_ms` (keeps a hostile 0 from
/// busy-spinning the watcher).
pub const MIN_TICK_MS: u64 = 25;
/// transcript.follow: bytes read per tick (the rest waits for the next
/// tick — bounded work per window).
pub const FOLLOW_WINDOW_BYTES: u64 = 1024 * 1024;
/// transcript.follow: a torn line may carry across ticks up to this many
/// bytes; beyond it the carry drops and a `resync` emits (a single line
/// bigger than this is hostile input, not a transcript).
pub const FOLLOW_CARRY_CAP: usize = 1024 * 1024;

/// path → (modified_ms, len). Equality of the pair = "unchanged".
type Snapshot = HashMap<PathBuf, (i64, u64)>;

struct Sub {
    tick_ms: u64,
    /// Milliseconds accumulated since the last scan.
    since_scan_ms: u64,
    seq: u64,
    payload: Payload,
}

enum Payload {
    /// fs.watch: snapshot-diff over watched roots.
    Fs { roots: Vec<PathBuf>, recursive: bool, snapshot: Snapshot },
    /// transcript.follow: tail a JSONL file from `offset`, carrying a
    /// torn trailing line between ticks.
    Follow { path: PathBuf, offset: u64, carry: Vec<u8> },
}

/// Per-connection subscription registry + the watcher thread's stop flag.
pub struct WatchHub {
    subs: Mutex<HashMap<u64, Sub>>,
    next_id: AtomicU64,
    stop: AtomicBool,
    /// The served root events relativize against (the watch family only
    /// exists when a root is served).
    root: Option<PathBuf>,
}

impl WatchHub {
    #[must_use]
    pub fn new(fs: &FsCtx) -> Self {
        Self {
            subs: Mutex::new(HashMap::new()),
            next_id: AtomicU64::new(1),
            stop: AtomicBool::new(false),
            root: fs.root_path().map(Path::to_path_buf),
        }
    }

    /// Signal the watcher thread to exit (connection teardown).
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Release);
    }

    #[must_use]
    pub fn stopped(&self) -> bool {
        self.stop.load(Ordering::Acquire)
    }

    /// `fs.watch {paths, recursive?, debounce_ms?}` → `{sub}`. Every path
    /// must resolve inside the served root (escape = `unauthorized`); the
    /// INITIAL snapshot is taken here so only post-subscribe changes emit.
    pub fn watch(&self, fs: &FsCtx, body: &[u8]) -> Result<Vec<u8>, WireError> {
        #[derive(serde::Deserialize)]
        struct Req {
            paths: Vec<String>,
            #[serde(default)]
            recursive: bool,
            #[serde(default)]
            debounce_ms: Option<u64>,
        }
        #[derive(serde::Serialize)]
        struct Resp {
            sub: u64,
        }
        let req: Req = decode_body(body)?;
        if req.paths.is_empty() {
            return Err(WireError {
                code: "wire_error".into(),
                text: "fs.watch needs at least one path".into(),
            });
        }
        let mut roots = Vec::with_capacity(req.paths.len());
        for p in &req.paths {
            roots.push(fs.contained(p)?);
        }
        let tick_ms = req.debounce_ms.unwrap_or(DEFAULT_TICK_MS).max(MIN_TICK_MS);
        let snapshot = scan(&roots, req.recursive, MAX_WATCHED_ENTRIES);
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let sub = Sub {
            tick_ms,
            since_scan_ms: 0,
            seq: 0,
            payload: Payload::Fs { roots, recursive: req.recursive, snapshot },
        };
        if let Ok(mut subs) = self.subs.lock() {
            subs.insert(id, sub);
        }
        encode_body(&Resp { sub: id })
    }

    /// `transcript.follow {dir, name, from_start?, debounce_ms?}` → `{sub}`
    /// (TSK-663). `dir`/`name` are EXACTLY the identifiers `transcript.list`
    /// returns; both must be single path components (no separators, no
    /// `..`) and `name` must end in `.jsonl` — the list family's
    /// zero-traversal posture. The tail starts at the file END unless
    /// `from_start` (history rides `transcript_parse`).
    pub fn follow(
        &self,
        tctx: &crate::transcript_list::TranscriptCtx,
        body: &[u8],
    ) -> Result<Vec<u8>, WireError> {
        #[derive(serde::Deserialize)]
        struct Req {
            dir: String,
            name: String,
            #[serde(default)]
            from_start: bool,
            #[serde(default)]
            debounce_ms: Option<u64>,
        }
        #[derive(serde::Serialize)]
        struct Resp {
            sub: u64,
        }
        let req: Req = decode_body(body)?;
        if !is_single_component(&req.dir)
            || !is_single_component(&req.name)
            || !req.name.ends_with(".jsonl")
        {
            return Err(unauthorized(
                "dir/name must be transcript.list identifiers (single components, name *.jsonl)",
            ));
        }
        let path = tctx.base().join(&req.dir).join(&req.name);
        let meta = std::fs::symlink_metadata(&path)
            .map_err(|_| unauthorized("no such transcript"))?;
        if meta.file_type().is_symlink() || !meta.is_file() {
            return Err(unauthorized("not a regular transcript file"));
        }
        let offset = if req.from_start { 0 } else { meta.len() };
        let tick_ms = req.debounce_ms.unwrap_or(DEFAULT_TICK_MS).max(MIN_TICK_MS);
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let sub = Sub {
            tick_ms,
            since_scan_ms: 0,
            seq: 0,
            payload: Payload::Follow { path, offset, carry: Vec::new() },
        };
        if let Ok(mut subs) = self.subs.lock() {
            subs.insert(id, sub);
        }
        encode_body(&Resp { sub: id })
    }

    /// `fs.unwatch {sub}` → `{}` (unknown sub ids answer `wire_error`).
    pub fn unwatch(&self, body: &[u8]) -> Result<Vec<u8>, WireError> {
        #[derive(serde::Deserialize)]
        struct Req {
            sub: u64,
        }
        #[derive(serde::Serialize)]
        struct Resp {}
        let req: Req = decode_body(body)?;
        let removed = self
            .subs
            .lock()
            .map(|mut s| s.remove(&req.sub).is_some())
            .unwrap_or(false);
        if !removed {
            return Err(WireError {
                code: "wire_error".into(),
                text: format!("no subscription {}", req.sub),
            });
        }
        encode_body(&Resp {})
    }

    /// One scheduling step: advance every subscription by `elapsed_ms`;
    /// scan + diff the due ones, emitting events through `emit`. Pure
    /// with respect to TIME (the caller owns the clock/sleep), so tests
    /// drive ticks deterministically.
    pub fn tick(&self, elapsed_ms: u64, emit: &mut dyn FnMut(Frame)) {
        let Ok(mut subs) = self.subs.lock() else { return };
        for (&id, sub) in subs.iter_mut() {
            sub.since_scan_ms = sub.since_scan_ms.saturating_add(elapsed_ms);
            if sub.since_scan_ms < sub.tick_ms {
                continue;
            }
            sub.since_scan_ms = 0;
            match &mut sub.payload {
                Payload::Fs { roots, recursive, snapshot } => {
                    let fresh = scan(roots, *recursive, MAX_WATCHED_ENTRIES);
                    let events = diff(snapshot, &fresh);
                    *snapshot = fresh;
                    if events.is_empty() {
                        continue;
                    }
                    if events.len() > MAX_EVENTS_PER_TICK {
                        // §5 backpressure: drop the burst, emit ONE resync —
                        // the seq advances by exactly one (explicit loss,
                        // no gap).
                        sub.seq = sub.seq.saturating_add(1);
                        emit(Frame::Event {
                            sub: id,
                            seq: sub.seq,
                            kind: "resync".into(),
                            body: Vec::new(),
                        });
                        continue;
                    }
                    for (kind, path) in events {
                        sub.seq = sub.seq.saturating_add(1);
                        emit(Frame::Event {
                            sub: id,
                            seq: sub.seq,
                            kind: kind.into(),
                            body: event_body(self.root.as_deref(), &path),
                        });
                    }
                }
                Payload::Follow { path, offset, carry } => {
                    match follow_step(path, offset, carry) {
                        FollowStep::Quiet => {}
                        FollowStep::Resync => {
                            sub.seq = sub.seq.saturating_add(1);
                            emit(Frame::Event {
                                sub: id,
                                seq: sub.seq,
                                kind: "resync".into(),
                                body: Vec::new(),
                            });
                        }
                        FollowStep::Events(body) => {
                            sub.seq = sub.seq.saturating_add(1);
                            emit(Frame::Event {
                                sub: id,
                                seq: sub.seq,
                                kind: "events".into(),
                                body,
                            });
                        }
                    }
                }
            }
        }
    }
}

/// One transcript-follow poll outcome.
enum FollowStep {
    Quiet,
    Resync,
    /// The UNFRAMED `{events: […]}` parse response — already
    /// REDACTION-FORCED (the wire guarantee holds for pushed content).
    Events(Vec<u8>),
}

/// Advance a follow tail one tick: detect truncation/rotation, read the
/// next window, carry torn lines, parse complete ones (redaction forced).
fn follow_step(path: &Path, offset: &mut u64, carry: &mut Vec<u8>) -> FollowStep {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(meta) = std::fs::symlink_metadata(path) else {
        // Vanished mid-follow: if we had progress, that is a rotation.
        if *offset > 0 || !carry.is_empty() {
            *offset = 0;
            carry.clear();
            return FollowStep::Resync;
        }
        return FollowStep::Quiet;
    };
    if meta.len() < *offset {
        // Truncated/rotated in place.
        *offset = 0;
        carry.clear();
        return FollowStep::Resync;
    }
    if meta.len() == *offset {
        return FollowStep::Quiet;
    }
    let Ok(mut file) = std::fs::File::open(path) else { return FollowStep::Quiet };
    if file.seek(SeekFrom::Start(*offset)).is_err() {
        return FollowStep::Quiet;
    }
    let mut buf = Vec::new();
    if file.take(FOLLOW_WINDOW_BYTES).read_to_end(&mut buf).is_err() {
        return FollowStep::Quiet;
    }
    *offset = offset.saturating_add(buf.len() as u64);
    carry.extend_from_slice(&buf);
    let Some(cut) = carry.iter().rposition(|&b| b == b'\n') else {
        if carry.len() > FOLLOW_CARRY_CAP {
            // A single "line" past the cap is hostile input — drop it
            // and tell the client to resync.
            carry.clear();
            return FollowStep::Resync;
        }
        return FollowStep::Quiet;
    };
    let rest = carry.split_off(cut.saturating_add(1));
    let complete = std::mem::replace(carry, rest);
    let text = String::from_utf8_lossy(&complete).into_owned();

    #[derive(serde::Serialize)]
    struct ParseReq {
        text: String,
        redacting: bool,
    }
    let Ok(req_frame) = mdvcore_core::wire::encode_frame(&ParseReq { text, redacting: true })
    else {
        return FollowStep::Quiet;
    };
    let Ok(framed) = mdvcore_core::transcript::parse_wire_forced_redaction(&req_frame) else {
        return FollowStep::Quiet;
    };
    let body = framed.get(4..).map(<[u8]>::to_vec).unwrap_or_default();
    // Skip empty batches (every line torn/invalid) — no frame, no seq.
    #[derive(serde::Deserialize)]
    struct Probe {
        events: Vec<serde::de::IgnoredAny>,
    }
    let non_empty = mdvcore_core::wire::decode_frame::<Probe>(&framed)
        .map(|p| !p.events.is_empty())
        .unwrap_or(false);
    if non_empty { FollowStep::Events(body) } else { FollowStep::Quiet }
}

/// A single path component: non-empty, no separators, not a dot-walk.
fn is_single_component(s: &str) -> bool {
    !s.is_empty() && !s.contains('/') && !s.contains('\\') && s != "." && s != ".."
}

/// `{path}` event body — relative to the served root where possible.
fn event_body(root: Option<&Path>, path: &Path) -> Vec<u8> {
    #[derive(serde::Serialize)]
    struct Body {
        path: String,
    }
    let rel = root
        .and_then(|r| path.strip_prefix(r).ok())
        .unwrap_or(path);
    encode_body(&Body { path: rel.to_string_lossy().into_owned() }).unwrap_or_default()
}

/// Snapshot the watched paths: a file root contributes itself; a dir root
/// contributes its entries (recursing when asked). Symlinks are NEVER
/// followed (the search-family posture); the walk stops at `cap` entries.
#[must_use]
pub fn scan(roots: &[PathBuf], recursive: bool, cap: usize) -> Snapshot {
    let mut out = Snapshot::new();
    for root in roots {
        scan_one(root, recursive, cap, &mut out);
        if out.len() >= cap {
            break;
        }
    }
    out
}

fn scan_one(path: &Path, recursive: bool, cap: usize, out: &mut Snapshot) {
    if out.len() >= cap {
        return;
    }
    let Ok(meta) = std::fs::symlink_metadata(path) else { return };
    if meta.file_type().is_symlink() {
        return; // never followed, never reported
    }
    if meta.is_file() {
        out.insert(path.to_path_buf(), (modified_ms(&meta), meta.len()));
        return;
    }
    if !meta.is_dir() {
        return;
    }
    let Ok(entries) = std::fs::read_dir(path) else { return };
    for entry in entries.flatten() {
        if out.len() >= cap {
            return;
        }
        let p = entry.path();
        let Ok(m) = std::fs::symlink_metadata(&p) else { continue };
        if m.file_type().is_symlink() {
            continue;
        }
        if m.is_file() {
            out.insert(p, (modified_ms(&m), m.len()));
        } else if m.is_dir() && recursive {
            scan_one(&p, recursive, cap, out);
        }
    }
}

/// Diff two snapshots into (kind, path) events, sorted by path for
/// deterministic emission order ("preserved per path; best-effort across
/// paths" — sorting satisfies both).
#[must_use]
pub fn diff(old: &Snapshot, new: &Snapshot) -> Vec<(&'static str, PathBuf)> {
    let mut events: Vec<(&'static str, PathBuf)> = Vec::new();
    for (path, sig) in new {
        match old.get(path) {
            None => events.push(("created", path.clone())),
            Some(prev) if prev != sig => events.push(("changed", path.clone())),
            Some(_) => {}
        }
    }
    for path in old.keys() {
        if !new.contains_key(path) {
            events.push(("deleted", path.clone()));
        }
    }
    events.sort_by(|a, b| a.1.cmp(&b.1).then(a.0.cmp(b.0)));
    events
}

#[cfg(test)]
mod tests {
    #![allow(clippy::panic, reason = "test assertions on frame shapes")]

    use super::*;
    use std::sync::atomic::AtomicUsize;

    static SEQ: AtomicUsize = AtomicUsize::new(0);

    fn temp_dir() -> PathBuf {
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        let d = std::env::temp_dir().join(format!(
            "mdv-watch-{}-{n}",
            std::process::id()
        ));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn write(dir: &Path, name: &str, contents: &str) -> PathBuf {
        let p = dir.join(name);
        std::fs::write(&p, contents).unwrap();
        p
    }

    fn ctx(root: &Path) -> FsCtx {
        FsCtx::new(Some(root.to_str().unwrap())).unwrap()
    }

    fn watch_body(paths: &[&str], recursive: bool, debounce_ms: Option<u64>) -> Vec<u8> {
        #[derive(serde::Serialize)]
        struct Req<'a> {
            paths: Vec<&'a str>,
            recursive: bool,
            #[serde(skip_serializing_if = "Option::is_none")]
            debounce_ms: Option<u64>,
        }
        encode_body(&Req { paths: paths.to_vec(), recursive, debounce_ms }).unwrap()
    }

    fn sub_id(resp: &[u8]) -> u64 {
        #[derive(serde::Deserialize)]
        struct Resp {
            sub: u64,
        }
        let framed = {
            let mut f = (u32::try_from(resp.len()).unwrap()).to_le_bytes().to_vec();
            f.extend_from_slice(resp);
            f
        };
        mdvcore_core::wire::decode_frame::<Resp>(&framed).unwrap().sub
    }

    fn collect(hub: &WatchHub, elapsed_ms: u64) -> Vec<Frame> {
        let mut out = Vec::new();
        hub.tick(elapsed_ms, &mut |f| out.push(f));
        out
    }

    #[test]
    fn scan_diff_detect_create_change_delete() {
        let dir = temp_dir();
        let a = write(&dir, "a.txt", "one");
        let before = scan(std::slice::from_ref(&dir), false, MAX_WATCHED_ENTRIES);
        assert_eq!(before.len(), 1);

        // create + change + delete between snapshots
        let b = write(&dir, "b.txt", "new");
        std::fs::write(&a, "one-changed-much-longer").unwrap(); // len changes
        let after = scan(std::slice::from_ref(&dir), false, MAX_WATCHED_ENTRIES);
        let mut got = diff(&before, &after);
        got.retain(|(_, p)| p == &a || p == &b);
        assert_eq!(
            got.iter().map(|(k, _)| *k).collect::<Vec<_>>(),
            vec!["changed", "created"],
            "sorted by path: a.txt changed, b.txt created"
        );

        std::fs::remove_file(&b).unwrap();
        let last = scan(std::slice::from_ref(&dir), false, MAX_WATCHED_ENTRIES);
        let got = diff(&after, &last);
        assert_eq!(got, vec![("deleted", b)]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn scan_never_follows_symlinks_and_respects_recursive_flag() {
        let dir = temp_dir();
        write(&dir, "top.txt", "t");
        let nested = dir.join("inner");
        std::fs::create_dir(&nested).unwrap();
        write(&nested, "deep.txt", "d");
        std::os::unix::fs::symlink("/etc", dir.join("escape")).unwrap();

        let flat = scan(std::slice::from_ref(&dir), false, MAX_WATCHED_ENTRIES);
        assert_eq!(flat.len(), 1, "non-recursive sees only top.txt: {flat:?}");
        let deep = scan(std::slice::from_ref(&dir), true, MAX_WATCHED_ENTRIES);
        assert_eq!(deep.len(), 2, "recursive adds inner/deep.txt");
        assert!(
            deep.keys().all(|p| !p.starts_with("/etc")),
            "symlinks are never followed"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn hub_emits_ordered_events_with_monotonic_seq() {
        let dir = temp_dir();
        write(&dir, "seed.txt", "s");
        let fs = ctx(&dir);
        let hub = WatchHub::new(&fs);
        let resp = hub.watch(&fs, &watch_body(&["."], false, Some(40))).unwrap();
        let id = sub_id(&resp);

        // Below the debounce window: nothing scans.
        write(&dir, "early.txt", "e");
        assert!(collect(&hub, 39).is_empty(), "window not yet elapsed");
        // Window elapses: the created event arrives with seq 1.
        let events = collect(&hub, 1);
        assert_eq!(events.len(), 1);
        let Frame::Event { sub, seq, kind, body } = &events[0] else {
            panic!("expected an event frame")
        };
        assert_eq!((*sub, *seq, kind.as_str()), (id, 1, "created"));
        let framed = {
            let mut f = (u32::try_from(body.len()).unwrap()).to_le_bytes().to_vec();
            f.extend_from_slice(body);
            f
        };
        #[derive(serde::Deserialize)]
        struct Body {
            path: String,
        }
        let b: Body = mdvcore_core::wire::decode_frame(&framed).unwrap();
        assert_eq!(b.path, "early.txt", "paths are root-relative");

        // A quiet window emits nothing; seq holds.
        assert!(collect(&hub, 40).is_empty());
        // Change + delete in one window: ordered by path, seq 2 then 3.
        std::fs::write(dir.join("early.txt"), "longer-now").unwrap();
        std::fs::remove_file(dir.join("seed.txt")).unwrap();
        let events = collect(&hub, 40);
        let got: Vec<(u64, String)> = events
            .iter()
            .map(|f| match f {
                Frame::Event { seq, kind, .. } => (*seq, kind.clone()),
                Frame::Request { .. } | Frame::Response { .. } => panic!("non-event"),
            })
            .collect();
        assert_eq!(got, vec![(2, "changed".into()), (3, "deleted".into())]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn burst_over_cap_collapses_to_one_resync_no_seq_gap() {
        let dir = temp_dir();
        let fs = ctx(&dir);
        let hub = WatchHub::new(&fs);
        let resp = hub.watch(&fs, &watch_body(&["."], false, Some(40))).unwrap();
        let id = sub_id(&resp);

        for i in 0..(MAX_EVENTS_PER_TICK + 1) {
            write(&dir, &format!("f{i:04}.txt"), "x");
        }
        let events = collect(&hub, 40);
        assert_eq!(events.len(), 1, "burst must collapse to a single frame");
        let Frame::Event { sub, seq, kind, .. } = &events[0] else {
            panic!("expected event")
        };
        assert_eq!((*sub, *seq, kind.as_str()), (id, 1, "resync"));

        // The NEXT real event continues at seq 2 — no gap.
        write(&dir, "after.txt", "y");
        let events = collect(&hub, 40);
        // (the resync re-snapshot already absorbed the burst; only the new
        // file diffs)
        assert_eq!(events.len(), 1);
        let Frame::Event { seq, kind, .. } = &events[0] else { panic!() };
        assert_eq!((*seq, kind.as_str()), (2, "created"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ---- transcript.follow (TSK-663) ----

    fn follow_base() -> (PathBuf, crate::transcript_list::TranscriptCtx) {
        // TranscriptCtx joins "projects" onto the claude dir.
        let claude = temp_dir();
        let proj = claude.join("projects").join("proj-a");
        std::fs::create_dir_all(&proj).unwrap();
        let ctx = crate::transcript_list::TranscriptCtx::new(Some(claude.to_str().unwrap()));
        (proj, ctx)
    }

    fn follow_body(dir: &str, name: &str, from_start: bool) -> Vec<u8> {
        #[derive(serde::Serialize)]
        struct Req<'a> {
            dir: &'a str,
            name: &'a str,
            from_start: bool,
            debounce_ms: u64,
        }
        encode_body(&Req { dir, name, from_start, debounce_ms: 40 }).unwrap()
    }

    fn append(path: &Path, chunk: &str) {
        use std::io::Write as _;
        let mut f = std::fs::OpenOptions::new().append(true).open(path).unwrap();
        f.write_all(chunk.as_bytes()).unwrap();
    }

    #[derive(serde::Deserialize)]
    struct EvBody {
        events: Vec<Ev>,
    }
    #[derive(serde::Deserialize)]
    struct Ev {
        kind: String,
        text: Option<String>,
        input: Option<Vec<(String, String)>>,
    }

    fn decode_events(body: &[u8]) -> Vec<Ev> {
        let mut framed = u32::try_from(body.len()).unwrap().to_le_bytes().to_vec();
        framed.extend_from_slice(body);
        mdvcore_core::wire::decode_frame::<EvBody>(&framed).unwrap().events
    }

    #[test]
    fn follow_rejects_traversal_and_shape() {
        let (proj, tctx) = follow_base();
        write(&proj, "s.jsonl", "");
        let dir_fs = ctx(&proj);
        let hub = WatchHub::new(&dir_fs);
        for (d, n) in [
            ("../proj-a", "s.jsonl"),
            ("proj-a", "../s.jsonl"),
            ("proj-a", "x/s.jsonl"),
            ("proj-a", "notes.txt"),
            ("..", "s.jsonl"),
        ] {
            let err = hub.follow(&tctx, &follow_body(d, n, false)).unwrap_err();
            assert_eq!(err.code, "unauthorized", "{d}/{n} must be rejected");
        }
        // Missing file is unauthorized too (no existence oracle outside list).
        let err = hub.follow(&tctx, &follow_body("proj-a", "nope.jsonl", false)).unwrap_err();
        assert_eq!(err.code, "unauthorized");
    }

    #[test]
    fn follow_emits_redacted_parsed_batches_from_the_tail() {
        let (proj, tctx) = follow_base();
        let file = proj.join("s.jsonl");
        std::fs::write(&file, "{\"uuid\":\"old\",\"message\":{\"role\":\"user\",\"content\":\"history\"}}\n").unwrap();
        let hub = WatchHub::new(&ctx(&proj));
        let resp = hub.follow(&tctx, &follow_body("proj-a", "s.jsonl", false)).unwrap();
        let id = sub_id(&resp);

        // Pre-subscribe history must NOT replay (tail starts at end).
        assert!(collect(&hub, 40).is_empty());

        // Append a user line + a tool_use carrying a SECRET signature.
        append(&file, "{\"uuid\":\"u1\",\"message\":{\"role\":\"user\",\"content\":\"hi\"}}\n");
        append(&file, "{\"uuid\":\"t1\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":\"t\",\"name\":\"X\",\"input\":{\"signature\":\"SECRET-BLOB\"}}]}}\n");
        let frames = collect(&hub, 40);
        assert_eq!(frames.len(), 1, "one batched events frame per tick");
        let Frame::Event { sub, seq, kind, body } = &frames[0] else { panic!() };
        assert_eq!((*sub, *seq, kind.as_str()), (id, 1, "events"));
        let events = decode_events(body);
        assert_eq!(events.len(), 2);
        assert_eq!(events[0].kind, "user");
        assert_eq!(events[0].text.as_deref(), Some("hi"));
        // THE WIRE GUARANTEE: pushed content is REDACTED.
        let input = events[1].input.as_ref().unwrap();
        let sig = input.iter().find(|(k, _)| k == "signature").unwrap();
        assert_eq!(sig.1, "[REDACTED]", "follow must never push unredacted content");
    }

    #[test]
    fn follow_carries_torn_lines_across_ticks() {
        let (proj, tctx) = follow_base();
        let file = proj.join("s.jsonl");
        std::fs::write(&file, "").unwrap();
        let hub = WatchHub::new(&ctx(&proj));
        hub.follow(&tctx, &follow_body("proj-a", "s.jsonl", false)).unwrap();

        // Half a record, no newline: nothing may emit.
        append(&file, "{\"uuid\":\"u9\",\"message\":{\"role\":\"user\",");
        assert!(collect(&hub, 40).is_empty(), "torn line must wait");
        // The rest arrives: ONE complete event, text intact.
        append(&file, "\"content\":\"stitched\"}}\n");
        let frames = collect(&hub, 40);
        assert_eq!(frames.len(), 1);
        let Frame::Event { kind, body, .. } = &frames[0] else { panic!() };
        assert_eq!(kind, "events");
        let events = decode_events(body);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].text.as_deref(), Some("stitched"));
    }

    #[test]
    fn follow_truncation_resyncs_then_recovers_with_monotonic_seq() {
        let (proj, tctx) = follow_base();
        let file = proj.join("s.jsonl");
        std::fs::write(&file, "{\"uuid\":\"a\",\"message\":{\"role\":\"user\",\"content\":\"one\"}}\n").unwrap();
        let hub = WatchHub::new(&ctx(&proj));
        hub.follow(&tctx, &follow_body("proj-a", "s.jsonl", false)).unwrap();

        // Rotate: the file shrinks under the tail.
        std::fs::write(&file, "").unwrap();
        let frames = collect(&hub, 40);
        assert_eq!(frames.len(), 1);
        let Frame::Event { seq, kind, .. } = &frames[0] else { panic!() };
        assert_eq!((*seq, kind.as_str()), (1, "resync"));

        // Post-rotation content emits from the new file, seq continues.
        append(&file, "{\"uuid\":\"b\",\"message\":{\"role\":\"user\",\"content\":\"two\"}}\n");
        let frames = collect(&hub, 40);
        assert_eq!(frames.len(), 1);
        let Frame::Event { seq, kind, body, .. } = &frames[0] else { panic!() };
        assert_eq!((*seq, kind.as_str()), (2, "events"));
        assert_eq!(decode_events(body)[0].text.as_deref(), Some("two"));
    }

    #[test]
    fn follow_from_start_replays_existing_content() {
        let (proj, tctx) = follow_base();
        let file = proj.join("s.jsonl");
        std::fs::write(&file, "{\"uuid\":\"h\",\"message\":{\"role\":\"user\",\"content\":\"replayed\"}}\n").unwrap();
        let hub = WatchHub::new(&ctx(&proj));
        hub.follow(&tctx, &follow_body("proj-a", "s.jsonl", true)).unwrap();
        let frames = collect(&hub, 40);
        assert_eq!(frames.len(), 1);
        let Frame::Event { kind, body, .. } = &frames[0] else { panic!() };
        assert_eq!(kind, "events");
        assert_eq!(decode_events(body)[0].text.as_deref(), Some("replayed"));
        let _ = std::fs::remove_dir_all(file.parent().unwrap());
    }

    #[test]
    fn watch_rejects_escapes_and_unwatch_silences() {
        let dir = temp_dir();
        write(&dir, "w.txt", "w");
        let fs = ctx(&dir);
        let hub = WatchHub::new(&fs);
        // Containment: an absolute path outside the root is unauthorized.
        let err = hub.watch(&fs, &watch_body(&["/etc"], false, None)).unwrap_err();
        assert_eq!(err.code, "unauthorized");
        // Escape via ..
        let err = hub.watch(&fs, &watch_body(&["../"], false, None)).unwrap_err();
        assert_eq!(err.code, "unauthorized");

        let resp = hub.watch(&fs, &watch_body(&["."], false, Some(40))).unwrap();
        let id = sub_id(&resp);
        #[derive(serde::Serialize)]
        struct Un {
            sub: u64,
        }
        hub.unwatch(&encode_body(&Un { sub: id }).unwrap()).unwrap();
        write(&dir, "post.txt", "p");
        assert!(collect(&hub, 40).is_empty(), "unwatched sub must emit nothing");
        // Double-unwatch errors cleanly.
        assert!(hub.unwatch(&encode_body(&Un { sub: id }).unwrap()).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
