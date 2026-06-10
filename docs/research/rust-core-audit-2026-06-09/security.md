# security — rust-core audit 2026-06-09

## Adversarially confirmed findings

### [S3] Web served-root fails OPEN to `/` when the start path can't be canonicalized
- **Where:** `rust-core/crates/web/src/main.rs:159`
- **Why it matters:** A canonicalize failure should fail CLOSED (refuse to start), not broaden the served scope from a single directory to the entire filesystem. `mdv-web /typo` silently exposes all of `/` over 127.0.0.1:8765 to any local process / browser tab (the path-confinement chokepoint is now a no-op). This is the classic fail-open anti-pattern in the one security boundary the web tier has.
- **Fix sketch:** On canonicalize failure, `eprintln!` and `std::process::exit(1)` (or return an `io::Error`) instead of defaulting to `/`. Also canonicalize+validate the CLI `start-dir` the same way the config root is validated, and reject a root of `/` explicitly unless an opt-in flag is passed.
- **Verifier:** Verified line-by-line at /Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/web/src/main.rs. (1) Line 159 is exactly `.unwrap_or_else(|_| PathBuf::from("/"));` applied to `root.canonicalize()` in main() (lines 149–159). (2) The CLI positional arg (lines 142–144) is taken raw into `start` with no existence/is_dir validation — only the config-restored root gets `.filter(|d| d.is_dir())` — so `mdv-web /typo` makes canonicalize fail and root silently becomes `/`. (3) `confined()` at lines 480–483 is `c == *root || c.starts_with(root)`; with root `/`, every canonicalized absolute path passes, so the single confinement chokepoint (used by /browse line 315, grep 326/581, /view 331, recents 408) becomes a no-op and the whole filesystem is served. (4) Aggravating factor the finding missed: line 162-164 `save_config` persists the resolved root, and since `/` IS a dir it survives the next argless launch's `is_dir()` filter — the broken root is sticky across restarts. Severity check: S3 is calibrated. It is a genuine fail-open that nullifies the tier's only security boundary, but exploitation requires a user-side typo, the server binds 127.0.0.1 only, host_allowed() (lines 469-475) blocks DNS-rebinding Host headers, and same-origin policy blocks browser-tab reads — so the practical attacker is a local same-user process, which limits it below S2. Fix sketch (fail closed with exit(1), validate the CLI start-dir like the config root) is correct and sufficient.

## UNVERIFIED (verifier died on session limit — re-run on resume)

- [S3] No total request deadline — slow-loris can pin worker slots for tens of hours
- [S3] CSV parser memory amplification: default caps permit ~2 GB from a ~32 MB file
- [S3] Directory listing is unbounded (no entry cap), unlike the 5000-row table cap

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