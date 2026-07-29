# Pre-launch Product Review — Tech Debt

**Dimension:** Tech debt — TODO/FIXME/HACK inventory (age + risk), dead code, deprecated API usage, orphaned features, stale scaffolding.
**Repo:** `/Users/me/Documents/workspaces/claude/markdown_viewer`
**Date:** 2026-07-10
**Reviewer lens:** static analysis only (no builds, no window-opening tests).

---

## Executive summary

This is an **unusually clean, mature codebase** for the tech-debt lens. The classic markers of rot are almost entirely absent:

- **3** `try!`, **4** `fatalError`, **1** `as!` in ~245K LOC of Swift source — and every one is a benign idiom (compile-constant regex literals; AppKit `init?(coder:)` boilerplate; a post-typecheck `AXValue` cast). No production crash-risk debt.
- **0** empty `catch {}` swallows, **0** stray `print(` debug statements, **0** `#if false` / commented-out dead blocks, **0** files named `*_old`/`*_legacy`/`*_v1`.
- Raw code-comment `// TODO/FIXME/HACK` markers in real (non-fixture, non-feature-string) code: **effectively one** (`StatusBar.swift:438`, a scoped `TODO(#228)` tied to a tracked ticket). The bulk of "111 BUG / 34 DEPRECATED" grep hits are **feature strings** — the app has a source-annotation scanner, a canvas design-token deprecation system, and golden test fixtures that contain those words as data, not debt.
- The Rust→Swift migration is managed with real discipline: retired gates (`diff`, `indent`, formula-evaluator) had their Swift twins **deleted**, not left to rot; the remainder route through a single fail-safe gate (`RustCoreGates` / `RustCoreFallback`).

So there is **no P0/P1 tech-debt finding**. The debt that exists is P2/P3 and falls into four buckets: (1) **orphaned/built-ahead scaffolding** (an entire unwired SQLite crate; a legacy bridge enum kept alive only for a test), (2) **test scaffolding compiled into the release binary** (the negative-control "deliberately break the UI" switches), (3) **god-object maintainability** (`DocumentModel` at 11.3K LOC / 76 files; `main.swift` at 4.4K), and (4) **known, tracked structural debt** (dormant Swift twins behind the Rust gate; ~60 MB of double-carried tree-sitter parse tables; deprecated-but-only-supported LaunchServices APIs).

**Note on methodology reliability:** the `Bash` tool's output rendering corrupted several exact tokens in-flight (e.g. `XCTSkip`→`ln`, `crates/pm`→`crates/n`). Every token-exact claim below was re-verified with the `Read` tool against the raw file, which renders cleanly.

---

## Methodology

**Examined:**
- Full marker sweep across `Sources/` (816 `.swift` files) and `rust-core/crates/` (85 `.rs` files) for `TODO|FIXME|HACK|XXX|BUG|KLUDGE|WORKAROUND|STOPGAP|DEPRECATED`, then filtered feature-strings/fixtures from real code comments.
- Crash-risk / error-hygiene patterns: `try!`, `fatalError`, `as!`, `preconditionFailure`, `assertionFailure`, empty `catch {}`, stray `print(`.
- Dead-code signals: `#if false/0`, commented blocks, legacy-named files, `#if os()` stub branches.
- The full Rust↔Swift migration seam: 13 `Rust*Adapter.swift` bridges, `RustCoreGates.swift` (per-capability defaults), `RustCoreFallback.swift`, and which adapters keep a live Swift-twin fallback vs are rust-only.
- Rust workspace layout (`rust-core/Cargo.toml`), per-crate consumers, and orphan status of each front-end crate (`tui`, `web`, `serve`, `highlight`, `pm`).
- Shipped test scaffolding: `MDVNegativeControl` and its call sites; `MDV_TEST_*` hooks.
- File-size hotspots (top 20 by LOC) for god-object/maintainability debt.
- Deprecated-API usage: LaunchServices, AppKit, Foundation.
- Vendored web-asset weight (`codemirror.js`, `mermaid.min.js`).
- Working-tree cruft via `git status`.

**Depth:** read the actual implementation at every cited site (not just grep counts). Did NOT compile, run tests, or execute anything that opens a window.

---

## Findings

