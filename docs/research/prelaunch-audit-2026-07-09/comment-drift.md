# Pre-launch audit — Comment quality + drift

**Dimension:** Comments that mis-describe the code — stale ticket/architecture
references, doc-comments contradicting behavior, dead file/symbol pointers,
load-bearing comments gone wrong.
**Date:** 2026-07-10 · **Scope:** `Sources/` (~816 Swift files) + `rust-core/`
(~85 Rust files), read-only.

---

## Executive summary

This codebase is, by comment-drift standards, **exceptionally well maintained**.
The commenting culture is heavy and disciplined — comments narrate ticket
history, root-cause diagnoses, and cross-module contracts — and the vast majority
of the specific, checkable claims I sampled were **accurate**: numeric caps,
count assertions, doc-file cross-references, FFI safety contracts, and
wire-protocol rejection semantics all verified against the code.

The drift that exists is **concentrated in one place**: the **Stage-B "Swift twin
deletion"** landed **2026-07-07 (TSK-649/TSK-854), just before this audit**. That
change deleted several Swift engine twins (`CMEditApplier`,
`TreeSitterEngine+Folds.swift`, the Swift highlight/fold twins) and ported them to
Rust. The code call-sites were updated, but a scatter of **doc-comments and one
adjacent bench header were not** — they still describe the deleted Swift path as
the live one, point at deleted files, and in one case make a now-inverted
architectural claim ("folds have no Rust port yet") that **directly contradicts a
sibling file's comment**.

None of this is a ship-blocker — comments don't execute. But two of the findings
would **actively mislead** a maintainer or agent trying to understand the
highlight/fold architecture or the perf-bench methodology, so they are worth a
cheap cleanup pass before launch while the context is fresh.

**Findings:** 0 × P0 · 0 × P1 · 2 × P2 · 3 × P3.

---

## Methodology

What I examined and how:

- **Literal marker sweep** — `TODO`/`FIXME`/`HACK`/`XXX` across `Sources` +
  `rust-core`. Only **one** genuine inline TODO exists
  (`StatusBar.swift:438`, `TODO(#228)`); the rest are the `SourceAnnotationScanner`
  feature's own domain vocabulary, not stale markers.
- **Provisional-language sweep** — `for now` / `temporarily` / `stubbed` /
  `not yet` (46 hits): spot-read; all matched current state.
- **Numeric-claim verification** — comments asserting caps/limits/defaults
  (`capped at 1 second`, `[0.3s, 30s]`, `1 MiB`, `8 MiB`, `32 MiB`, bundle
  `65/80 MB`) cross-checked against the literals/`min`/`max`/`clamp` in code.
  **All accurate.**
- **Count-assertion verification** — comments stating "N grammars/cases/tools"
  checked against enums/switches (`ImageDocument` 8 orientations, `TreeSitterEngine`
  "8 dropped grammars", `UnifiedDiff.Line.Kind` case count). **All accurate.**
- **Doc-file cross-references** — extracted every `*.md` reference in comments
  (169 unique) and resolved them; the design-doc pointers (`LSP_DESIGN.md`,
  `perf-fix1-view-retention.md`, `DAEMON_LIFECYCLE_DESIGN.md`,
  `PHASE_5B_TREESITTER.md`, `M2-PLAN.md`, …) **all resolve.**
- **Swift-file & symbol cross-references** — extracted `*.swift` and
  backticked-identifier references in comments; flagged ones that no longer
  resolve to a file/declaration, then read each in context to separate real
  drift from example filenames (`a.swift`, `Foo.swift`) and intentional history
  notes ("Renamed from `CodeMirrorBridgeV1.swift`").
- **FFI/safety-contract read** — `rust-core/crates/ffi` `# Safety`/`SAFETY`
  comments and the `CoreClient` wire contracts (e.g. `len_utf16 == 0 on
  rejection`) verified against both sides of the boundary. **Accurate.**
- **Stage-B deletion follow-through** — traced every comment referencing a
  deleted twin (`CMEditApplier`, `TreeSitterEngine+Folds.swift`) to see whether
  the surrounding prose was updated with the call-site.

