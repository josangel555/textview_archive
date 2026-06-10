# explorer-b — rust-core audit 2026-06-09 (final, post-resume)

## Adversarially confirmed findings

### [S3] Snapshot/table wire frame is hard-capped at 16 MiB — far below the CSV parser's own limits — so a valid large CSV opens but every snapshot/table pull fails with an opaque WireError
- **Where:** `rust-core/crates/core/src/wire.rs:73`
- **Why:** The product is a file viewer; CSVs in the 16–50 MB range are ordinary and parse cleanly, yet are completely unviewable through the FFI — open succeeds, the very next table/snapshot call fails. The failure is indistinguishable (at the C status level) from a genuine codec bug, and there is no pagination/windowing FFI to work around it. This is a functional ceiling silently set an order of magnitude below the parser's advertised caps.
- **Fix:** Either (a) add a windowed snapshot FFI (row range -> frame) so the host pages rows and no single frame approaches the cap, or (b) align MAX_FRAME_LEN with the parse caps and chunk the encode. At minimum, surface a distinct status (e.g. ResultTooLarge) separate from WireError so the host can react, and lower the csv total-cell/scalar caps to what a single frame can actually carry if windowing is deferred.
- **Verifier:** MECHANICS CONFIRMED at every cited point (line numbers for the FFI exports were slightly off but the functions exist as claimed):

- `MAX_FRAME_LEN = 16 * 1024 * 1024` at rust-core/crates/core/src/wire.rs:73, enforced in `encode_frame` at wire.rs:163-166 — returns `WireFault::Framing("frame body {n} exceeds max 16777216")` for any body over 16 MiB.
- CSV parse caps are an order of magnitude larger: `max_total_cells: 32_000_000`, `max_input_scalars: 256 * 1024 * 1024` at crates/core/src/csv.rs:47-48. So a ~21 MB CSV parses cleanly (well under both caps) but its serialized table/snapshot necessarily exceeds 16 MiB — the arithmetic is deterministic, no PoC needed: the frame carries every visible cell string plus the indices array plus msgpack overhead, strictly more than the raw cell bytes.
- `CsvSession::snapshot_frame()` (session.rs:162-184) serializes ALL visible rows into ONE frame via `wire::encode_frame(&view)` — no windowing. `session.table()` egress is likewise single-frame (`wire::encode_frame(session.table())`, ffi/src/lib.rs:489).
- FFI mapping confirmed: `mdvcore_session_table` (ffi/src/lib.rs:472, error → `MdvStatus::WireError` at :495) and `mdvcore_session_snapshot` (:560, error → :587), both with `*out_buf = MdvBuf::empty()` pre-set — so the host gets WireError + empty buf, indistinguishable from an encode bug. Export list confirms NO windowed/paged variant exists (14 exports, none take a row range).

SEVERITY MISCALIBRATED (S2 → S3). The finding's impact claim — "CSVs in the 16-50 MB range are completely unviewable" — does not survive contact with the actual consumers:
1. The ONLY production consumer is Sources/ViewerCore/RustCSVAdapter.swift, which is explicitly fail-safe: any bridge throw falls back to the Swift `CSVParser`, so a >16 MiB table degrades to today's Swift path — the CSV still renders. The gate (RustCSVGate.swift) is also DEFAULT OFF (opt-in via UserDefaults or MDV_RUST_CSV=1).
2. The Swift app path only calls `session.table()` one-shot; `setFilter`/`snapshot` have no production Swift caller — the snapshot pull loop the finding centers on is exercised only by tests/the A-B harness.
3. The TUI and web front-ends use the core in-process and never touch `encode_frame`/`snapshot_frame` (grep over both main.rs: zero hits), so they are unaffected by the cap.

What remains real and worth fixing for the stated production-core goal: the parse-cap vs frame-cap inconsistency is a genuine API-contract defect in the reusable core (the core admits tables its only egress path cannot emit), there is no pagination mechanism in the protocol, and `WireError` conflates "result too large" with "codec bug" so a host cannot react intelligently. The fix sketch (windowed snapshot FFI, or distinct ResultTooLarge status, or aligning the caps) is apt. But with graceful host fallback, a default-off gate, and no affected shipped front-end, this is a functional ceiling / design-debt item for the future FFI-primary world — moderate (S3), not serious (S2). No data loss, no UB, no security dimension.