### F1 — Fully-built `mdvcore-pm` SQLite crate has zero consumers (orphaned/built-ahead feature)
- **Severity:** P2
- **Location:** `rust-core/crates/pm/src/lib.rs` (1,478 LOC), `rust-core/Cargo.toml:16,23,67-73`
- **Evidence:** `mdvcore-pm` is a workspace member but **not** in `default-members` (`= ["crates/core", "crates/ffi", "crates/serve"]`). Grepping the whole tree for `mdvcore-pm` returns only: its own `Cargo.toml`, the workspace-root comment, and `Cargo.lock`. **No** other crate declares it as a dependency, **no** FFI symbol exports it, **no** Swift file references it, and it appears in **0** files under `scripts/` or `.github/`. It pulls in a new native dependency (`rusqlite = "=0.39.0"`, TSK-345) whose only justification comment (`Cargo.toml:67-72`) is "the project-management store." Last touched 2026-06-28.
- **Impact:** ~1,500 LOC + a pinned SQLite dependency surface compiled and maintained (it's a non-default member, so it isn't even in the merge gate — meaning regressions in it are caught only by an explicit `cargo test -p mdvcore-pm`) with **no wired consumer**. This is precisely the "built ≠ usable" / frugality tension in the project's own charter: a complete feature crate carried ahead of any product that consumes it.
- **Suggested fix:** Either (a) wire it (FFI export + a Swift bridge + a consumer surface) if the PM feature is on the launch roadmap, or (b) `git rm` the crate + drop the `rusqlite` dep and re-add when the consumer lands. A dormant SQLite store is not launch-blocking, but shipping it in the repo carries dep + maintenance cost for zero user value.
- **Fix size:** S (to remove) / L (to wire)
- **Fix risk:** safe (remove) / careful (wire)

### F2 — Negative-control "deliberately break the UI" switches are compiled into the release binary
- **Severity:** P2
- **Location:** `Sources/ViewerCore/MDVNegativeControl.swift` (whole file), consumers `Sources/ViewerUI/TextDisplayView.swift` (`~"RULER"`) and `Sources/ViewerUI/CanvasWebViewHost.swift` (`~"CANVAS_OVERLAY"`)
- **Evidence:** `MDVNegativeControl.isBroken(name)` returns true when env `MDV_ENABLE_BROKEN_<NAME>=1`. The call sites are **not** wrapped in `#if DEBUG` (verified: no `#if DEBUG` anywhere in `TextDisplayView.swift`, `CanvasWebViewHost.swift`, or `MDVNegativeControl.swift`). At `TextDisplayView.swift` the guarded branch deliberately attaches a broken ruler; the in-code comment literally reads **"(Don't ship a build with this set.)"** — acknowledging the smell while leaving the mechanism in the shipping build.
- **Impact:** Test-only scaffolding (a T5 pixel-teeth device, TSK-1134) ships in the production/release binary. Any process that can set the app's environment can force a visibly-broken render. Low real-world risk (single-user desktop app, env-gated, defaults off), but it is production code whose sole purpose is to break the app, and it is not compile-stripped from release.
- **Suggested fix:** Wrap the `isBroken` body (or each call site) in `#if DEBUG` so the switch is a no-op / absent in release builds. Keeps the teeth mechanism for the VM/nightly lane while guaranteeing it cannot exist in a shipped binary.
- **Fix size:** S
- **Fix risk:** safe

### F3 — `DocumentModel` god-object: 11.3K LOC across 76 partial files; `main.swift` at 4.4K LOC
- **Severity:** P2
- **Location:** `Sources/ViewerUI/DocumentModel.swift` (3,586 LOC) + 75 `DocumentModel+*.swift` extension files (11,305 LOC total); `Sources/MarkdownViewer/main.swift` (4,435 LOC)
- **Evidence:** `find Sources/ViewerUI -name 'DocumentModel*.swift'` → 76 files, `cat | wc -l` → 11,305. `main.swift` is the single largest source file in the repo at 4,435 lines.
- **Impact:** The central view-model is split into 76 files (good instinct) but still totals 11K LOC of one type's surface — any state added here touches an already-huge `@MainActor` observable, raising re-render/coupling risk and making the ownership of a given `@Published` property hard to reason about. `main.swift` concentrates menu/command wiring in one 4.4K-line shell. This is maintainability debt, not a bug, but it is the highest-leverage refactor target and worth flagging pre-launch as the thing most likely to slow future work.
- **Suggested fix:** No launch action. Post-launch, extract cohesive sub-models (e.g. a `FindState`, `SessionState`, `EditorState` owned object) out of `DocumentModel` and split `main.swift`'s menu wiring into per-menu builders. Track as a standing refactor epic.
- **Fix size:** XL
- **Fix risk:** careful (touches the central model; needs the full render/UAT lane)