Verification bar: every finding below was confirmed by reading the code the
comment describes (and, for the architecture claims, the sibling file it
contradicts and the replacement engine that proves the claim false).

---

## Findings

### P2-1 — `RustHighlightAdapter` header says folds "have no Rust port yet" and points at a **deleted** file; contradicts its own sibling

- **Severity:** P2 (quality — materially misleading architecture comment)
- **File:** `Sources/ViewerCore/RustHighlightAdapter.swift:5-11`
- **Evidence:**
  ```
  /// (The Swift engine survives ONLY for code-FOLDS + structural search, which have no
  /// Rust port yet — see `TreeSitterEngine+Folds.swift`.)
  ```
  Both halves are false as of TSK-649/TSK-854 (2026-07-07):
  1. **Folds ARE ported to Rust.** `Sources/ViewerCore/RustFoldAdapter.swift`
     exists and is the fold engine.
  2. **`TreeSitterEngine+Folds.swift` is deleted** (`find Sources -name
     'TreeSitterEngine+Folds.swift'` → nothing; only `TreeSitterEngine.swift` and
     `TreeSitterEngine+TestSupport.swift` remain).
  3. This **directly contradicts the sibling comment**
     `Sources/ViewerCore/Highlight/TreeSitterEngine.swift:50`, which correctly
     states: *"the fold twin (`TreeSitterEngine+Folds.swift`, …) is DELETED — folds
     are served by the rust engine via `RustFoldAdapter`."*
  (Only the *structural-search* half of the claim is still true — that remains
  host Swift logic in `StructuralSearchEngine.swift`, no Rust port.)
- **Impact:** This is the header a maintainer/agent reads to understand the
  highlight ⇄ fold split. It tells them folds live in a Swift file that doesn't
  exist and hasn't been ported — the opposite of reality — and it disagrees with
  the authoritative comment one file over. High-confusion, exactly the "which is
  true?" trap.
- **Suggested fix:** Reword to: folds + structural search were the twin's last
  duties; **folds are now Rust (`RustFoldAdapter`)**; only **structural search**
  remains host Swift (`StructuralSearchEngine`). Drop the dead
  `TreeSitterEngine+Folds.swift` pointer.
- **Fix size:** S · **Fix risk:** safe (comment-only)

---

### P2-2 — `EditorPerfBench` header claims it benches a "pure Swift reducer `CMEditApplier.apply` … no Rust lib needed" — but the runner now calls the Rust FFI adapter

- **Severity:** P2 (quality — mis-describes what a perf number measures)
- **File:** `Sources/ViewerCore/Perf/EditorPerfBench.swift:14-16` and `:225-227`
- **Evidence:** Two header/doc comments still describe the deleted Swift path:
  ```
  //   - wall-clock of the model edit-apply (the pure Swift reducer
  //     `CMEditApplier.apply`, the deterministic UI-free kernel both the Swift
  //     and Rust paths agree on — host-stable, no WKWebView, no Rust lib needed).
  ```
  ```
  /// Pure: drives the host-stable Swift reducer
  /// (`CMEditApplier.apply`) for wall-clock, and the analytic wire model for
  /// FFI bytes. Deterministic inputs ⇒ comparable across commits.
  ```
  But the actual runner applies edits via the **Rust FFI adapter**
  (`runWorkload`, ~line 261): `let applied = RustCMEditAdapter.apply(edits, to: base)`,
  and its own *inline* comment there was updated: *"Stage-B: the rust reducer via
  the …"*. `CMEditApplier` **has no definition anywhere** (deleted TSK-649) —
  it survives only as a name in stale comments.
- **Impact:** The doc claims the wall-clock measures a **pure host-Swift kernel
  with "no Rust lib needed"**; it actually measures a **Rust FFI round-trip**.
  Those have very different latency characteristics, and the "no Rust lib needed"
  line would mislead anyone trying to run the bench on a host without the built
  Rust core (it will now require it). Header and body disagree about the
  methodology of a perf harness whose whole purpose is comparable numbers.
- **Suggested fix:** Update both header blocks to say the wall-clock now drives
  `RustCMEditAdapter.apply` (Rust core via FFI), and delete the stale
  "no Rust lib needed" / "pure Swift reducer" claims.