### [S2] CI merge gate runs clippy + tests on core + ffi ONLY; the network-facing web server, the TUI, and the tree-sitter highlight crate (~7,700 LOC) are excluded entirely
- **Where:** `scripts/rust-core-gate.sh:34`
- **Why:** The web tier parses untrusted HTTP input and is the one component doing security-relevant path confinement and HTML escaping; it ships its own tests that prove the anti-DNS-rebinding and `..`-traversal defenses, but those tests never gate anything. Any of these three crates can be broken on `main` (compile error, regressed traversal guard, panic) and the gate stays green. For a stated production-grade target that includes the TUI and web front-ends, the merge gate covers under 40% of the Rust LOC.
- **Fix:** Add a second gate lane that runs `cargo clippy -p mdvcore-tui -p mdvcore-web -p mdvcore-highlight --all-targets` and `cargo test -p mdvcore-web -p mdvcore-tui -p mdvcore-highlight` (kept separate so their heavier dep trees never enter the app/staticlib build, preserving the existing scoping rationale). Wire it into pr.yml alongside rust-core-gate.sh.
- **Verifier:** Every factual claim checks out exactly as cited:

1. `scripts/rust-core-gate.sh:34` runs `cargo clippy --manifest-path "$RUST_DIR/Cargo.toml" --all-targets` and `:37` runs `cargo test --manifest-path ...` — neither passes `--workspace` or `-p`, so in a virtual workspace cargo operates on `default-members` only.
2. `rust-core/Cargo.toml:23` sets `default-members = ["crates/core", "crates/ffi"]`, and the comment at lines 17-22 explicitly states the CI gate and staticlib build operate on default members only.
3. `.github/workflows/pr.yml:90-98` — the only Rust steps are `build-rust-core.sh` and `rust-core-gate.sh`; no other lane touches tui/web/highlight.
4. `mdvcore-highlight` is a dependency only of `crates/tui` (tui/Cargo.toml:20) and `crates/web` (web/Cargo.toml:22), NOT of core or ffi — so it is genuinely never compiled, clippy-checked, or tested transitively by the gate.
5. `crates/web/src/main.rs:480` contains `fn confined(root: &Path, candidate: &Path)` (the canonicalize+starts_with traversal/symlink guard, per its doc comment at :479), `esc()` HTML-escaping at :1792, and a large `mod tests` from :1861 with security-pinning tests (e.g. `browse_filter_value_is_html_escaped` at :2138, `view_text_is_escaped` at :2149) — tests that exist but never gate a merge.

Refutation angles considered and rejected:
- "It's deliberate design, not a bug": the Cargo.toml comment shows the scoping is intentional (keep ratatui/tree-sitter dep trees out of the app/staticlib build), but the finding already acknowledges this and proposes a separate lane preserving that rationale. Deliberate scoping of the BUILD doesn't justify zero CI coverage of the security-relevant web tier; the consequence (the traversal/XSS tests are dead letters) is real regardless of intent.
- "Maybe highlight is covered via ffi": checked — it is not a dependency of core or ffi.
- "Low impact since web/tui aren't the key FFI path": the audit scope explicitly includes the whole rust-core subtree as the production target, and the gate script's own header (lines 5-11) documents that this exact failure mode (uninvoked checks = dead letters) already shipped panic-capable code once in this repo. A 3,079-LOC hand-rolled HTTP server parsing untrusted bytes that cannot even fail to compile on main is a serious gap, not a nit.

Severity: S2 is justified for the stated production-grade target — the excluded code includes the one component parsing untrusted network input, its security regression tests never run, and there is in-repo precedent of uncovered checks rotting. No adjustment needed.