### F4 — Dormant Swift twin engines retained as fallback-only + full Rust-migration dual-path scaffolding carried in-tree
- **Severity:** P2
- **Location:** `Sources/ViewerCore/RustCoreGates.swift` (all `defaultEnabled: true`), 13× `Sources/ViewerCore/Rust*Adapter.swift` + `RustCoreFallback.swift` (1,147 LOC combined); live Swift twins `FindEngine.swift` (213 LOC), plus the hex/hexSearch/highlight fallback arms; `Highlight/TreeSitterEngine.swift` (409 LOC)
- **Evidence:** Every capability in `RustCoreGates.defaultEnabled` now returns `true` (csv/hex/fuzzy/find/transcript/markdown/cmEdit/highlight/formula/fold), so the **default production path is Rust for all of them**. Of the 13 adapters, only `find`, `hex`, `hexSearch`, and `highlight` still carry a two-arm `swift: { … }` fallback; `find`'s arm calls the full `FindEngine` (213 LOC) and `highlight`'s degrades to `[]`. The rest are `runRustOnly` (twins already deleted in Stage B). So the Swift twins that remain are **executed only on a Rust-bridge fault** — dead-in-default code that must still be kept in sync (migration policy: "bugfix-only twins"). Stage-B deletion of the remaining twins is owner-gated (`docs/STAGE_B_DELETION_PLAN.md`, `docs/RUST_MIGRATION_PLAN_2026-06-04.md`).
- **Impact:** ~1.1K LOC of gate/adapter scaffolding + a few hundred LOC of dormant twins carried for a migration that is functionally complete (everything defaults Rust). This is *deliberate* fail-safe insurance, not accidental rot — but it is real carried surface and a divergence risk (a bug fixed in Rust must be mirrored, or the fallback silently behaves differently). The `find` fallback in particular means two engines with **documented behavioral differences** (the Rust PikeVM bypasses the `RegexComplexityGuard` ReDoS rejection and has no wall-clock truncation — `RustFindAdapter.swift:18-22`) can both be reached depending on a fault.
- **Suggested fix:** Once the owner signs off Stage B, delete the remaining fallback twins (`FindEngine`, the hex Swift arms) and collapse the two-arm adapters to `runRustOnly`, matching the already-completed diff/indent/formula precedent. Until then, keep the gate — but treat this as tracked, closeable debt rather than permanent structure.
- **Fix size:** M
- **Fix risk:** careful (removing a fail-safe fallback; needs A/B parity + VM validation, which the plan documents)

### F5 — Main executable carries ~60 MB of double-carried tree-sitter grammar parse tables (bundle bloat)
- **Severity:** P2
- **Location:** `rust-core/crates/highlight/Cargo.toml` (33 tree-sitter grammar references), exec sub-cap machinery in `scripts/check-bundle-size.sh`; tracked as TSK-1214 / TSK-1098
- **Evidence:** Per `CLAUDE.md` (project instructions) the release exec is ~60 MB, "most of the ~60 MB exec is double-carried tree-sitter grammar parse tables," and the exec sub-cap was bumped 26→44→52→60→65 MB to accommodate organic growth. The `highlight` crate statically links ~33 grammar crates. The real reclaim (lazy-load / dedup) is explicitly owner-gated and tracked (TSK-1214/1098).
- **Impact:** A 65 MB main-executable cap (80 MB bundle cap) for a document viewer is heavy; the grammars are the dominant contributor and are double-carried. Not launch-blocking (it ships and runs), but it inflates download/disk footprint and every cap bump defers the reclaim. Flagged here because "bundle bloat from double-carried static tables" is textbook debt even though it's already ticketed.
- **Suggested fix:** Pursue the tracked lazy-load / dedup of grammar parse tables (load grammars as `Contents/Frameworks/` dylibs on demand rather than static-linking all into the exec). Owner call on target budget.
- **Fix size:** L
- **Fix risk:** careful (touches the highlight link model + bundle layout; guarded by the exec sub-cap test)

