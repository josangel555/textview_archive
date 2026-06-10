# efficiency-of-means — rust-core audit 2026-06-09 (final, post-resume)

## Adversarially confirmed findings

### [S2] tui/web/highlight crates (8.3k LoC) sit outside every lint and test gate — rot is already accumulating
- **Where:** `rust-core/Cargo.toml:23`
- **Why:** Two of the three front-ends plus the highlight crate — more code than core+ffi combined — have zero automated enforcement. Dead code, warnings, and broken tests accumulate silently, which directly contradicts both the project's own change→tests mandate and the "rock solid" goal. The dead `render_view` proves this isn't theoretical.
- **Fix:** Add a second stanza to scripts/rust-core-gate.sh (or a nightly lane if ratatui compile time is the concern): `cargo clippy --workspace --all-targets -- -D warnings`-equivalent and `cargo test --workspace` (or explicit `-p mdvcore-tui -p mdvcore-web -p mdvcore-highlight`). At minimum run `cargo test -p mdvcore-tui -p mdvcore-web` in the nightly VM lane and fix the gate-script comment.
- **Verifier:** Finding survives adversarial verification on every load-bearing claim:

1. `rust-core/Cargo.toml:23` — `default-members = ["crates/core", "crates/ffi"]`, confirmed; lines 17–22 document that the gate and Swift staticlib build operate on default members only.
2. `scripts/rust-core-gate.sh:34,37` — `cargo clippy --all-targets` and `cargo test` with `--manifest-path` only, no `--workspace`/`-p`, so both cover only default-members. Confirmed by reading the script.
3. Zero other automated coverage: grep across `scripts/` and `.github/` finds no reference to mdvcore-tui/mdvcore-web/mdvcore-highlight; the only CI cargo entry points are `rust-core-gate.sh` (default-members) and `build-rust-core.sh:78` (default-members build). `pr.yml:97` just calls the gate.
4. Dead code confirmed by compilation: `cargo check -p mdvcore-web` emits `warning: function render_view is never used` (crates/web/src/main.rs:651). Nuance: its ~40 callers are all inside the `#[cfg(test)]` module, so it is a test-only helper missing a cfg attribute — mild rot, not abandoned product code — but it is exactly the class of warning no gate ever sees.
5. TUI test suite never runs anywhere: `crates/tui/src/main.rs` test module spans lines 3054–4666 (~1,612 lines, 60 `#[test]`s), including the TestBackend per-cell tests the project memory explicitly treats as its host pixel coverage for TUI rendered behavior. No CI lane (merge or nightly) executes them.
6. Gate-script comment `rust-core-gate.sh:16` does say "`cargo test` runs every workspace crate's tests (core + ffi)" — literally false for a 5-crate workspace, though the parenthetical narrows it; partially mitigating.

Minor inaccuracies that do not change the verdict: the claimed "5 standing doc-lint warnings in tui" did not reproduce — my `cargo check` shows 7 missing-docs warnings attributed to mdvcore-core (lib) and 0 to tui. Also, the exclusion from the merge gate is deliberate and documented (dep-tree scoping for ratatui/crossterm), so this is a known scoping decision — but the documented rationale covers only the merge gate, not the total absence of any lint/test lane.

Severity S2 holds: TUI and web are first-class front-ends per the owner's standing decision, highlight contains the isolated unsafe tree-sitter FFI, the three crates exceed core+ffi in LoC, existing tests silently never execute (a false sense of coverage, the project's recurring failure mode), and demonstrable warnings already accumulate — directly contrary to the change→tests mandate and the production-grade goal. Fix sketch (workspace-wide clippy/test stanza in the gate or a nightly lane + correcting the comment + `#[cfg(test)]` on render_view) is sound and cheap (web is std-only; tui/highlight compile is the only cost, addressable via the nightly lane).