### [S3] hunk_marks() does unguarded i64 arithmetic on the attacker-controlled new-side line number — panics in dev/test builds, silently wraps to a negative line in release
- **Where:** `rust-core/crates/core/src/diff.rs:474`
- **Why:** The core is contractually panic-free (clippy denies panic/unwrap/indexing workspace-wide) and is fed untrusted `git diff`/`git show` text. In dev/test FFI builds this panics — caught by `ffi_guard!` and degraded to `MdvStatus::Panic`, but the no-panic invariant the whole core advertises is violated. In the shipping `dist` profile (release, overflow-checks off) it does NOT panic; it wraps to ~i64::MIN and emits gutter marks keyed at a hugely negative line — silent wrong output with no signal. Either way it's a defense-in-depth hole reachable from input.
- **Fix:** Clamp the parsed new-side start the same way parse_coord does (`.clamp(0, MAX_COORD)`), and use `saturating_add` / `checked_add` for the `line_in_new` increments. Add a fuzz/property test feeding adversarial hunk headers (i64::MAX, negative, missing terminator) and assert no panic + bounded keys.
- **Verifier:** Verified against actual code. diff.rs:473-474 parses the new-side hunk start to i64 and assigns line_in_new = n - 1 with NO clamp, whereas parse_coord (diff.rs:275-285) clamps to MAX_COORD=1_000_000_000 — confirming the "unclamped twin" claim. Unguarded i64 increments at :497, :502, :506 and line_in_new + 1 at :517. FFI reachability confirmed: mdvcore_diff_hunk_marks (ffi/src/lib.rs:210) -> hunk_marks_wire (diff.rs:547-553) -> hunk_marks on raw caller diff text. No profile enables overflow-checks (root Cargo.toml [profile.*]), and arithmetic_side_effects is NOT in the workspace deny set (only panic/unwrap_used/expect_used/indexing_slicing), so clippy's no-panic gate does not catch this. I wrote a faithful PoC of the exact algorithm (including the empty-trailing-line increment branch): a header `@@ -1 +9223372036854775807 @@` followed by two context lines panics with `attempt to add with overflow` under debug overflow-checks and silently wraps (exit 0, wrong output) under release. The bug is real and matches the cited evidence. One trivial inaccuracy: the finding says the "next" consumed line overflows; with n=i64::MAX, line_in_new=MAX-1, the next line reaches MAX and the one after overflows (needs 2+ lines), but any normal multi-line hunk triggers it, and the cited panic site (:497) and message match. Severity S3 is correct: genuine no-panic-contract violation + silent-wrong-output reachable from FFI on influenceable git-diff text, but it is safe Rust (no UB/memory unsafety), degrades gracefully via ffi_guard! -> MdvStatus::Panic in test builds, and the release consequence is benign mis-keyed gutter marks — below S2, above S4.

### [S3] The documented rich-error wire channel (WireError {code,message,data}) is never emitted — every FFI error path returns a bare status enum with an empty out_buf
- **Where:** `rust-core/crates/ffi/src/lib.rs:10`
- **Why:** When the Swift host hits the 16 MiB cap (finding above), a bad frame, or any failure, it receives only a coarse enum with zero context — no message, no offending size, no field. That makes production diagnosis of the most likely real-world failures (large file, malformed wire) impossible from the host side, and means the carefully-specified error contract is aspirational. A reviewer reading the docs would reasonably assume detail is available when it never is.
- **Fix:** On error, encode a `WireError{code,message,data}` frame into out_buf (the host already must call `mdvcore_buf_free`), so the bare status carries the matching code and the body carries detail. Or delete the WireError type + the doc paragraph if the coarse enum is genuinely the whole contract — but don't ship a documented channel that's never populated.
- **Verifier:** Verified against the code. (1) The doc promise is real: ffi/src/lib.rs:10-11 states rich error detail "rides in the MessagePack wire body", and ffi/src/status.rs:7-8 independently claims the status codes "match the WireError.code carried in the MessagePack body". (2) wire::WireError (core/src/wire.rs:62-69) exists with code/message/data exactly as described. (3) Workspace-wide grep confirms WireError is constructed only once — in wire.rs's own test module (wire.rs:264). No FFI export ever encodes it. (4) Every FFI error arm returns a bare MdvStatus with out_buf left as MdvBuf::empty() (lib.rs:146, 192, 237, 351, 495, 587; empty buf pre-set at lib.rs:129/175/220/272/320/380/482/569), and the Err(_) patterns even discard the WireFault Encode/Decode/Framing detail (wire.rs:77-85) that could populate the body. So the documented rich-error channel is genuinely dead: a 16 MiB MAX_FRAME_LEN violation (wire.rs:73), a malformed frame, and an encode failure are indistinguishable to the Swift host. Severity S3 is correctly calibrated: not exploitable and the coarse statuses are correct (so not S1/S2), but it's a documented cross-language contract that is unimplemented in two doc sites — misleading integrators and erasing already-available error detail — which is more than a nit. Fix sketch (encode WireError into out_buf on error, or delete the type + docs) is sound; the host already must call mdvcore_buf_free on all paths.

