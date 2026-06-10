# explorer-a — rust-core audit 2026-06-09 (final, post-resume)

## Adversarially confirmed findings

### [S2] FFI CSV path has a hard 16 MiB wire ceiling that the parser limits massively exceed — session_table/snapshot structurally fail on mid-size CSVs
- **Where:** `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/core/src/wire.rs:73`
- **Why:** The flagship FFI feature (CSV open → table/snapshot pull) silently stops working for any file whose encoded table exceeds ~16 MiB — roughly any CSV over ~10-15 MB. Open succeeds, every pull fails, and the host sees only a generic WireError, so the Swift app can neither display the data nor explain why. For a production core this is a designed-in functional ceiling, not an edge case.
- **Fix:** Decouple the decode-side hostile-length guard from the encode path (the encoder's own output length is trusted). Add a windowed pull API (`mdvcore_session_snapshot_range(handle, first_row, max_rows, out_buf)`) so frames are bounded by construction, and/or add a distinct MdvStatus::TooLarge so the host can fall back. Align csv::Limits with whatever transport bound is chosen.
- **Verifier:** Every factual claim in the finding checks out against the code.

1. The 16 MiB cap IS enforced on encode: /Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/core/src/wire.rs:73 (`MAX_FRAME_LEN = 16 * 1024 * 1024`) and wire.rs:163-167 (`encode_frame` returns `WireFault::Framing` when `body_len > MAX_FRAME_LEN`). Notably the const's own doc comment (wire.rs:71-72) justifies it solely as a DECODE-side guard ("Guards the decoder against a hostile / corrupt length prefix"), yet it is applied to the encoder's own trusted output — confirming the design mismatch the finding alleges.

2. Parser limits massively exceed the transport cap: /Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/core/src/csv.rs:41-51 (`max_total_cells = 32_000_000`, `max_input_scalars = 256 MiB`), and `CsvSession::open` (session.rs:52-69) calls `csv::parse` which uses `Limits::default()` (csv.rs:118-120). So `mdvcore_session_open` (ffi/lib.rs:427-462) accepts and fully parses a 50 MB CSV with status Ok.

3. Every pull then fails: `mdvcore_session_table` (ffi/lib.rs:472-500) calls `wire::encode_frame(session.table())` and maps any Err to `MdvStatus::WireError` (line 495); `mdvcore_session_snapshot` (ffi/lib.rs:560-592) calls `session.snapshot_frame()` (session.rs:162-184, which ends in `wire::encode_frame`) and likewise maps Err to `MdvStatus::WireError`. MessagePack named-map encoding of a Table is roughly input-sized (per-cell/row headers vs removed delimiters), so a CSV in the mid-teens of MB exceeds the cap; the snapshot frame is strictly larger (it additionally carries `indices`, ~5 bytes/row). The "~10-15 MB" estimate is fair.

4. No escape hatch exists: the full export list (grep of `no_mangle` in ffi/lib.rs) is add/force_panic/cm_apply/diff_parse/diff_hunk_marks/hex_render/hex_search/indent_detect/session_open/session_table/session_set_filter/session_snapshot/session_free/buf_free — no windowed/range pull. And `MdvStatus` (ffi/src/status.rs:16-35) has only `WireError = 4` for the whole wire class — no TooLarge — and on the encode-failure path the out_buf is left empty (ffi/lib.rs:482, 569), so no rich `WireError{code,message}` body reaches the host either. The host genuinely cannot distinguish "table too big" from "corrupt frame".

Severity: S2 is correctly calibrated. Not S1 (no UB, no exploitability, no data loss — the failure is clean and the handle stays valid). But it is more than moderate: it is a designed-in, deterministic functional ceiling on the flagship FFI feature (CSV open→pull is the Stage 1/2 surface the owner's production core is built around), with internally inconsistent limits (parser admits 256 MiB, transport refuses >16 MiB), a misleading success on open, no fallback API, and an undiagnosable generic error. One mitigating note: this is currently a PoC A/B path (csv.rs header says the Swift CSVParser still exists), so no shipping user is hit today — but the audit's explicit brief is the production-grade target, where this is a structural defect. The fix sketch (decouple decode-side guard from encode, add a ranged pull, add a distinct status) is sound. is_real=true, severity stands at S2.

### [S2] TUI and web front-ends run `git status` against arbitrary browsed directories without neutralizing repo-local config (core.fsmonitor ⇒ command execution)
- **Where:** `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/web/src/main.rs:822`
- **Why:** A document viewer is routinely pointed at downloaded/untrusted directories. Browsing into a cloned malicious repo with the TUI or web tier executes attacker-chosen commands as the user — no click on any file required, the directory listing alone triggers it. Also a per-request process spawn on every web page render (perf).
- **Fix:** Spawn with repo config neutralized: `git -c core.fsmonitor= -c core.hooksPath= --no-optional-locks status …` (and consider `GIT_CONFIG_COUNT`-style env pinning or `safe.directory` semantics). Cache the result per directory for the web tier instead of re-spawning per request.
- **Verifier:** Verified against the actual code. Both spawns exist exactly as cited: web/main.rs:822-826 git_status_html and tui/main.rs:2955-2960 git_status_for both run `git -C <dir> --no-optional-locks status --porcelain=v1 --branch` with output captured. git_status_html is called from nav_html (web/main.rs:873), which renders on /browse, /view AND /grep (callers at lines 490, 607, 686), so it fires on every directory-listing render against the browsed dir. A grep for GIT_CONFIG*, core.fsmonitor, safe.directory, env_clear, .env( across both files returned nothing — there is NO config/env neutralization. The fsmonitor vector is real: a repo-local .git/config setting core.fsmonitor=<command> is treated by git as the fsmonitor hook program and executed via run_command during the index refresh that `git status` performs; --no-optional-locks does not disable fsmonitor, and safe.directory (ownership-based) does not help when the tree is user-owned (downloaded/extracted). The fix sketch (`-c core.fsmonitor=` overrides repo config; per-dir caching) is correct. The only imprecision is the word 'cloning' — git clone writes a fresh config and would not import the attacker's core.fsmonitor; the realistic trigger is a downloaded/extracted directory that already contains a hostile .git, which is exactly the untrusted-directory threat model stated. This does not undermine the finding. Severity S2 is justified: RCE-class execution from untrusted data with no file-open click required, but confined to the two out-of-default-members PoC front-ends (merge gate covers core+ffi only; production is the SwiftUI FFI path) and gated on the user running that tier plus an attacker planting a .git — serious but not critical, so S2 stands.

### [S3] tui, web and highlight crates (~8,300 lines) have zero CI: the gate and PR workflow build/test default-members (core+ffi) only
- **Where:** `/Users/me/Documents/workspaces/claude/markdown_viewer/scripts/rust-core-gate.sh:34`
- **Why:** Two shipping front-ends and the highlighting engine can silently rot: a core API change that breaks tui/web compiles green through CI, and their substantial test suites (which exist and pass locally) never gate a merge. The gate script comment even claims coverage it doesn't provide.
- **Fix:** Add a second (can be non-blocking at first) gate step: `cargo clippy --workspace --all-targets` + `cargo test --workspace`. Keep the macOS app build scoped to default-members; CI checking is cheap relative to the rot risk. Fix the ':16' comment either way.
- **Verifier:** Verified against the actual code; every factual claim holds. (1) /Users/me/Documents/workspaces/claude/markdown_viewer/scripts/rust-core-gate.sh:34 runs `cargo clippy --manifest-path "$RUST_DIR/Cargo.toml" --all-targets` and :37 runs `cargo test --manifest-path ...` with no `--workspace`/`-p` flags; invoked at the workspace root, cargo scopes both to `default-members = ["crates/core", "crates/ffi"]` (/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/Cargo.toml:23 — finding cited :25, off by two, immaterial). (2) .github/workflows/pr.yml:90-98 runs only build-rust-core.sh + rust-core-gate.sh; nightly-vm.yml contains zero cargo invocations, and a grep of scripts/ + .github/ finds NO reference to mdvcore-tui, mdvcore-web, mdvcore-highlight, `--workspace`, or `-p mdvcore` — so no CI lane ever compiles, clippys, or tests those three crates. (3) highlight is not a dependency of core or ffi (crates/ffi/Cargo.toml deps: mdvcore-core + serde + rmp-serde only), so it isn't even compiled transitively by the gate. (4) The ungated surface is real and substantial: tui/src/main.rs 4,666 lines / 60 #[test] fns; web/src/main.rs 3,079 lines / 75 tests; highlight/src/lib.rs 522 lines / 9 tests — 144 tests across ~8.3k lines that never gate a merge, so a core API change breaking tui/web compiles green through CI. (5) The gate comment at rust-core-gate.sh:16 ("cargo test runs every workspace crate's tests (core + ffi)") is indeed inaccurate wording — the workspace has 5 members. Partial mitigation considered and rejected as a refutation: the exclusion is DELIBERATE and documented (rust-core/Cargo.toml:17-23 explains keeping the ratatui dep tree out of the merge gate and the macOS app build). That justifies excluding tui/web from the app-build path, but nothing covers them anywhere — the rot risk the finding describes is real, and the owner's stated goal is a production-grade reusable core with TUI/web as shipping front-ends. Severity S3 is correctly calibrated: it's a CI-coverage/process gap (no current code defect, no exploitability/data loss), but with 8.3k LoC and two shipping front-ends ungated it is more than an S4 nit. Fix sketch (a separate `cargo clippy --workspace --all-targets` + `cargo test --workspace` step, keeping the app build scoped to default-members, plus fixing the :16 comment) is sound; the only cost is the tree-sitter C-grammar compile time, which the existing cargo-target cache in pr.yml would absorb.

### [S3] Web server leaks an in-flight connection slot on worker panic; 128 leaked slots = permanent 503 (and release profile panic=abort kills the whole server on any panic)
- **Where:** `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/web/src/main.rs:186`
- **Why:** A single recurring panic-triggering input degrades the server irreversibly (each retry burns a slot) until it refuses all requests — the failure is silent and cumulative, exactly the kind of thing 'rock solid' excludes.
- **Fix:** Wrap the decrement in a Drop guard (`struct Slot(Arc<AtomicUsize>); impl Drop …`) created before handle_conn runs, or `catch_unwind` the handler body. Decide an explicit panic profile for the bins (panic=unwind + guard, or supervisor restart).
- **Verifier:** Every factual claim checks out at the cited locations.

1. Leak mechanism confirmed — /Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/web/src/main.rs:186-189: `thread::spawn(move || { let _ = handle_conn(stream, &root, &recents); inflight.fetch_sub(1, Ordering::AcqRel); })`. The decrement is straight-line code after the call, not a Drop guard, and there is no catch_unwind anywhere in web/main.rs (grep confirms zero occurrences). A panic unwinding out of handle_conn skips the fetch_sub permanently; the JoinHandle is dropped (detached thread) so nothing observes the panic.

2. Cap + 503 confirmed — MAX_INFLIGHT = 128 at main.rs:61; main.rs:178-181 answers 503 (`refuse_overloaded`) and drops the socket once `fetch_add` returns >= cap. Leaked slots are never reclaimed, so 128 cumulative panics = permanent 503 for the process lifetime.

3. Panic reachability is plausible, and the codebase itself concedes it — crates/web/Cargo.toml:24-25 explicitly opts OUT of the workspace no-panic/no-indexing deny lints ("deliberately NOT lints.workspace = true"). The request path calls `mdvcore_highlight::highlight_lines` at main.rs:1066, which does raw `spans[si]`/`src[cursor..s]` indexing+slicing at highlight/lib.rs:341-363 exactly as cited. Tellingly, main.rs:420-421 documents the recents Mutex as guarded "so a panicked sibling worker can't wedge the list" — the author anticipated worker panics and hardened the Mutex, but not the inflight counter. The panic premise is accepted by the code's own comments.

4. panic=abort claim confirmed — rust-core/Cargo.toml:85-90 `[profile.release] panic = "abort"`, and profiles are root-only (Cargo.toml:11-12), so a `cargo build --release -p mdvcore-web` binary aborts the whole server on first panic. (The `panic = "unwind"` `dist` profile at Cargo.toml:98-101 exists but is for the shipping macOS dylib, not the web bin's default release build.) The finding presents both regimes correctly: unwind (dev/default) = cumulative slot leak; abort (release) = instant process death.

Severity: S3 is correctly calibrated. Mitigating: localhost-only (127.0.0.1 bind, main.rs:165), single-user tool, out of default-members and the merge gate, fully recoverable by restart, and exploitation requires an input that actually panics the handler (none demonstrated, only made plausible). Aggravating: the degradation is silent and cumulative under unwind, and the stated project bar is "rock solid" production-grade. Not S2 (no data loss, no UB, no remote exposure), clearly more than an S4 nit (a real availability defect with a concrete failure mechanism). The Drop-guard fix sketch is the right shape.

### [S3] tree-sitter HighlightConfiguration (query compile) rebuilt from scratch on every highlight() call — per-HTTP-request in the web tier
- **Where:** `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/highlight/src/lib.rs:270`
- **Why:** Every page load of a source file pays grammar-query compile + full-file parse + full-file re-render. For a 'hyper efficient' production core this is the single hottest avoidable cost in the web tier, and it compounds with the per-request `git status` spawn on the same page.
- **Fix:** Cache `HighlightConfiguration` per `Lang` in a `OnceLock`/`LazyLock` array (it's Sync once configured) so query compile happens once per process; optionally add a small (path, mtime) → segments LRU in the web tier.
- **Verifier:** All cited evidence verified against the code. (1) highlight/src/lib.rs:268-274: every highlight() call invokes lang.grammar() — which allocates an owned query String, including format! concatenations for TS/TSX/C++ — and HighlightConfiguration::new(), i.e. full tree-sitter query compilation per call; no OnceLock/LazyLock/static cache exists anywhere in the crate. (2) web/src/main.rs:1063-1066: the /view render path calls mdvcore_highlight::highlight_lines(&lines.join("\n"), lang) per HTTP request with no cross-request cache; PREVIEW_CAP = 1 MiB (main.rs:43) confirms input size. (3) The doc comment at lib.rs:110-111 claiming "front-ends cache the highlight result" is only true for the TUI (hl_cache at tui/main.rs:166, populated at 182-188) — the web tier has no cache, so the comment's premise is false for it. (4) The compounding per-request git spawn also holds: /view renders nav_html (main.rs:686) → git_status_html (main.rs:873) → Command::new("git") (main.rs:822-826). (5) The fix sketch is viable: Highlighter::highlight takes &HighlightConfiguration, Query/Language are Sync, so a per-Lang OnceLock array works (configure() runs once before publication). Severity S3 is correctly calibrated: real avoidable hot-path cost under the owner's "hyper efficient" mandate, but a localhost single-user tool with no security/data-loss angle, and the inherent full-file parse likely dominates the query-compile share — not S2, more than an S4 nit.

### [S4] Declared rust-version 1.85 understates the real MSRV — core uses let-chains (stabilized in Rust 1.88)
- **Where:** `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/core/src/trace.rs:109`
- **Why:** The whole point of rust-version is a clean 'your toolchain is too old' diagnostic. With the field wrong, a 1.85–1.87 toolchain passes cargo's MSRV check and then dies on an inscrutable E0658 parse error inside the crate. Any future MSRV-checking CI lane would also be testing the wrong floor.
- **Fix:** Bump `rust-version` to "1.88" (audit for any later-stabilized APIs first), or rewrite the one let-chain. Consider a `cargo +1.88 check` CI step to keep the claim honest.
- **Verifier:** Confirmed: rust-core/crates/core/src/trace.rs:109-110 uses a let-chain (`if let Ok(guard) = SINK.read() && let Some(sink) = guard.as_ref()`), which stabilized only in Rust 1.88 (edition 2024), while rust-core/Cargo.toml [workspace.package] declares rust-version = "1.85" with edition = "2024". A 1.85–1.87 toolchain would pass cargo's MSRV check and then fail with E0658 inside the crate, exactly as the finding claims. However, severity is overstated: the workspace is publish = false, there is no rust-toolchain pin or MSRV CI lane, the real toolchain in use is 1.92, and the only consequence is a worse diagnostic for a hypothetical old-toolchain builder. One-line manifest fix (bump to "1.88") or rewrite the single let-chain. Real, but a metadata-hygiene nit, not a moderate issue.

### [S3] cargo-deny / cargo-audit / Miri are configured or referenced but wired into no gate — supply-chain and UB checks are dead letters
- **Where:** `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/deny.toml:1`
- **Why:** For a production commitment, the security posture currently exists only as comments: yanked-crate/advisory/license/duplicate-sys-crate checks never run, and the unsafe FFI surface has no UB checker in the loop despite the tests being written for it.
- **Fix:** Add to the gate (or a nightly lane): `cargo deny check`, `cargo audit`, and `cargo +nightly miri test -p mdvcore-ffi`. All three are one-line additions once the tools are installed.
- **Verifier:** Every factual claim in the finding holds up. (1) /Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/deny.toml:1-6 contains the quoted header verbatim — cargo-deny config committed but the tool was 'NOT installed on this host at PoC time'. (2) scripts/rust-core-gate.sh contains zero invocations of cargo deny/audit/miri (the only grep hit for 'deny' is the clippy no-panic lint comment at line 33). (3) .github/workflows/pr.yml runs build-rust-core.sh + rust-core-gate.sh (lines 91, 98) and nothing else for Rust; a repo-wide sweep across all *.sh/*.yml/Makefile/*.toml finds the ONLY mention of these tools is deny.toml itself — no hook, nightly lane, or script runs them. (4) The Miri comment exists at rust-core/crates/ffi/src/tests.rs:208 ('a leak/double-free would surface under Miri /…') — the finding cited 'ffi/tests.rs:208-209', a trivially imprecise path (src/ omitted) but the right file and line. (5) rust-core/crates/highlight/Cargo.toml:23-39 pins tree-sitter 0.25.10 + 12 exact-pinned C-grammar crates (tree-sitter-json/rust/javascript/typescript/java/c/cpp/c-sharp/swift/kotlin-ng/lua + tree-sitter-highlight) that never receive an advisory scan. So the supply-chain/UB checks genuinely exist only as comments and committed config — dead letters as claimed. Severity S3 is correctly calibrated: this is a process/tooling gap with mitigations in place (exact pins, lockfile, registry-only sources implied, the unsafe surface is small and has handle-lifecycle tests), not an exploitable bug — so not S2; but for a stated production-grade/security commitment it is more than a nit, so not S4. The fix sketch is accurate: all three are one-line gate additions once the tools are installed (cargo-audit v0.22.1 is even noted as already present per the deny.toml header, making that one immediately wireable).

### [S3] 2.7 GB rust-core/target sits inside the iCloud-synced worktree, violating the workspace's own build-dir mandate
- **Where:** `/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/Cargo.toml:8`
- **Why:** Someone ran cargo without CARGO_TARGET_DIR and the guard is purely advisory. 2.7 GB of churning build artifacts under iCloud causes sync thrash, xattr re-stamping (the same class of problem that already breaks codesign in this repo), and disk bloat — and it will keep recurring.
- **Fix:** Delete the dir, then make the mandate self-enforcing: a `.cargo/config.toml` in rust-core setting `build.target-dir = "/private/tmp/…"` (or at minimum a gate check that fails when rust-core/target exists).
- **Verifier:** Every evidentiary claim verified against the live tree. (1) rust-core/Cargo.toml:8-9 contains the verbatim mandate that build dirs MUST live outside the worktree via CARGO_TARGET_DIR. (2) rust-core/target is 2.8 GB on disk inside the iCloud-synced worktree (finding said 2.7 GB; dir has grown). (3) rust-core/.gitignore:13 has the /target/ backstop, so git is clean — but iCloud Drive syncs regardless of .gitignore. (4) No .cargo/config.toml exists in rust-core/ or the repo root, so the mandate is purely advisory; only scripts/rust-core-gate.sh:26 and scripts/build-rust-core.sh:53 export CARGO_TARGET_DIR, and bare cargo runs bypass them — files inside target (release/mdv-web, .rustc_info.json) were written within the last ~5 days, proving the violation is recurring, not a stale one-off. (5) The target dir's com_apple_backup_excludeItem xattr (set by cargo) excludes Time Machine only, not iCloud Drive, so the sync-thrash concern stands; the project's own CLAUDE.md documents real iCloud xattr-restamping breakage (codesign) in this repo. Severity: S3 is correctly calibrated — operational hygiene, no correctness/security impact (so not S2), but a recurring 2.8 GB violation of an explicit owner directive with documented iCloud failure history in this repo (so above S4). Fix sketch is valid: a .cargo/config.toml build.target-dir default (env var still overrides, so existing scripts unaffected) or a gate check on rust-core/target existence makes it self-enforcing.

## S4 nits (unverified by design)

- MdvBuf documents `data == null when len == 0` but from_vec of an empty Vec yields a dangling non-null pointer (`/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/ffi/src/buf.rs`)
- hex::rendered_row_length(0) underflows (debug panic) despite the core's no-panic posture (`/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/core/src/hex.rs`)
- SessionHandle::with recovers a poisoned lock and keeps using possibly half-mutated state, contradicting the documented 'drop & recreate after Panic' contract (`/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/ffi/src/handle.rs`)
- TOCTOU between confined() canonicalization and the later file open in the web tier (`/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/web/src/main.rs`)
- short() strips the $HOME prefix without a path-separator boundary check (`/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/web/src/main.rs`)
- Web responses omit defensive headers (X-Content-Type-Options, CSP) on a page that inlines untrusted file content (`/Users/me/Documents/workspaces/claude/markdown_viewer/rust-core/crates/web/src/main.rs`)

---

## Full reviewer report

# rust-core/ audit — 2026-06-09

Scope: full read of `rust-core/` (workspace manifest, `crates/core`, `crates/ffi`, `crates/highlight`, `crates/web`, `crates/tui` (targeted), `deny.toml`, gate scripts, CI wiring, on-disk state). ~17.5k lines of Rust.

## Overall verdict

This is an unusually disciplined PoC. The architecture is right for the production goal: a `#![forbid(unsafe_code)]` sans-IO core; one small FFI crate holding all unsafe with per-fn safety contracts, panic guards, opaque handles, and a documented threading model; exact-pinned minimal deps; deny-level no-panic lints actually enforced by a gate; deliberate byte-parity tests (legacy-oracle frame encoding, ASCII-fast-path vs Unicode reference filter, Swift A/B contracts). Most of the classic FFI/web footguns (length-prefixed framing with decode caps, trailing-garbage rejection, `to_vec_named` map encoding, UTF-16 CodeMirror semantics with surrogate-validating decode, JSON recursion depth cap, bounds-checked image header parsing, HTML escaping + percent-encoding, Host-header anti-rebinding, header-size caps, socket timeouts, connection caps) are already handled — and tested.

The problems that remain are mostly **systemic / design-level**, not line-level bugs. Two are serious (S2).

## S2 — serious

### 1. The FFI CSV pipeline has a built-in ~16 MiB ceiling
- `wire.rs:73` `MAX_FRAME_LEN = 16 MiB` is enforced **on encode** (`wire.rs:163-167`), not just decode.
- `csv.rs:41-51` default `Limits` admit 32M cells / 256M input chars — files far beyond what one frame can carry.
- Net effect: `mdvcore_session_open` (ffi/lib.rs:427) succeeds on a 50 MB CSV, then **every** `mdvcore_session_table` / `mdvcore_session_snapshot` fails with the generic `MdvStatus::WireError` (ffi/lib.rs:495, :587). No status distinguishes "too large" from "corrupt".
- Fix: drop the encode-side cap (it guards against hostile *length prefixes*, which can't occur on encode), add a windowed snapshot API (`snapshot_range(first_row, max_rows)`) so frames are bounded by construction, and add a distinct status (`TooLarge`). Align `csv::Limits` with the chosen transport bound.

### 2. `git status` spawned against untrusted directories without neutralizing repo-local config
- web/main.rs:822-829 (runs in `nav_html`, i.e. **every** /browse, /view, /grep render) and tui/main.rs:2954-2965.
- `git status` honors the target repo's `.git/config`; `core.fsmonitor = <cmd>` makes git execute that command. Browsing into a downloaded hostile repo ⇒ code execution, no file open needed. This is the known fsmonitor attack class that made VS Code add repo-trust prompts.
- `--no-optional-locks` is present (good) but does not mitigate this.
- Fix: `git -c core.fsmonitor= -c core.hooksPath= --no-optional-locks status --porcelain=v1 --branch`, plus per-directory caching in the web tier (it's also a per-request process spawn today — perf).

## S3 — significant

### 3. ~8,300 lines (tui, web, highlight) have zero CI
- `rust-core-gate.sh:34,:37` runs clippy/test with no `--workspace`, so cargo scopes to `default-members = ["crates/core", "crates/ffi"]` (Cargo.toml:25). `pr.yml` runs only build + gate.
- The gate's own comment claims "cargo test runs every workspace crate's tests" — false.
- Both front-ends have *real* test suites (TestBackend pixel tests, HTTP route tests) that never gate anything. A core API change can break both front-ends invisibly.
- Fix: add `cargo clippy --workspace --all-targets` + `cargo test --workspace` as a gate step (or separate lane).

### 4. Web server slot-leak on panic → creeping permanent 503
- web/main.rs:186-189: `inflight.fetch_sub` runs *after* `handle_conn` rather than in a Drop guard. A panic (the web crate deliberately opts out of the no-panic lints; `mdvcore-highlight` does raw indexing/slicing at lib.rs:341-363) leaks the slot forever; at 128 leaks the server 503s everything (cap at main.rs:61, check at :178).
- Compounding: the workspace `[profile.release] panic = "abort"` applies to this bin — a release build dies on first panic.
- Fix: RAII slot guard; decide an explicit panic strategy for the bins.

### 5. tree-sitter query recompiled per call — per HTTP request
- highlight/lib.rs:268-274 builds `HighlightConfiguration::new` (query compile = the expensive part) on every `highlight()`; web calls it per /view request on up to 1 MiB (web/main.rs:1063-1067). The doc at lib.rs:110 ("front-ends cache… runs once per file") is true only for the TUI (`Preview.hl_cache`).
- Fix: `LazyLock` per-Lang config cache; optional (path, mtime) → segments LRU in web.

### 6. `rust-version = "1.85"` is wrong — actual MSRV ≥ 1.88
- trace.rs:109-110 uses a let-chain (`if let … && let …`), stable only since Rust 1.88 / edition 2024. A 1.85-1.87 toolchain passes cargo's MSRV gate then fails with E0658. Fix the field; add an MSRV check lane if the claim matters.

### 7. Supply-chain / UB tooling is configured but never runs
- `deny.toml` is committed with a header admitting cargo-deny isn't installed; no gate runs `cargo deny`, `cargo audit`, or Miri — while ffi/tests.rs:208 explicitly defers leak/double-free detection to "Miri / ASan", and highlight pulls 13 C-grammar crates that get no advisory scanning.
- Fix: nightly lane with `cargo deny check`, `cargo audit`, `cargo +nightly miri test -p mdvcore-ffi`.

### 8. 2.7 GB `rust-core/target/` inside the iCloud-synced worktree
- Directly contradicts the workspace's own mandate (Cargo.toml:8-10, "Build dirs MUST live outside the worktree"). Gitignored, but iCloud syncs it anyway (this repo already has documented iCloud-xattr pain).
- Fix: delete; make it self-enforcing via `rust-core/.cargo/config.toml` `build.target-dir`, not a comment.

## S4 — nits / hardening

9. **MdvBuf doc/impl mismatch** (buf.rs:15 vs :38-43): doc says `data` is null when `len == 0`, but `from_vec(empty)` exposes a dangling 0x1 pointer (reachable via `mdvcore_hex_render` on empty input). Free is safe (cap==0 guard) but C-side null checks misbranch. Emit null for empty, or fix the doc + header.
10. **`hex::rendered_row_length(0)` underflows** (hex.rs:27): debug panic in the "panic-free" core; only doc-guarded. Saturate or early-return; consider `clippy::arithmetic_side_effects` for core.
11. **Poison-recovery vs 'drop & recreate' contract** (handle.rs:104-109 vs status.rs:29-31): `with()` silently continues on a poisoned lock; nothing enforces the documented post-panic handle replacement. Add a tainted flag → status.
12. **TOCTOU** between `confined()` canonicalize (web/main.rs:480-483) and the later open (read_capped, :1743): symlink-swap race. Low impact locally; fix by open-then-verify.
13. **`short()` HOME-prefix strip without boundary check** (web/main.rs:1781-1790): `/Users/josette` renders as `~ette`.
14. **No nosniff/CSP headers** (web/main.rs:242-245): all XSS safety rests on every format! site escaping correctly; a one-line CSP/nosniff layer bounds future misses.

## Worth noting, not filed as findings

- **Escaping audit came up clean**: every interpolation of file names/contents/queries I traced goes through `esc()` or `pct_encode()` (which encodes `"`, `<`, `&`), including attribute contexts. The `find_box`/`goto_box` hidden inputs `esc(&pct_decode(href))` round-trip correctly.
- **`/grep` can read up to 2000 files × 1 MiB per request** (web/main.rs:529-531, 545-601) — bounded and capped, but a heavy synchronous unit of work per request; fine for localhost, revisit before any non-dev exposure.
- **Duplication between tui and web** (read_capped, mtime_secs, git spawn, esc/pct helpers exist twice): consider a `mdvcore-frontend-common` crate before the third copy appears.
- **`confined()` resolves relative `?path=` values against the process cwd**, not the served root — not an escape (the prefix check still applies) but surprising; consider rejecting relative paths outright.
- **`mdvcore_session_open` maps all open errors to `BadUtf8`** (ffi/lib.rs:459) — correct today (the only error), but the match will silently misreport when `OpenError` grows variants; add an exhaustive match.
- The FFI crate's design notes (panic=abort vs unwind split, `dist` profile for the shipping dylib, cbindgen header mirroring, exact lint rationale incl. cargo #13157) are genuinely production-grade documentation; keep that bar.

## Top recommendations, in order

1. Fix the frame-size ceiling design (S2 #1) before the Swift app grows more FFI surface on the same pattern.
2. Neutralize git config in both front-end spawns (S2 #2) — one-line change, real attack class.
3. Put the whole workspace under CI (S3 #3) and wire deny/audit/miri (S3 #7) — these turn the codebase's *claimed* guarantees into enforced ones.
4. RAII the web slot counter and pick an explicit bin panic policy (S3 #4).
5. Cache tree-sitter configs (S3 #5) and the git status per dir — the two per-request costs in the web tier.