### [S4] Dead function: web `render_view` is never called
- **Where:** `rust-core/crates/web/src/main.rs:651`
- **Why:** Compiler-verified dead code in a shipped binary; also the canary proving the front-end crates are ungated.
- **Fix:** Delete `render_view` (or re-point trivial call sites to it and give `render_view_filtered` a params struct — see the 12-positional-args `#[allow(clippy::too_many_arguments)]` at main.rs:664).
- **Verifier:** Verified: cargo clippy -p mdvcore-web emits `function 'render_view' is never used` at crates/web/src/main.rs:651, and production code calls only render_view_filtered (the sole non-test call path at main.rs:361). However, the finding's evidence is partially wrong: render_view is NOT abandoned — it has ~40 call sites, all inside the #[cfg(test)] module (begins line 1860; calls at 2151–3042), making it a test-only convenience wrapper missing a #[cfg(test)] attribute, not migrated-and-forgotten dead code. The proposed fix (delete it) would break ~40 tests; the right fix is `#[cfg(test)]` on the wrapper. Impact is pure lint hygiene with no correctness/security/size consequence, so S3 is miscalibrated — this is an S4 nit. The 'canary for ungated crates' weight belongs to the separate gating finding.

### [S3] FFI entry-point bodies are copy-pasted ~6x — three byte-identical frame-in/frame-out fns and a repeated 20-line unsafe prologue
- **Where:** `rust-core/crates/ffi/src/lib.rs:119`
- **Why:** Every new FFI slice copy-pastes ~30 lines of unsafe code; a future edit fixing one copy (e.g. a tightened null/len check) can silently miss the others. The crate's own lint posture (`multiple_unsafe_ops_per_block`, per-block SAFETY) shows the team knows this is the highest-risk surface — centralizing the pattern shrinks the audited unsafe area severalfold.
- **Fix:** Add two private helpers: `unsafe fn slice_in<'a>(ptr: *const u8, len: usize) -> Result<&'a [u8], MdvStatus>` and `unsafe fn frame_entry(req, req_len, out_buf, f: fn(&[u8]) -> Result<Vec<u8>, WireFault>) -> MdvStatus` (or a `ffi_frame_fn!` macro). The three wire fns collapse to one-liners; the SAFETY reasoning lives in exactly one place.
- **Verifier:** Verified by reading rust-core/crates/ffi/src/lib.rs in full. The three cited frame-in/frame-out fns (mdvcore_cm_apply 119-149, mdvcore_diff_parse 165-195, mdvcore_diff_hunk_marks 210-240) are byte-identical except for the one core function called — including identical SAFETY comments. The 15-20 line unsafe prologue (out_buf null check, MdvBuf::empty init, null/len check, from_raw_parts) additionally repeats in mdvcore_hex_render (267-281), mdvcore_hex_search (315-336, two slice-ins), mdvcore_indent_detect (375-390), mdvcore_session_open (432-449), and mdvcore_session_set_filter (516-530) — 8+ hand-maintained copies, matching the claim. No current defect (each copy is correct and documented), so this is a maintainability/divergence risk on the sole unsafe crate, not an exploitable bug — S3 is correctly calibrated. The fix sketch (slice_in helper + frame_entry/ffi_frame_fn! macro) is sound and would collapse the three wire fns to one-liners.