## S4 nits (unverified by design)

- hex::render_all trusts the `width` parameter unboundedly — a large width drives a multi-gigabyte Vec::with_capacity / abort, reachable through the FFI hex_render width arg (`rust-core/crates/core/src/hex.rs`)
- Observability seam advertised as FFI-forwardable is not exported across the C ABI — no extern "C" sink installer exists (`rust-core/crates/core/src/trace.rs`)

---

## Full reviewer report

# Rust-core pre-production audit — `rust-core/` workspace

Scope: `crates/{core,ffi,highlight,tui,web}`. Reviewed every `src/*.rs`, the
workspace + per-crate manifests, the CI gate (`scripts/rust-core-gate.sh`,
`.github/workflows/pr.yml`), and the lint/deny config. Two findings were
reproduced with a throwaway crate linked against the live `mdvcore-core`.

## Overall read

The pure core is genuinely high quality for a PoC: `#![forbid(unsafe_code)]`,
a no-panic clippy deny-set (unwrap/expect/indexing/panic) that is actually
enforced on core+ffi, careful UTF-16 handling in `cm_edit`, quote-aware CSV,
end-of-stream-checked MessagePack decode, framing-length validation against a
`MAX_FRAME_LEN`, a depth-guarded JSON pretty-printer, and a well-reasoned FFI
boundary (opaque handle behind a `Mutex` with `try_lock`→`Busy`, `MdvBuf`
allocate-and-free-same-side, `catch_unwind` on every entry point, shipping via
the `panic=unwind` `dist` profile so the guard is real). Unsafe is concentrated,
documented per-block, and the FFI tests exercise null args, double-free,
contention, and the panic→status path.

The problems are at the **edges and the contract**, not the algorithms: a wire
size ceiling set below the parser's own limits, a CI gate that omits ~60% of the
Rust LOC (including the network-facing web server), an unclamped arithmetic path
on untrusted diff input in an otherwise panic-free core, and two
documented-but-unimplemented contracts (rich wire errors; FFI observability).

## Findings (ranked)

### S2 — Wire frame 16 MiB cap makes valid large CSVs unviewable, opaquely
`MAX_FRAME_LEN = 16 MiB` (`wire.rs:73`) bounds `encode_frame`, but the CSV
parser admits 32M cells / 256 MiB of input (`csv.rs:47-48`).
`CsvSession::snapshot_frame()` (`session.rs:162`) and `mdvcore_session_table` /
`mdvcore_session_snapshot` (`ffi/src/lib.rs:368,509`) serialize **all** visible
rows into one frame. Reproduced: a ~21 MB CSV (well under every `csv::Limits`
cap) opens fine, then `snapshot_frame()` returns
`wire framing error: frame body 23068629 exceeds max 16777216`. The host sees
`MdvStatus::WireError` + empty out_buf. There is no windowed/paged snapshot FFI,
so such files are simply unviewable. Fix: add a row-range snapshot FFI (page the
rows) or align the cap + chunk the encode; at minimum return a distinct status
so the host can distinguish "too large" from a codec bug.

### S2 — CI gate excludes web, tui, and highlight crates
`rust-core-gate.sh:34,37` run `cargo clippy --all-targets` / `cargo test` with
no `--workspace`, so the virtual manifest's `default-members = [core, ffi]`
(`Cargo.toml:23`) scope applies — confirmed by the manifest's own comment. The
hand-rolled HTTP/1.1 server (`crates/web/src/main.rs`, 3,079 LOC, parsing
untrusted request bytes + doing `..`/symlink confinement in `confined()` and the
anti-DNS-rebinding `host_allowed` check), the 4,666-LOC TUI, and the highlight
crate are never compiled, clippy'd, or tested on a merge. Their security tests
exist but gate nothing. Fix: a second CI lane running
`cargo {clippy,test} -p mdvcore-web -p mdvcore-tui -p mdvcore-highlight`.