### F6 — Reliance on deprecated LaunchServices default-handler APIs (forward-compat risk, but currently the only supported path)
- **Severity:** P3
- **Location:** `Sources/ViewerCore/DefaultAppRegistration.swift:150-176`
- **Evidence:** `LiveRoleHandlerService` calls `LSCopyDefaultRoleHandlerForContentType` / `LSSetDefaultRoleHandlerForContentType`, both **deprecated** by Apple. The file documents (150-157) that these "remain the ONLY supported way to read/set a default *viewer* (vs editor) handler" — `NSWorkspace.setDefaultApplication` (macOS 12+) is URL/role-based and doesn't expose the viewer-vs-editor distinction the app relies on, and there is no non-deprecated content-type variant. The deprecation is deliberately scoped to this thin wrapper.
- **Impact:** If Apple removes these symbols in a future macOS, the "set as default viewer for `<type>`" feature breaks with no drop-in replacement. This is well-managed debt (isolated, documented, no better API exists), so it's P3 — but it's a genuine deprecated-API dependency worth surfacing pre-launch so it's a known watch item, not a surprise.
- **Suggested fix:** No action now (no supported alternative). Add a runtime `@available`/OS-version guard or a graceful-degradation path if a future SDK marks the symbols unavailable; keep the wrapper isolated as it already is.
- **Fix size:** S
- **Fix risk:** safe