### [S4] mdvcore-ffi declares `serde` and `rmp-serde` dependencies it never uses
- **Where:** `rust-core/crates/ffi/Cargo.toml:45`
- **Why:** Cargo doesn't warn on unused deps, so the manifest misstates the crate's true dependency surface — exactly the kind of drift the project's minimal-deps posture is supposed to prevent. Anyone auditing the FFI crate's supply chain audits two deps it doesn't have.
- **Fix:** Delete both lines from crates/ffi/Cargo.toml [dependencies]; `cargo build -p mdvcore-ffi` to confirm (versions are workspace-unified, so no behavior change).
- **Verifier:** Verified: rust-core/crates/ffi/Cargo.toml:45-46 declares serde and rmp-serde, and a recursive grep over every .rs file in crates/ffi/ (src/, tests, build.rs) finds zero references to either — all encoding goes through mdvcore_core::wire. Removal is provably safe: mdvcore-core (the ffi crate's sole path dep) already depends on both with the same workspace-pinned versions/features (core/Cargo.toml:14,18; pins at rust-core/Cargo.toml:34-35), and ffi adds no extra features, so the lockfile/feature graph is unchanged. However, S3 is miscalibrated: because both crates remain in the dependency graph transitively via mdvcore-core, the built artifact and the actual supply-chain surface are byte-identical either way — an auditor of the FFI crate's full dep tree sees the same crate set. The defect is direct-dep manifest hygiene only (cargo-machete class), with no functional, security, or build-graph impact → S4 nit. Fix sketch (delete the two lines, cargo build -p mdvcore-ffi) is correct.

### [S3] TUI and web re-implement the same helpers: read_capped, human_size, mtime_secs, git-status spawn, ViewMode token map, key=value config codec
- **Where:** `rust-core/crates/web/src/main.rs:1743`
- **Why:** This is precisely the "same feature implemented twice that core should own" class. The pure pieces (human_size, mode tokens, config codec) can drift independently — mode tokens drifting breaks saved sessions/URLs cross-front-end; the project's own pattern (nav::cmp, view::table_col_widths, whitespace::reveal were all hoisted for exactly this reason) shows the intended home.
- **Fix:** Hoist the pure ones into core: `ViewMode::as_str()/from_str()` on view::ViewMode (both front-ends already import view), `format::human_size` (or a new tiny core module), and a `config` module owning the key=value codec (text ↔ Vec<(&str, String)>). The IO pair (read_capped, mtime_secs, git spawn) can't enter sans-IO core — put them in a small shared `mdvcore-frontend-util` crate or accept the duplication with a cross-link comment.
- **Verifier:** Every cited pair verified by reading both files. Byte-identical: read_capped (tui:2968/web:1743), human_size (tui:2991/web:1771), mtime_secs (tui:2942/web:1764). Near-identical as claimed: the git `-C <dir> --no-optional-locks status --porcelain=v1 --branch` spawn (tui git_status_for ~:2954 / web git_status_html :821) — both even comment that parsing is shared so the tiers stay identical, while the spawn is hand-copied; the six-token ViewMode maps (tui mode_token/mode_from_token :419-440 / web mode_str :1303-1312 plus URL-parse arms), two hand-kept copies of the same vocabulary; and the lenient key=value codec scaffold + config_path/load_config/save_config trios (tui :338-396, :482-500 / web :84-131), differing only in keys handled and the tui/wui path segment. Minor overstatement: the configs are per-front-end, so token drift would cause divergent vocabularies, not corruption of existing cross-front-end sessions — this doesn't change the verdict. Severity S3 holds: not a bug today, but six distinct duplicated items across two monolithic, out-of-gate front-end mains, including protocol-ish token vocabulary, in a project whose explicit mandate is a reusable core with an established hoisting pattern (view::table_col_widths, git::parse_status). Fix sketch is sound and correctly notes the IO helpers cannot enter the sans-IO core.

### [S3] Hex bytes-per-row (16) is defined three times; core's HEX_WIDTH is private while both front-ends hardcode a mirror
- **Where:** `rust-core/crates/core/src/view.rs:15`
- **Why:** A literal whose comment says "must match" is the textbook drift bug: change core's width and every front-end's hex-search row mapping silently breaks (no compile error, no test crossing the crates).
- **Fix:** Make it `pub const HEX_WIDTH: usize = 16;` in core (view or hex module) and have tui/web/FFI callers reference `view::HEX_WIDTH` instead of re-declaring 16.
- **Verifier:** Verified against the code. core/src/view.rs:15 declares `const HEX_WIDTH: usize = 16;` (private — no `pub`), used at view.rs:461 in `view::build` via `hex::render_all(bytes, HEX_WIDTH, ...)`. tui/src/main.rs:54 re-declares `const HEX_BYTES_PER_ROW: usize = 16;` with the comment "must match `mdvcore_core::hex::render_all`" and uses it for match-offset→row math at 1889-1891. web/src/main.rs:46 re-declares the same constant with the comment "mirrors core `view::HEX_WIDTH`" and uses it at 1036 and 1273. The coupling is functional, not cosmetic: both front-ends render the hex dump produced by core's `view::build` (tui 765/1064/1124, web 934), which uses the private HEX_WIDTH, then map search-hit byte offsets to rows using their own local 16. Because the core constant is private, the front-ends cannot reference it; changing it desynchronizes hex-search row mapping in both tiers silently (no compile error), and tui/web sit outside the rust-core gate's default-members so no gating test crosses the crates. Fix sketch (make it `pub` and reference it from tui/web) is correct. S3 is appropriately calibrated: no present misbehavior (all three values are 16), but a real silent cross-crate drift hazard affecting user-visible hex-search navigation — above a nit, below a live bug.

### [S3] trace facade is an over-general seam nothing consumes: no FFI forwarding (despite docs claiming it), sink installers unused, elapsed_micros always None
- **Where:** `rust-core/crates/core/src/trace.rs:92`
- **Why:** Dead abstraction with a live runtime cost on the hot CSV path, plus module docs that promise a mechanism that doesn't exist. For "the real thing" the seam should either be wired (an `mdvcore_trace_set_sink` FFI export taking a C callback — it's the stated design) or cut to nothing.
- **Fix:** Either (a) implement `mdvcore_trace_set_sink(extern "C" fn(...))` in ffi and keep the facade honest (drop `elapsed_micros` or add the timer hook), or (b) demote: delete the Sink/RwLock machinery and the dead field, keep span/event call sites behind a no-op (or `#[cfg(feature = "trace")]`) until a consumer exists. Fix the module doc either way.
- **Verifier:** Verified all claims against the actual code. (1) False doc cross-reference: rust-core/crates/core/src/trace.rs:9-11 states "The FFI layer can forward these across the C ABI to a Swift closure (see `mdvcore-ffi`)" — but `grep -rn trace crates/ffi/src/` returns zero matches; no trace-related FFI export exists. (2) Sink installers unused: `set_sink` (trace.rs:92) and `clear_sink` (trace.rs:99) are referenced nowhere in the workspace outside trace.rs's own #[cfg(test)] module — a repo-wide grep for `set_sink` hits only trace.rs itself; neither tui, web, highlight, nor ffi installs a sink, so no production host can ever receive a record. (3) `elapsed_micros` is dead: the only production emit site is `Drop for Span` (trace.rs:142-148), which hardwires `elapsed_micros: None`; the doc at trace.rs:57-60 claims "the duration is computed by the host-injected timer in the span guard" but `Span` (trace.rs:130-132) has no timer injection point whatsoever — that doc is also false. (Minor citation slop in the finding: trace.rs:187 is a test assertion, not a second emit site, and there is exactly one emit site rather than "both" — immaterial to the substance.) (4) Live cost on hot paths: `emit` (trace.rs:108-114) takes the global RwLock read on every record, and call sites exist in csv.rs:129/251/275 (`csv.parse` span + events) and session.rs:53/106/109/113/130/163 — a handful of uncontended RwLock reads per parse/op, so the "live runtime cost" leg is real but small (per-operation, not per-row; this is the weakest leg). Net: an entire module of dead machinery (global RwLock, Sink trait, dead field) instrumenting the CSV/session paths for a consumer that cannot exist, with module docs falsely claiming the FFI forwarding mechanism is implemented in mdvcore-ffi — on exactly the SwiftUI↔Rust FFI path the owner calls the key path. That is moderate design/documentation debt, not a nit and not a functional bug; S3 is correctly calibrated. The fix sketch (wire an `mdvcore_trace_set_sink` C-callback export, or demote the facade to a no-op/feature-gated stub and fix the docs) is apt.

