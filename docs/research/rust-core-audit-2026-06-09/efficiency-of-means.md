# efficiency-of-means — rust-core audit 2026-06-09

## UNVERIFIED (verifier died on session limit — re-run on resume)

- [S2] tui/web/highlight crates (8.3k LoC) sit outside every lint and test gate — rot is already accumulating
- [S3] Dead function: web `render_view` is never called
- [S3] FFI entry-point bodies are copy-pasted ~6x — three byte-identical frame-in/frame-out fns and a repeated 20-line unsafe prologue
- [S3] mdvcore-ffi declares `serde` and `rmp-serde` dependencies it never uses
- [S3] TUI and web re-implement the same helpers: read_capped, human_size, mtime_secs, git-status spawn, ViewMode token map, key=value config codec
- [S3] Hex bytes-per-row (16) is defined three times; core's HEX_WIDTH is private while both front-ends hardcode a mirror
- [S3] trace facade is an over-general seam nothing consumes: no FFI forwarding (despite docs claiming it), sink installers unused, elapsed_micros always None
- [S3] core::theme's cross-front-end palette contract is honored only by the TUI — web hardcodes its own ~30-color palette, partially duplicating the One Dark/Light values
- [S3] Pub API surface with zero external consumers (incl. wire::WireError — the documented rich-error channel that is never sent)
- [S3] 60 standing clippy warnings on mdvcore-core saturate the warn tier — 18 are false-positive case-sensitive-extension hits on already-lowercased strings

## S4 nits (unverified by design)

- ffi build.rs prints a cargo:warning on every successful build (permanent noise on the success path) (`rust-core/crates/ffi/build.rs`)
- Machine-generated, non-snake-case integration-test filenames leak audit-tooling names into the crate (`rust-core/crates/core/tests/Audit_rust_core_crates_core_src_diff_rs_split_parity.rs`)
- Stage-0 scaffolding `mdvcore_add` still exported in the production C ABI (`rust-core/crates/ffi/src/lib.rs`)
- [profile.dev] restates compiler defaults (`rust-core/Cargo.toml`)

---

## Full reviewer report

# rust-core TIGHTNESS audit — 2026-06-09

**Dimension:** code-level economy and discipline ("super tight" / no-fat pass).
**Scope:** `rust-core/` workspace only — `crates/core` (21 modules, sans-IO), `crates/ffi` (the unsafe C ABI edge), `crates/highlight`, `crates/tui` (4,666-line monolith), `crates/web` (3,079-line monolith), workspace manifests, `clippy.toml`, `scripts/rust-core-gate.sh`, `scripts/build-rust-core.sh`.
**Method:** full read of core + ffi sources and manifests; targeted reads of tui/web/highlight; fresh `cargo clippy --workspace --all-targets` run; mechanical pub-API consumption sweep (every `pub fn` in core grepped for references outside its defining file, across all crates incl. integration tests); CI-lane grep across `.github/workflows/` + `scripts/`.

## Verdict in one paragraph

The gated half of the workspace (core + ffi) is genuinely tight: zero TODO/FIXME debt, every `#[allow]` carries a written reason, deps are exact-pinned, the no-panic deny-set is enforced by a real gate, and even the gate's enforcement is itself regression-tested (the manifest-asserting `no_panic_lints_gate` test). The fat is concentrated in three places: **(1) everything outside `default-members` is outside every gate** and is already rotting (compiler-proven dead code, never-run test suites); **(2) the two front-end monoliths duplicate each other** (identical helpers, token maps, config codecs) and partially bypass core abstractions built for them (`theme`); **(3) core carries unconsumed surface** — a trace facade whose host seam was never wired, a documented rich-error wire type never sent, and a dozen pub fns nothing calls.

---

## S2 — the gate hole (the one structural finding)

### 1. tui/web/highlight are outside every lint/test gate; rot is measurable

