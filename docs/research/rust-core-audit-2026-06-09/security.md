# security — rust-core audit 2026-06-09 (final, post-resume)

## Adversarially confirmed findings

### [S3] Web served-root fails OPEN to `/` when the start path can't be canonicalized
- **Where:** `rust-core/crates/web/src/main.rs:159`
- **Why:** A canonicalize failure should fail CLOSED (refuse to start), not broaden the served scope from a single directory to the entire filesystem. `mdv-web /typo` silently exposes all of `/` over 127.0.0.1:8765 to any local process / browser tab (the path-confinement chokepoint is now a no-op). This is the classic fail-open anti-pattern in the one security boundary the web tier has.
- **Fix:** On canonicalize failure, `eprintln!` and `std::process::exit(1)` (or return an `io::Error`) instead of defaulting to `/`. Also canonicalize+validate the CLI `start-dir` the same way the config root is validated, and reject a root of `/` explicitly unless an opt-in flag is passed.
- **Verifier:** Verified against rust-core/crates/web/src/main.rs — every element of the finding holds, and it is slightly WORSE than stated.

1. Fail-open confirmed (main.rs:149-159): `let root = start.or_else(...config...).unwrap_or(std::env::current_dir()?).canonicalize().unwrap_or_else(|_| PathBuf::from("/"));` (line 159). `Path::canonicalize()` errors on a nonexistent/unreadable path, so `mdv-web /typo` yields root `/`.

2. Asymmetric validation confirmed: only the config-restored root gets `.filter(|d| d.is_dir())` (line 155); the CLI arg (`start = Some(PathBuf::from(a))`, line ~144) is taken verbatim with no existence/dir check.

3. Confinement collapse confirmed (main.rs:480-483): `confined()` returns `Some(c)` when `c == *root || c.starts_with(root)`; with root = `/`, every canonicalized path starts with `/`, so the single documented chokepoint ("closes arbitrary file-read, `..` traversal, and symlink-escape" per its own doc comment) becomes a no-op. No later guard rejects a `/` root before `TcpListener::bind(("127.0.0.1", port))` and serving.

4. Amplifier the finding missed: line 162 `save_config(p, &WebConfig { root: Some(root.clone()) })` persists the broken root to `~/.textview/wui/config`, and on the next no-arg launch the restore filter `.is_dir()` PASSES for `/` — so a single typo'd launch permanently converts the server into a whole-filesystem server until the config is manually fixed or a valid path arg is passed.

Severity S3 is correctly calibrated: real security-boundary failure (the server runs with the owner's file permissions, and 127.0.0.1:8765 is reachable by ANY local user/process on a multi-user machine, so this exposes the owner's entire readable filesystem beyond direct browser-tab exfiltration, which same-origin policy + the host_allowed Host check at main.rs:469-475 largely contain). Mitigating factors keeping it below S2: loopback-only bind, requires a mistyped/missing start path to trigger, and the web crate is a localhost convenience front-end outside the default-members merge gate. Not refuted; severity stands.

### [S3] No total request deadline — slow-loris can pin worker slots for tens of hours
- **Where:** `rust-core/crates/web/src/main.rs:208`
- **Why:** The threat model explicitly lists slow-loris. The per-read timeout bounds a STALL but not a slow DRIP; combined with a thread-per-connection model and a 128-slot cap, a trivial local client (or a same-origin malicious page that passes the Host check) can exhaust all serving capacity for an extended period.
- **Fix:** Record `let deadline = Instant::now() + REQUEST_BUDGET;` at connection start and enforce it across the header-read loop (e.g. shrink each `set_read_timeout` to `deadline - now`, or abort once exceeded). A 5-10 s total head-parse budget closes the drip vector while leaving legitimate localhost clients unaffected.
- **Verifier:** Verified against rust-core/crates/web/src/main.rs. The claim holds exactly: handle_conn (line 208) sets only a per-recv 15s read timeout (lines 56, 212) and a 16 KiB header cap via Take (lines 51, 216); grep confirms no Instant/deadline anywhere in the file. A client dripping 1 byte every <15s never trips the per-recv timeout, so a single connection can hold a worker for ~16384 × 14s ≈ 63 hours, and the drip happens in read_request_head BEFORE the Host check (line 218), so anti-rebind is no defense. With MAX_INFLIGHT = 128 (lines 61, 178-181) refusing excess connections with 503, 128 trickling sockets wedge the server for days. The code's own comment (lines 209-211) claims slow-loris is mitigated — but only the stall variant is; the drip variant is a real gap against the stated threat model. One overstatement in the finding: a malicious same-origin browser page cannot drip headers (fetch sends them atomically), so the realistic attacker is a local process only — but that does not change the verdict, and the codebase itself rated the weaker stall-only variant S3, so S3 is correctly calibrated (localhost-only and availability-only rules out S2; full sustained capacity exhaustion contradicting an explicit hardening claim rules out S4). Fix sketch (wall-clock deadline shrinking each set_read_timeout across the header loop) is sound and dependency-free.