- **Fix size:** S · **Fix risk:** safe (comment-only)

---

### P3-1 — `StatusBar` zoom doc-comment claims a `"Zoom (UI+Doc)"` label; the view renders `Text("Zoom")`

- **Severity:** P3 (polish)
- **File:** `Sources/ViewerUI/StatusBar.swift:427-434` (vs `:448`)
- **Evidence:** The design-note comment says:
  ```
  /// Rather than fabricate a second readout … we
  /// surface the ONE value under an explicit "Zoom (UI+Doc)" label whose
  /// tooltip says they're unified.
  ```
  The actual `zoomReadout` renders `Text("Zoom")` (line 448) — no `(UI+Doc)`
  suffix. (The *tooltip*/help text does say UI and document share one level, so
  that half of the claim holds; only the label string drifted.)
- **Impact:** Minor. A maintainer trusting the comment would grep for
  `"Zoom (UI+Doc)"` and find nothing; the intent-vs-implementation mismatch is
  the kind that quietly rots.
- **Suggested fix:** Either change the comment to reflect the actual `"Zoom"`
  label, or (if the parenthetical was intended) update the `Text(...)`. The
  tooltip already carries the disambiguation, so the plain `"Zoom"` label is
  defensible — fix the comment.
- **Fix size:** S · **Fix risk:** safe (comment-only)

---

### P3-2 — `StructuralSearchEngine` comment "Mirrors `TreeSitterEngine+Folds.swift`" points at a deleted file

- **Severity:** P3 (polish)
- **File:** `Sources/ViewerCore/Highlight/StructuralSearchEngine.swift:12`
- **Evidence:** `/// … no shared parser state across concurrent searches). Mirrors
  \`TreeSitterEngine+Folds.swift\`.` — the referenced file was deleted in TSK-649
  (see P2-1). The parser-discipline *pattern* the comment describes still exists
  (folds now live in `RustFoldAdapter` + the `Fold*.swift` files), but the named
  file the comment tells you to compare against is gone.
- **Impact:** Low; a dangling "compare with X" pointer. Part of the same Stage-B
  fallout as P2-1.
- **Suggested fix:** Drop the `TreeSitterEngine+Folds.swift` reference or repoint
  it at the per-call `Parser` discipline in `TreeSitterEngine.swift` itself.
- **Fix size:** S · **Fix risk:** safe (comment-only)

---

### P3-3 — Cluster: several comments reference the deleted `CMEditApplier` type as a live referent

- **Severity:** P3 (polish)
- **Files:**
  - `Sources/RustCore/CoreClient.swift:620` — *"…the caller's cue to full-resync,
    exactly matching the Swift `CMEditApplier` contract."*
  - `Sources/ViewerCore/TextTransform.swift:7` — *"Design constraints (mirrors
    `CMEditApplier`):"*, and `:98` — *"Mirrors `CMEditApplier.decodeValidatingUTF16`;
    kept local so the two engines stay independently testable."*
  - `Sources/ViewerUI/Resources/codemirror/codemirror.html:148` — JS comment
    *"// CMEditApplier expects."*
- **Evidence:** `CMEditApplier` has **no definition** anywhere (deleted TSK-649);
  it exists only as a name in comments. These prose references present it as a
  live contract/reference implementation a reader can go consult. The
  `TextTransform.swift:98` case is the sharpest: *"kept local so the two engines
  stay independently testable"* — there is now only **one** engine (TextTransform
  + the Rust core), not "two", so the rationale is stale.
- **Impact:** Low but real; each is a "go look at `CMEditApplier`" breadcrumb that
  dead-ends. (Note: `Tests/ViewerCoreTests/CMEditApplierTests.swift` still exists
  but was correctly repurposed — its header says *"(`CMEditApplier`) is deleted —
  these rules now pin the RUST engine"* and it exercises `RustCMEditAdapter`. Only
  the **filename** is stale, not the comment; flagged here as an aside, not a
  finding.)
