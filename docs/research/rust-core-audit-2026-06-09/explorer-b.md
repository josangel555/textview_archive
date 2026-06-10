# explorer-b — rust-core audit 2026-06-09

## UNVERIFIED (verifier died on session limit — re-run on resume)

- [S2] Snapshot/table wire frame is hard-capped at 16 MiB — far below the CSV parser's own limits — so a valid large CSV opens but every snapshot/table pull fails with an opaque WireError
- [S2] CI merge gate runs clippy + tests on core + ffi ONLY; the network-facing web server, the TUI, and the tree-sitter highlight crate (~7,700 LOC) are excluded entirely
- [S3] hunk_marks() does unguarded i64 arithmetic on the attacker-controlled new-side line number — panics in dev/test builds, silently wraps to a negative line in release
- [S3] The documented rich-error wire channel (WireError {code,message,data}) is never emitted — every FFI error path returns a bare status enum with an empty out_buf

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