### [S3] core::theme's cross-front-end palette contract is honored only by the TUI — web hardcodes its own ~30-color palette, partially duplicating the One Dark/Light values
- **Where:** `rust-core/crates/web/src/main.rs:1679`
- **Why:** Half-adopted shared abstraction: the duplicated values can drift (edit theme.rs, TUI changes, web doesn't), and theme.rs's headline claim is false for one of the two front-ends it names. Either the module is the contract or it's TUI-private — currently it's neither.
- **Fix:** Generate the web CSS custom properties from `theme::Palette` (e.g. a `:root { --accent: #...; }` block built via `Palette::color(role)` + a tiny rgb→hex fn) for the roles theme owns; keep genuinely-web-only colors local. Or narrow theme.rs's doc to match reality.
- **Verifier:** Verified against the code. (1) theme.rs:3-5 explicitly names "CSS for the web front-end" as a palette consumer and invokes the one-core/three-front-ends contract. (2) grep over crates/web/src returns zero references to `theme`; the use-block at web/main.rs:29-38 imports nine mdvcore_core modules but not theme. Only the TUI consumes Palette (tui/main.rs:48,700-703,3381+). (3) The cited byte-duplicates check out in page()'s CSS: light .tok-at #0184bc / .tok-fn #4078f2 (= Light Accent/Header, theme.rs:100-101) and dark .tok-at #56b6c2 / .tok-fn #61afef (= Dark Accent/Header, theme.rs:88-89), plus #e5c07b (= Dark HighlightBg) and #fafafa (= Light OnHighlight). Minor nuance: those byte-equal literals are syntax-token colors, not the same semantic Roles, so they coincide via the shared One Dark/Light upstream rather than direct role duplication — but the finding is actually stronger than cited: theme owns Added/Removed/Hunk/Context/HighlightBg roles and web reimplements exactly those with DIFFERENT values (.diff-add #0a7d28 vs theme Light Added #50a14f; hit bg #fff3b0 vs #c18401), so TUI and web already render diff/search colors inconsistently today. Severity S3 is fair: not a runtime bug, but a shared-contract module whose headline claim is false for one of two named front-ends, plus live cross-front-end visual divergence and a real drift channel, in a project whose stated goal is the reusable multi-front-end core. Fix sketch (emit :root CSS custom properties from Palette::color, or narrow the doc) is correct and dependency-free.

### [S3] Pub API surface with zero external consumers (incl. wire::WireError — the documented rich-error channel that is never sent)
- **Where:** `rust-core/crates/core/src/wire.rs:62`
- **Why:** 13 pub items with no consumer is API surface that must be documented (missing_docs is on), semver-respected, and mentally carried — for nothing. The WireError case is worse than dead code: two crates' contract docs describe an error channel that doesn't exist, which a Swift-side implementer would build against.
- **Fix:** Demote internal-only helpers to `pub(crate)`/private (hex row math, diff::hunk_marks, csv::detect_delimiter). For deliberate future-API (parse_with, from_table, parse_hex) either keep with a `// future-API` note or cut until needed. For WireError: implement it (encode a WireError frame into out_buf on error paths) or delete the type and fix the lib.rs/status.rs docs.
- **Verifier:** VERIFIED — the finding survives on every cited point.

1. WireError (the load-bearing part): `rust-core/crates/core/src/wire.rs:62` defines `pub struct WireError`; a repo-wide grep shows the ONLY construction is wire.rs:264, inside wire.rs's own byte-parity test. Every other "WireError" hit in the workspace is the unrelated C-status enum variant `MdvStatus::WireError` (status.rs:28) or doc references to it. Meanwhile the contract docs explicitly promise this channel: `rust-core/crates/ffi/src/lib.rs:10-11` ("Rich error detail (message + context) rides in the MessagePack wire body, not the C signature") and `rust-core/crates/ffi/src/status.rs:7-8` ("The codes also match the WireError.code carried in the MessagePack body, so the C status and the rich wire error agree"). I read the FFI error paths (e.g. `mdvcore_cm_apply` lib.rs:146, `mdvcore_diff_parse` lib.rs:192): on error they leave `out_buf = MdvBuf::empty()` and discard the `Err(_)` entirely — no WireError frame is ever encoded into any body, on any of the 16 entry points. The documented rich-error channel genuinely does not exist; a Swift implementer reading lib.rs/status.rs would build a body-decoding error path against nothing.

2. The other cited symbols: grep across all crates (core, ffi, highlight, tui, web) confirms each has zero consumers outside its own module/tests: `csv::detect_delimiter` (csv.rs:57, only internal call at csv.rs:119), `csv::parse_with` (csv.rs:128, internal + own tests), `diff::hunk_marks` (diff.rs:460, called only by its sibling `hunk_marks_wire` at diff.rs:549 — the FFI shim calls the wire wrapper, not it), `hex::hex_search_find`/`rendered_row_length`/`row_count` (hex.rs:171/25/33, internal + tests), `session::from_table` (session.rs:74, ZERO callers anywhere incl. tests), `theme::parse_hex` (theme.rs:116, own tests only — the hex.rs:280 `parse_hex_forms` test exercises a different hex-module function), `view::looks_tabular` (view.rs:246, tests only), `trace::set_sink`/`clear_sink` (trace.rs:92/99, own tests only). The TUI and web monoliths consume none of them.

Minor inaccuracy: the list enumerates 12 items, not 13 — immaterial to the finding.

Severity: S3 stands. The unused-pub-surface portion alone would be S4 hygiene, but the WireError piece is a cross-crate contract-doc defect on the key SwiftUI↔Rust FFI path (the owner's stated critical seam): two crates document an error channel the Swift side would be built against that no entry point implements. That combination justifies moderate, not nit. Fix sketch (demote to pub(crate)/private; implement-or-delete WireError and correct lib.rs/status.rs docs) is apt.

### [S3] 60 standing clippy warnings on mdvcore-core saturate the warn tier — 18 are false-positive case-sensitive-extension hits on already-lowercased strings
- **Where:** `rust-core/crates/core/src/image.rs:77`
- **Why:** The gate's design (deny = fail, pedantic warn = signal) only works if warn output is near-zero; at 60 permanent warnings a NEW real pedantic warning is invisible. The workspace even warns on `allow` without reason (Cargo.toml lints) — the discipline exists, it just hasn't been applied to the standing set.
- **Fix:** One pass: restructure extension checks to the clippy-suggested `Path::extension().is_some_and(|e| e.eq_ignore_ascii_case(...))` (also drops the manual lowercase alloc), backtick the 10 doc idents (or extend clippy.toml doc-valid-idents), add `#[must_use]`s, and `#[allow(clippy::match_same_arms, reason = "CurrentBg deliberately aliases Hunk")]` on theme. Target: zero standing warnings, so warn output regains meaning.
- **Verifier:** Verified against the live tree; the finding holds on every load-bearing claim.

1. Warning count: `cargo clippy -p mdvcore-core --lib` (and the --workspace --all-targets run) prints exactly "`mdvcore-core` (lib) generated 60 warnings" — matches the claim verbatim.

2. The 18 case_sensitive_file_extension_comparisons bucket: confirmed exactly 18 hits, at `rust-core/crates/core/src/image.rs:77/79/79/81/83/85`, `rust-core/crates/core/src/outline.rs:38/40/41`, and `rust-core/crates/core/src/view.rs:223-231` (9 hits). All three sites do `let lower = name.to_ascii_lowercase();` before the `ends_with` chains (image.rs:76, outline.rs:37, view.rs:222), so they are behaviorally case-insensitive and the lint hits are pure noise that will never self-resolve — exactly as the finding says.

3. Other buckets: 6× must_use (4 method + 2 function) confirmed; 2× match_same_arms confirmed, and theme.rs Dark mode indeed maps both Role::CurrentBg and Role::Hunk to Rgb::new(0xc6,0x78,0xdd) — the deliberate-alias explanation is accurate. Minor inaccuracy: doc-backtick warnings are 9, not 10 (the finding labeled it doc_markdown; clippy reports "item in documentation is missing backticks"), and the bucket list omits ~11 cast warnings + misc — but the finding said "largest buckets," and the off-by-one doesn't change the substance.

4. The "why it matters" framing is correct: `scripts/rust-core-gate.sh:34` runs bare `cargo clippy --all-targets` with NO `-D warnings` — only deny-level lints fail it — so all 60 warnings pass the gate as a printed wall on every run, and a new warn-tier signal (e.g. a fresh i64→usize cast-truncation warning, several of which already sit in the pile) would be invisible. The gate's own header comment documents that clippy discipline is load-bearing here (panic-capable code shipped when clippy wasn't run).

Severity S3 is calibrated correctly: not a runtime bug (so not S2), but materially more than a nit — it systematically blinds the warn tier of the project's only Rust lint gate, in a codebase whose stated bar is production-grade and whose history shows lint-signal lapses shipping real defects. The fix sketch is sound (the clippy-suggested `Path::extension().eq_ignore_ascii_case` restructure, doc backticks or clippy.toml doc-valid-idents, #[must_use], reasoned allow on theme.rs).

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