- **Suggested fix:** Repoint these at the surviving contract — the Rust core /
  `RustCMEditAdapter` — or phrase them as history ("formerly the deleted Swift
  `CMEditApplier`"). Fix the "two engines" wording in `TextTransform.swift:98`.
- **Fix size:** S · **Fix risk:** safe (comment-only)

---

## Positive observations

The dimension is, overall, a **strength** of this codebase. Concretely verified
as accurate:

- **Numeric caps/limits/defaults are tightly synchronized with code.**
  `FileWatcher` backoff "capped at 1 second" (`min(…, 1.0)`), `ScriptRunner`
  "`[0.3s, 30s]`" (`min(max(secs, 0.3), 30.0)`), `HotExitSpill` "1 MiB"
  (`hotExitMaxBytes = 1 << 20`), the "8 MiB snapshot read cap" / "32 MiB editor
  cap", and the `check-bundle-size.sh` `65 / 80 MB` comments all match their
  literals — and the bundle-size script even carries a well-kept **changelog of
  cap bumps** with the measured breach that justified each.
- **FFI safety + wire contracts are honest.** `CoreClient`'s "`lenUTF16` is 0 on
  rejection" is backed by `rust-core/crates/core/src/cm_edit.rs:357`
  (`None => DeltaResponse { changed: None, len_utf16: 0 }`); the `# Safety` blocks
  in `rust-core/crates/ffi/` (`buf.rs`, `guard.rs`, `launchd.rs`, `handle.rs`)
  match the unsafe operations they guard.
- **Count assertions match enums/switches** — `ImageDocument`'s "eight cases"
  (8 EXIF orientations), `TreeSitterEngine`'s "8 dropped grammars" (with the exact
  language list), `UnifiedDiff.Line.Kind`'s "4 cases".
- **Doc-file cross-references resolve** — 169 unique `*.md` references, including
  deep research-doc paths, all present.
- **Only one literal `TODO` in the entire tree** (`StatusBar.swift:438`,
  `TODO(#228)`), and it is *not* stale — the code confirms UI/doc zoom are still
  unified, so the "when the zoom pass splits them" TODO is still pending, not
  drifted.
- **No references to retired mechanisms** (`board.py`, `/tmp/board.py`) survive in
  `Sources/`.
- **Intentional history notes are labeled as such** ("Renamed from
  `CodeMirrorBridgeV1.swift`") rather than masquerading as live pointers.

The single systemic weakness is **follow-through on a same-week refactor**: the
Stage-B twin deletion (2026-07-07) updated call-sites and the primary owning file
comments, but left a scatter of secondary/cross-reference comments pointing at the
deleted world. All five findings trace to that one event — which is the
*best-case* shape for comment drift (localized, one root cause, one cleanup pass).

---

## Coverage gaps (what I did NOT examine)

- **Rendered-behavior comments** (SwiftUI/AppKit/WebView) — I verified *model-*
  and *contract-*level comment claims, not comments that describe on-screen visual
  behavior; per the repo's own directive those need VM/pixel confirmation, out of
  scope for a static read.
- **Exhaustive `///` parameter/return doc audit** — I sampled ~50 numeric/behavioral
  claims and the Stage-B cluster; I did **not** mechanically verify every
  `- Parameter:` / "returns nil when" doc line across all ~816 Swift files against
  its signature. A full pass would likely surface more P3-grade "returns
  X"-vs-actual nits.
- **The web asset bundles** (`Resources/codemirror/*.js`, `mermaid/`, `canvas/*.html`)
  — I checked cross-references *into* them but did not audit intra-JS comment
  accuracy beyond the one `codemirror.html` CMEditApplier reference.
- **Rust-internal prose beyond the FFI seam** — I read `ffi/` safety comments and
  the `cm_edit`/`fuzzy` contract prose; I did not deep-read every `core/` engine's
  internal comments (`canvas/` DSL, `formula`, `nav`, `json`) for algorithm-vs-
  comment drift.
- **`scripts/` and CI-workflow comments** beyond `check-bundle-size.sh`.
- **Historical-accuracy of ticket-number attributions** — I confirmed the *code*
  claims comments make, not whether each `TSK-####` in a comment maps to the ticket
  the board actually recorded (that cross-check needs the tracker; the repo's own
  CLAUDE.md notes a "#NNN trap" where board ids and code-comment ids can diverge).