### F7 — `CodeMirrorBridge` legacy untyped enum retained only to keep a test green during a completed rollout
- **Severity:** P3
- **Location:** `Sources/ViewerUI/CodeMirrorEditorView.swift:1327-1345+`
- **Evidence:** A `// MARK: - Legacy bridge (kept for backwards-compatibility)` block introduces `enum CodeMirrorBridge`, documented as **"Deprecated — the original untyped bridge enum, retained so the existing `CodeMirrorBundleTests` pass during Phase 1 rollout. New code should use `CMBridgeCodec.decodeInbound` from ViewerCore."** The v1 codec (`CMBridgeCodec`) is the real path; this enum only adapts the v1 envelope back into three legacy cases for the old test.
- **Impact:** Dead-in-production adapter code kept alive solely for a test, tied to a "Phase 1 rollout" that (given the migration's completion elsewhere) is done. Small, but it's exactly "stale scaffolding" — a deprecated shim outliving its reason to exist.
- **Suggested fix:** Migrate `CodeMirrorBundleTests` onto `CMBridgeCodec.decodeInbound` and delete the legacy `CodeMirrorBridge` enum.
- **Fix size:** S
- **Fix risk:** safe

### F8 — Retired-gate ABI capability bits (`diff`, `indent`) intentionally kept after their gates were deleted
- **Severity:** P3
- **Location:** `Sources/ViewerCore/RustCoreGates.swift:24-33` (comments), the `CoreCapabilities` bitset in the FFI
- **Evidence:** `RustCoreGates` documents that `diff` and `indent` gates were retired (Stage B #1/#4 deleted their Swift twins → direct rust-only calls) but **"The ABI capability bit `CoreCapabilities.diff`/`.indent` stays"** because bits are ABI-stable.
- **Impact:** Vestigial capability bits with no gate behind them. This is *correct* (never renumber ABI bits), so it's a P3 note, not an actionable defect — but a reviewer scanning the capability set will find bits that no longer map to a toggle, which is mild cognitive debt.
- **Suggested fix:** None required. Optionally add a one-line `// reserved (gate retired)` marker next to the vestigial bits in the FFI header for clarity.
- **Fix size:** S
- **Fix risk:** safe

### F9 — Untracked working-tree cruft in the repo root
- **Severity:** P3
- **Location:** repo root — `Untitled.txt`, `OwnerWishlist.md.bak`, `archive/Untitled.txt`, `tmp/` (all untracked per `git status`)
- **Evidence:** `git status --porcelain` lists `?? Untitled.txt`, `?? OwnerWishlist.md.bak`, `?? archive/Untitled.txt`, `?? tmp/`. (Not modified per this review's constraints — reported only.)
- **Impact:** Housekeeping noise. Not shipped (untracked, and none are in the app bundle), so zero user impact, but `Untitled.txt` / `.bak` files in a launch repo are sloppy and risk being accidentally committed. `tmp/` should be `.gitignore`d if it isn't.
- **Suggested fix:** Delete the stray `Untitled.txt` / `.bak` files (owner to confirm — they may be intentional scratch), ensure `tmp/` and `*.bak` are `.gitignore`d.
- **Fix size:** S
- **Fix risk:** safe

### F10 — Large vendored minified web assets with unpinned/unclear upstream version currency
- **Severity:** P3
- **Location:** `Sources/ViewerUI/Resources/mermaid/mermaid.min.js` (~2.57 MB), `Sources/ViewerUI/Resources/codemirror/codemirror.js` (~1.11 MB)
- **Evidence:** Two vendored third-party bundles totaling ~3.7 MB ship in the app. They are the dominant Resources payload; there is no visible pinned-version manifest alongside them in the resource dir (version provenance lives in build docs, not next to the asset).
- **Impact:** Vendored minified blobs are a supply-chain + staleness surface: a security advisory in the pinned mermaid/CodeMirror version can't be tracked by a lockfile the way a package dep can. Not launch-blocking, but "vendored blob of unknown currency" is a debt/security watch item, and mermaid in particular has had XSS/DoS advisories historically.
- **Suggested fix:** Record the exact upstream version + integrity hash next to each vendored asset (a small `VERSION`/`.sha256` sidecar), and add a periodic upstream-advisory check to the dep-hygiene routine.
- **Fix size:** S
- **Fix risk:** safe

---

## Positive observations

- **Near-zero crash-risk debt.** 3 `try!` (all compile-constant regex literals), 4 `fatalError` (all `init?(coder:)` boilerplate), 1 `as!` (post-typecheck), 0 empty catches, 0 stray prints. This is genuinely production-grade error hygiene at ~245K LOC.
- **Migration is being *finished*, not accreted.** Retired gates (`diff`, `indent`, formula-evaluator) had their Swift twins **deleted** (`FormulaEngine.swift` is now just contract types + a bridge, with a clear "STAGE-B DELETED TWIN" banner) rather than left as parallel rot. The single-gate/single-fallback design (`RustCoreGates` + `RustCoreFallback`) is a clean seam.
- **Markers are disciplined.** The one real `TODO` in code (`StatusBar.swift:438`) is scoped and ticket-linked (`TODO(#228)`). The rest of the "marker" grep noise is feature data (annotation scanner, canvas token-deprecation system, golden fixtures) — the team is not scattering unowned TODOs.
- **`archive/` is docs-only** (50 tracked `.md` files) and clearly dated/named — an intentional historical record, not stale source masquerading as live code.
- **Known structural debt is already ticketed** (grammar-table bloat TSK-1214/1098; Stage-B twin deletion; PM store TSK-345). The board reflects reality.
- **Deprecated APIs are isolated and justified.** The one real deprecated-API dependency (LaunchServices) is scoped to a documented thin wrapper with an explicit "no non-deprecated variant exists" rationale.

---

## Coverage gaps (what I did NOT examine)

- **No build / no test execution.** Deprecation *warnings* the Swift/Clang compiler would emit (beyond the one grep-visible LaunchServices case) were not captured — a `swift build` warning sweep would surface more deprecated-symbol usage than static grep. Recommend a warnings-as-signal pass in CI.
- **Rigorous dead-symbol analysis not performed.** I spot-checked orphan status (the `pm` crate, the `CodeMirrorBridge` enum, twin engines) but did not run a whole-repo unused-`public`-symbol / unreferenced-file analysis (Swift has no built-in; would need `periphery` or equivalent — a new tool, out of scope). There may be additional orphaned `public` API not caught here.
- **Test-code debt largely out of scope.** I focused on `Sources/` + `rust-core/` production code. The ~178K LOC of tests (198 `XCTSkip` self-skips — mostly the by-design VM-tier gating, not debt) were not audited for their own dead/duplicated helpers.
- **Vendored asset internals not audited.** I flagged `mermaid.min.js` / `codemirror.js` weight + provenance but did not diff them against a known-good upstream release or scan the minified blobs for known-vulnerable patterns (that belongs in the security dimension).
- **Rust `unsafe` review is shallow.** `crates/core` is `#![forbid(unsafe_code)]`; I confirmed the boundary but did not audit the FFI crate's `unsafe` blocks for soundness (that's a correctness/security-dimension task, not tech-debt).
- **Runtime/perf debt not measured.** Any "slow but works" hot paths would need the profiling harness (VM-only), which this static pass did not exercise.