- `rust-core/Cargo.toml:23` — `default-members = ["crates/core", "crates/ffi"]`.
- `scripts/rust-core-gate.sh:33-37` — both `cargo clippy` and `cargo test` run against the manifest with no `--workspace`, i.e. default-members only. No workflow or script anywhere invokes `-p mdvcore-tui` / `-p mdvcore-web` / `-p mdvcore-highlight` (grepped `.github/workflows/`, `scripts/*.sh`).
- The gate header (`rust-core-gate.sh:16`) says "`cargo test` runs every workspace crate's tests (core + ffi)" — the parenthetical contradicts the claim; only the parenthetical is true.
- Measured consequences, today:
  - `warning: function render_view is never used` — `crates/web/src/main.rs:651` (dead wrapper superseded by `render_view_filtered`).
  - 5 standing `doc_lazy_continuation` warnings in tui.
  - The TUI's ~1,600 lines of in-crate tests — including the ratatui `TestBackend` per-cell color assertions this project documents as its *host pixel coverage* for the TUI — never run in CI. They are dead letters exactly like the pre-gate "65+ pure cargo tests" the gate script's own header describes fixing for core.

The scoping rationale in `Cargo.toml` (keep ratatui's dep tree out of the merge gate and the macOS app build) is sound for *builds*, but it was silently extended to *all enforcement*. Fix: a second gate stanza (or nightly lane) running `cargo clippy/test` for the three excluded crates; correct the gate-script comment.

---

## S3 — duplication and dead surface

### 2. Dead code: web `render_view` (`crates/web/src/main.rs:651`)
Compiler-proven (`dead_code` warning). Thin wrapper over `render_view_filtered` (main.rs:665); all call sites migrated. Delete it — and note `render_view_filtered`'s 12 positional args under `#[allow(clippy::too_many_arguments)]` (main.rs:664) want a params struct.

### 3. FFI entry-point boilerplate ×6 (`crates/ffi/src/lib.rs:119-240`)
`mdvcore_cm_apply` / `mdvcore_diff_parse` / `mdvcore_diff_hunk_marks` are **identical** apart from the one core call. The null-check → `MdvBuf::empty()` init → `from_raw_parts` prologue (3 SAFETY comments each) repeats again in `mdvcore_hex_render`, `mdvcore_hex_search`, `mdvcore_indent_detect`, `mdvcore_session_open`, `mdvcore_session_set_filter`. ~8 hand-maintained copies of the same unsafe marshaling in the only unsafe crate. Fix: `unsafe fn slice_in(ptr, len) -> Result<&[u8], MdvStatus>` + a `frame_entry(req, req_len, out_buf, f)` helper (or `ffi_frame_fn!` macro); the wire entry points become one-liners and the SAFETY reasoning lives once. This is both economy and risk-surface reduction.

### 4. ffi declares `serde` + `rmp-serde` and uses neither (`crates/ffi/Cargo.toml:45-46`)
Zero references in `ffi/src/` or `build.rs` — all encoding rides `mdvcore_core::wire`. Cargo never warns about this. Delete both lines (workspace-unified versions ⇒ no behavior change).

### 5. tui ↔ web duplicated helpers (the "core should own it" list)
| Helper | tui | web | Pure? |
|---|---|---|---|
| `read_capped` | main.rs:2968 | main.rs:1743 | IO (byte-identical) |
| `human_size` | main.rs:2991 | main.rs:1771 | **pure** (byte-identical) |
| `mtime_secs` | main.rs:2942 | main.rs:1764 | IO (identical) |
| git porcelain spawn | `git_status_for` :2954 | `git_status_html` :821 | IO (same Command incantation) |
| ViewMode↔token map (6 arms) | `mode_token`/`mode_from_token` :419-440 | `mode_str` :1303 / `parse_mode` :1291 | **pure** — and it's the persisted-config AND URL vocabulary |
| key=value config codec + `config_path`/`load_config`/`save_config` | :338-397, :482-497 | :84-131 | codec is **pure** |

The project already hoists exactly this class (`nav::cmp`, `view::table_col_widths`, `nav::breadcrumbs`, `whitespace::reveal` all carry "same by construction" comments). Hoist the pure rows into core (`ViewMode::as_str/from_str` is the highest-value one — token drift corrupts saved sessions and links); the IO rows go to a tiny shared front-end-util crate or stay duplicated with cross-link comments.

### 6. Bytes-per-hex-row = 16, defined three times
`view.rs:15` (`const HEX_WIDTH`, **private**), tui main.rs:54 and web main.rs:46 (each a local `HEX_BYTES_PER_ROW: usize = 16` whose comment says "must match" core). Offset→row math (tui:1889-1891, web:1036/1273) silently breaks on drift. Make core's constant `pub` and reference it.

### 7. The trace facade: an unwired seam with a live cost (`crates/core/src/trace.rs`)
- Doc (trace.rs:9-11) claims "The FFI layer can forward these across the C ABI… (see `mdvcore-ffi`)" — **no trace reference exists anywhere in ffi**.
- `set_sink`/`clear_sink` (trace.rs:92/99): used only by trace's own unit tests. No production host can ever install a sink.
- `Record::SpanExit.elapsed_micros` (trace.rs:65): hardwired `None` at both emit sites (:146, :187); the "host-injected timer" it documents has no hook.
- Meanwhile every `csv::parse` / `CsvSession::open/set_filter/snapshot` takes the `RwLock` read to deliver to a sink that can't exist.

Either wire it (an `mdvcore_trace_set_sink(extern "C" fn …)` export — the stated design and the `ObservabilitySink` analog the Swift app would actually use) or cut the Sink/RwLock machinery and dead field until a consumer arrives. Fix the doc either way.

### 8. `core::theme` is honored by one of the two front-ends it names
theme.rs:1-8 declares the palette shared with "CSS for the web front-end", but web never imports `theme`; its `page()` CSS hardcodes ~30 hex literals, several byte-duplicating theme values (`#0184bc`/`#4078f2` at web:1679 = Light Accent/Header; `#56b6c2`/`#61afef` at web:1718 = Dark Accent/Header; also `#e5c07b`, `#fafafa`). Generate the shared roles as CSS custom properties from `Palette`, or re-scope the module doc to TUI-only reality.

### 9. Unconsumed pub surface (mechanical sweep, all crates + tests)
Externally unreferenced: `csv::detect_delimiter` (:57), `csv::parse_with` (:128), `diff::hunk_marks` (:460 — only its own `_wire` wrapper), `hex::hex_search_find`/`rendered_row_length`/`row_count` (:171/:25/:33), `session::from_table` (:74), `theme::parse_hex` (:116), `view::looks_tabular` (:246), `trace::set_sink`/`clear_sink`.
Worst case: **`wire::WireError`** (wire.rs:62) — never constructed outside its own byte-parity test, yet `ffi/src/lib.rs:10-11` and `status.rs:7-8` document a rich-error wire channel ("the codes also match the WireError.code carried in the MessagePack body") that **does not exist**. A Swift implementer reading the contract would build a decoder for frames that are never sent. Implement the channel or delete the type and fix two crates' docs. For the rest: `pub(crate)` the internal helpers; keep deliberate future-API only with an explicit marker.

### 10. 60 standing warnings on mdvcore-core saturate the warn tier
`cargo clippy --workspace --all-targets`: core lib alone generates 60 warnings. Buckets: 18× `case_sensitive_file_extension_comparisons` — **all false positives** (every site lowercases first: image.rs:76-86, outline.rs:38-41, view.rs:223-232); 10× `doc_markdown`; 6× `must_use`; 2× deliberate `match_same_arms` (theme.rs:89/93 — CurrentBg intentionally aliases Hunk); assorted `format!`-append, redundant-closure, cast-lossless in non-core crates. The gate's design (deny=fail, pedantic-warn=signal) only works at ~zero standing warnings; at 60, a new real warning is invisible. One cleanup pass: switch extension checks to `Path::extension().is_some_and(|e| e.eq_ignore_ascii_case(..))` (also kills the `to_ascii_lowercase` alloc per call), backtick the doc idents or extend `doc-valid-idents`, add the `must_use`s, and reason-`allow` the two deliberate same-arm matches.

---

## S4 — nits

11. **build.rs success-path warning** (`ffi/build.rs:56-59`): `cargo:warning=cbindgen wrote header to …` on every successful build. Real failures two lines below use the same channel and now blend in. Drop or env-gate it.
12. **Machine-generated test filenames**: `crates/core/tests/Audit_rust_core_crates_core_src_diff_rs_split_parity.rs`, `…session_rs_snapshot_frame.rs`, `crates/ffi/tests/no_panic_lints_gate_Audit_rust_core_crates_ffi_Cargo_toml.rs` — path-mangled audit-tool artifacts, non-snake-case test-target names. Rename to `diff_split_parity.rs`, `snapshot_frame_parity.rs`, `ffi_no_panic_lint_gate.rs`.
13. **`mdvcore_add` Stage-0 smoke** (`ffi/src/lib.rs:72`) still in the production header/symbol table. Exports are forever per the crate's own ABI discipline; drop it (unlike `mdvcore_force_panic`, which is load-bearing for the cross-language panic test).
14. **`[profile.dev]` restates defaults** (`Cargo.toml:79-81`): `opt-level = 0`, `debug = true` are cargo's dev defaults.

---

## Checked and CLEAN (no finding)

- **Panic-semantics vs profiles** — the dimension's explicit check: `release` is `panic="abort"` (size-figure only) and `dist` is `panic="unwind"`; `scripts/build-rust-core.sh:30-48` *enforces* that only `dist|dev|test` may be linked into the app and rejects `release` (and any custom profile) with an explanatory error. Documented invariant verified end-to-end. ✅
- **TODO/FIXME debt**: zero markers in the entire workspace (the two grep hits are `\\uXXXX` doc text). ✅
- **`#[allow]` hygiene in gated crates**: every allow carries a `reason` (csv.rs:124 too_many_lines, diff.rs:58/289 struct_excessive_bools, ffi lib.rs:43 missing_safety_doc, lib.rs:92 the deliberate test panic). Web's reason-less allows (main.rs:664/912) are a side effect of finding #1 (no workspace-lints inheritance there). ✅
- **Dep pinning / features**: everything `=`-pinned incl. all 12 grammar crates; `serde` default-features=false; `cbindgen` default-features=false. ✅
- **wire.rs economy**: the single-allocation `encode_frame` rewrite is pinned byte-identical against the legacy implementation in tests; `decode` end-of-stream check closes the trailing-bytes hole; `MAX_FRAME_LEN` guards hostile prefixes. Tight. ✅
- **Monomorphization/generics**: generics are minimal (`wire::encode/decode<T>` over 3 wire types, `find_in_table<R: AsRef<[String]>>`, `history::push<T: PartialEq>`); no bloat. ✅
- **Error-style consistency**: pure-fallible → `Option` (format, cm_edit, theme::parse_hex), wire-boundary → `Result<_, WireFault>`, session open → typed `OpenError`, FFI → `MdvStatus`. Consistent and deliberate. ✅
- **`tui::sort_loaded`** looked like comparator duplication but is the opposite: it mirrors entries into `nav::Entry` and sorts via the shared `nav::cmp` to avoid re-deriving the ordering. Good pattern (it's the one the dup finding #5 asks the token maps to follow). ✅

## Suggested fix order

1. Gate the ungated crates (finding 1) — everything else regresses without it.
2. The one-pass warning zero-out (10) + dead `render_view` (2) — mechanical, makes future drift visible.
3. FFI marshaling helper (3) + drop ffi's unused deps (4) — shrinks the audited unsafe surface.
4. Hoist `ViewMode` tokens + `human_size` + config codec into core; `pub const HEX_WIDTH` (5, 6).
5. Decide trace's fate and WireError's fate (7, 9) — wire them or cut them; both currently document fiction.
6. Nits (8 doc-or-adopt for theme, 11-14) opportunistically.

No new third-party dependencies are required by any fix above; everything is deletion, demotion, hoisting into existing crates, or (optionally) one new dep-free workspace member for shared front-end IO helpers.