### [S3] CSV parser memory amplification: default caps permit ~2 GB from a ~32 MB file
- **Where:** `rust-core/crates/core/src/csv.rs:47`
- **Why:** This is reachable via `mdvcore_session_open` (FFI) on attacker-supplied file content — exactly threat-model (a)/(d). The caps technically exist (answering 'do Limits bound all parsers?') but the cell-count cap is decoupled from actual memory, so a 'rock-solid' core still OOMs/thrashes on a small crafted CSV. (The web tier is safe — it pre-caps at `PREVIEW_CAP = 1 MiB`; the FFI/Swift path uses these defaults.)
- **Fix:** Add a byte/heap-accounted cap (e.g. bound total bytes retained across all cells, or cap rows independently at a sane number like 5 M) so the worst case is O(input), not O(input * per-cell-overhead). Alternatively lower `max_total_cells` and add a `max_rows` cap; flip `truncated` when hit.
- **Verifier:** Verified against actual code and empirically reproduced. csv.rs:44-49 sets max_total_cells=32M and max_input_scalars=256MiB as claimed. In parse_with, each newline runs commit_field! (pushing one empty String) + rows.push + total_cells+=1 (lines 210-219), so one cell == one Vec<String> body row. A pathological all-newline input of ~32MB stays far under the 256MiB scalar cap, so only the 32M-cell cap binds. I built a repro linking mdvcore-core: 4MB of bare newlines yielded 3,999,998 rows and 479MB RSS (~120x amplification, WORSE than the finding's ~50x estimate); scaling to the 32M cap implies ~3.8GB from ~32MB input. Reachable through mdvcore_session_open -> CsvSession::open -> csv::parse with Limits::default() (ffi/src/lib.rs:451, session.rs:57), on attacker-supplied file content, which is the document-viewer's core use case. The cell-count cap is genuinely decoupled from retained heap. S3 is well-calibrated: recoverable resource-exhaustion DoS (no UB, no data loss), requires opening a crafted file, but large amplification on the primary FFI threat surface. Finding holds as stated.

### [S3] Directory listing is unbounded (no entry cap), unlike the 5000-row table cap
- **Where:** `rust-core/crates/web/src/main.rs:888`
- **Why:** Unbounded in-memory response construction is a memory-DoS (threat-model (c)/(d)). The asymmetry with `table_html`'s explicit 5000-cap shows the bound was intended elsewhere but missed for directory navigation — the most-hit code path. Reachable by the user navigating (or a same-origin page issuing) `/browse?path=<huge dir>`.
- **Fix:** Cap rendered entries (e.g. `.take(SOME_MAX)` with a 'N more, refine filter' notice, mirroring the grep/table truncation banners), and/or stream the response instead of buffering the full body.
- **Verifier:** Every cited claim checks out against /Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/web/src/main.rs: (1) read_entries (lines 696-725) collects every fs::read_dir entry into a Vec with no cap — the only filtering is dotfile suppression and the optional quick-find needle; an empty filter returns the full listing. (2) nav_html (lines 888-907) iterates the full returned Vec and push_str's a formatted <li> per entry into the response String, with no .take()/truncation banner. (3) handle_conn (lines 242-248) buffers the entire body String and Content-Length's it before write_all — nothing streams. (4) The asymmetry is real: table_html caps at rows.iter().take(5000) (line 1538), and the crate bounds everything else it considered a risk (MAX_HEADER_BYTES=16KiB line 51, MAX_INFLIGHT=128 line 61, GREP_MAX_FILES=2000/GREP_MAX_HITS=500 lines 529-530), so the missing directory-listing cap is plausibly an oversight rather than a decision. Reachability holds: /browse is GET-routable, and while the server binds 127.0.0.1 with a Host allowlist (lines 165, 218, 474), the Host check only blocks DNS rebinding — a malicious page can still fire a no-cors GET at http://127.0.0.1:<port>/browse?path=... with a legitimate Host header, and the user can simply navigate into a huge directory themselves. MAX_INFLIGHT limits concurrency but a single request can still build a hundreds-of-MB-to-GB String (1M entries × ~150-250 bytes of HTML each), plus the per-entry metadata() syscalls make it slow to boot. Severity calibration: S3 is right — it's a memory-DoS in a localhost-only dev tool requiring a pathologically large directory under the root, not exploitable for data loss or code execution (not S2), but a real unbounded-allocation gap inconsistent with the crate's own hardening posture (more than an S4 nit). Fix sketch (cap + 'N more' banner mirroring grep/table truncation) is apt and cheap.

## S4 nits (unverified by design)

- hex::render_all sizes a Vec from an unvalidated `width`, enabling multi-GB alloc / OOM-abort (`rust-core/crates/core/src/hex.rs`)
- git subprocess spawned on every /browse and /view request (`rust-core/crates/web/src/main.rs`)
- MdvBuf::from_vec on an empty Vec yields a non-null dangling data pointer, contradicting the documented contract (`rust-core/crates/ffi/src/buf.rs`)

---

## Full reviewer report

# rust-core SECURITY audit — hostile content, wire boundary, web/TUI front-ends

Scope: `rust-core/` only. Threat model facets (a) hostile file content, (b) hostile wire bytes at the FFI/web boundaries, (c) the std-only web server, (d) algorithmic/memory DoS in parsers, (e) TUI file/path handling.

## Headline

The rust-core security posture is genuinely strong, and several previously-documented classes are **actually fixed and complete** (not merely claimed):

- **Wire framing is well-hardened.** `decode_frame` rejects oversized declared lengths (`> MAX_FRAME_LEN = 16 MiB`), rejects `declared != body.len()`, and the body slice is already the in-memory buffer — there is **no pre-allocation-from-untrusted-length** vector. `decode` adds a strict end-of-stream check (`consumed != bytes.len()` → reject) that kills the rmp-serde trailing-garbage trap. (`wire.rs:118-210`)
- **No alloc-amplification through rmp-serde 1.3.0.** Its `Deserializer` has a depth limit of 1024 (`decode.rs:216`) and reads strings via `take(len).read_to_end(buf)` (grows with bytes actually present, bounded by the ≤16 MiB frame), not `with_capacity(declared_len)`. `serde`'s `Vec` path uses the cautious size hint. A crafted msgpack header cannot force a giant allocation.
- **DNS-rebinding / origin defense is correct.** A present non-loopback `Host` is 403'd (`host_allowed`, `main.rs:469-475`); a browser always sends `Host`, so the cross-origin vector is closed. Absent-Host is only reachable by local non-browser clients, and the listener binds `127.0.0.1` only.
- **Path confinement is correct.** `confined()` canonicalizes (resolving `..`/symlinks) then uses component-wise `Path::starts_with` — no `/foo/barbaz` prefix-escape — and `grep_walk` confines every file read and filters symlinked dirs (DirEntry::file_type doesn't follow). (`main.rs:480-483`, `545-601`)
- **Panic boundary is profile-correct.** The shipping staticlib links the `dist` profile (`panic = "unwind"`), and `build-rust-core.sh` actively REJECTS the `panic=abort` `release` profile for the app-link path, so `catch_unwind` is load-bearing rather than a no-op.
- **`core` is `#![forbid(unsafe_code)]`** with workspace-wide no-panic/no-indexing denies; the only `unsafe` lives in `ffi`, which re-declares the deny set and wraps every entry point in `ffi_guard!`.

No S1/S2 issues found. Everything below is S3/S4 hardening — DoS / robustness / contract on a localhost / trusted-caller surface. I did not inflate them.

## Findings

### S3 — Web served-root fails OPEN to `/` (`web/src/main.rs:157-159`)
`root = ....canonicalize().unwrap_or_else(|_| PathBuf::from("/"))`. A nonexistent/unreadable CLI `start-dir` (which, unlike the config-restored root, is NOT `is_dir`-filtered) makes `root` become `/`, and `confined()`'s `starts_with("/")` then accepts the entire filesystem. The single confinement chokepoint becomes a no-op. Fail-open in the one security boundary the web tier has. Fix: fail closed (exit) on canonicalize error; validate the CLI dir; reject a root of `/` unless explicitly opted in.

### S3 — No total request deadline; slow-loris (`web/src/main.rs:208-216`, `51`, `56`, `61`)
Only a per-read timeout (15 s) and a 16 KiB header byte-cap exist; there is no wall-clock budget. A client dripping 1 byte every <15 s never trips the per-read timeout and survives ~64 h per connection (bounded only by the 16 KiB `Take`), holding 1 of 128 slots. 128 trickles wedge the server for days. The threat model explicitly lists slow-loris. Fix: a per-request `Instant` deadline enforced across the header loop.

### S3 — CSV memory amplification (`core/src/csv.rs:44-49`, parse loop `206-219`)
`max_total_cells = 32_000_000` is decoupled from memory. ~32 M bare newlines (~32 MB) → ~32 M one-cell rows → ~1.5-2 GB resident (~50x), under the 256 MiB scalar cap so it never fires. Reachable via `mdvcore_session_open` on hostile file bytes (threat (a)/(d)). The web tier is safe (pre-caps at 1 MiB); the FFI/Swift path uses these defaults. Fix: byte/heap-accounted cap, or a separate `max_rows` and a much lower per-cell budget.

### S3 — Unbounded directory listing (`web/src/main.rs:696-725`, `888-907`)
`read_entries` + `nav_html` render every directory entry into a fully-buffered response `String`, with no cap — unlike `table_html`'s deliberate `.take(5000)` (`1538`). A huge directory under the served root yields a multi-GB in-memory body. Fix: cap rendered entries with a truncation banner (mirroring grep/table), and/or stream the response.

### S4 — hex::render_all trusts an unvalidated `width` (`core/src/hex.rs:26-27`, `72`, `86-107`; `ffi/src/lib.rs:283`)
`Vec::with_capacity(rows * per_row)` and a `0..width` inner loop scale with `width: u32` from the FFI caller (`usize::try_from(width).unwrap_or(usize::MAX)`). A large `width` requests a >10 GB allocation → OOM → **abort** (uncatchable by `catch_unwind`), crashing the host. Not file-content-reachable today (Swift sets `width`), so defense-in-depth — but a reusable core shouldn't size allocations from an unvalidated scalar. Fix: clamp `width` (e.g. `min(4096)`) before the capacity math; guard `rendered_row_length(0)`'s `width*3 - 1` underflow.

### S4 — git subprocess per request (`web/src/main.rs:822-829`, `873`)
`nav_html` spawns `git status` synchronously for every `/browse` and `/view`. 128 concurrent requests → 128 forked `git` processes; no timeout on the spawn. Resource amplification compounding the thread-per-conn model. Fix: cache per-dir with TTL / gate behind a param / bound concurrency / add a timeout.

### S4 — MdvBuf::from_vec(empty) returns a non-null dangling data pointer (`ffi/src/buf.rs:38-44`)
`as_mut_ptr()` on an empty `Vec` is `NonNull::dangling()` (non-null), with `len=cap=0`, contradicting the struct doc "null when len==0" (`buf.rs:16`). Harmless only while every consumer checks `len` first; a consumer trusting the documented null would dereference an invalid pointer across the ABI. Fix: return `MdvBuf::empty()` when `v.is_empty()`.

## Things checked and cleared (not findings)
- `pct_decode` bounds (`i + 2 < bytes.len()`) are correct — no panic/off-by-one (`main.rs:1822-1849`).
- `diff::parse_diff_git_paths` `match_indices(" b/")` loop is O(n), not quadratic; slices use ASCII-derived byte offsets (boundary-safe) (`diff.rs:196-240`).
- `find_matches`/`grep_lines` advance by ≥1 byte per match → linear, no quadratic blow-up (`find.rs:53-79`).
- `cm_edit::apply` UTF-16 splice is bounds-checked via `get(..)`, rejects overlap/OOB/ill-formed (lone-surrogate) results, all bounded by the 16 MiB frame (`cm_edit.rs:46-94`).
- `image::identify` is fully `slice::get`-based — every header field bounds-checked, no panic on short/malformed input (`image.rs`).
- `format::pretty_json` recursion is depth-capped at 128; `pretty_xml` is iterative (`format.rs:25-32`).
- `highlight` input is capped by the front-ends (web: 1 MiB read cap + 200k-line cap); tree-sitter parse is linear on that bound.
- FFI null/len handling is uniform and correct across all 16 exports; handles use a `Mutex` + `try_lock`→`Busy` single-writer model; `from_raw`/`into_raw` balanced.