### S3 — `hunk_marks` unguarded i64 arithmetic on untrusted diff
The new-side hunk start is parsed to i64 and used unclamped: `line_in_new = n-1`
(`diff.rs:474`) then incremented (`:497,:502,:506,:517`). Input
`@@ -1 +9223372036854775807 @@` overflows — reproduced as a panic at
`diff.rs:497`. Reachable from `mdvcore_diff_hunk_marks` (`ffi/src/lib.rs:209`).
In dev/test the `ffi_guard!` catches it (→`MdvStatus::Panic`), violating the
core's panic-free contract; in the `dist` release build (overflow-checks off) it
wraps silently to a near-`i64::MIN` line key — wrong output, no signal. Note the
structured `parse_coord` already clamps to `MAX_COORD` (`diff.rs:289`);
`hunk_marks` is the unclamped twin. Fix: clamp the start, `saturating_add` the
cursors, add an adversarial-header test.

### S3 — Rich `WireError` channel documented but never emitted
`ffi/src/lib.rs:10` promises rich error detail "rides in the MessagePack wire
body"; `wire::WireError` (`wire.rs:62`) exists. But every FFI error arm writes
`MdvBuf::empty()` and returns a bare enum (e.g. `Err(_) => MdvStatus::WireError`
throughout `lib.rs`). `WireError` is built only in wire.rs tests. The host can
never get a message/context for the failures it will actually hit (large file,
malformed wire). Fix: encode a `WireError` frame into out_buf on error, or
delete the type + doc paragraph.

### S4 — `hex::render_all` trusts `width` unboundedly
`mdvcore_hex_render` forwards `width: u32` (`ffi/src/lib.rs:283`) into
`render_all`, where `per_row = 8+2+(width*3-1)+2+width+1` (`hex.rs:27`) feeds
`Vec::with_capacity(header.len()+rows*per_row)` (`hex.rs:72`). A near-`u32::MAX`
width requests ~16 GB → `handle_alloc_error` abort (uncatchable). Caller-
controlled, so low impact today (app passes 16), but a reusable core shouldn't
trust an unbounded geometry parameter across the ABI. Fix: clamp width.

### S4 — Observability seam not exported across FFI
`trace.rs:9-11` says "the FFI layer can forward these across the C ABI to a Swift
closure" and frames the module as the `ObservabilitySink` analog, but no
`mdvcore_set_sink`-style symbol exists among the `#[unsafe(no_mangle)]` exports.
`trace::set_sink` is reachable only in-process (TUI/web), so for the primary
consumer (Swift over FFI) every span/event is dropped. Fix: export an
extern "C" sink installer (catch_unwind-guarded callback) or correct the doc.

## Notable things checked and found sound
- `MdvBuf` raw-parts round-trip stores `cap`, double-free nulls fields, free
  paths are `catch_unwind`-wrapped (no unwind across C in `Drop`).
- `SessionHandle` `Send+Sync` is justified by the `Mutex`; poisoned-lock
  recovery is deliberate and documented.
- `decode`/`decode_frame` reject trailing bytes and oversized/short frames;
  `MAX_FRAME_LEN` guards the decoder against a hostile length prefix.
- Web server: complete HTML escaping (`esc` covers `& < > " '`), path
  confinement via `canonicalize`+`starts_with` (closes `..`/symlink), header
  byte cap, socket timeouts, in-flight cap, grep symlink-loop guard.
- `format::pretty_json` bounds recursion at depth 128; `pretty_xml` is iterative.
- `filter` ASCII fast-path is correctly gated to ASCII-only and parity-tested
  against a Unicode reference (Turkish dotted-I, sharp-S).

## Verification notes (defending the reproduced findings)
- 16 MiB cap: built `/tmp/mdv-audit-poc` against the live crate; `bigcsv` mode
  opened a 21 MB CSV then `snapshot_frame()` returned the framing error above
  (exit 0, graceful error — confirming the functional ceiling, not a crash).
- diff overflow: same harness, `overflow` mode panicked at `diff.rs:497`
  ("attempt to add with overflow") in a debug build.