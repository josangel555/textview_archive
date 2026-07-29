# Greenfield Research Learnings — Batch 1/3 (Research Documents)

**Date:** 2026-07-11 · **Scope:** docs/research/ group 1/3 (9 dated research directories) · **Purpose:** Extract learnings from point-in-time investigations to guide the greenfield rebuild.

---

## Document Inventory

| Path | Document | Status | Learnings / Carry-forward |
|---|---|---|---|
| adversarial-review-2026-06-18/ | **13-dimension security + correctness audit** (FINAL.md = synthesis of 44 NEW issues) | **current** | **CRITICAL:** 1 SIGSEGV, 9 high-severity, 16 medium, 18 low findings across concurrency/security/perf/persistence/error-handling. **Key carry-forward:** patterns to avoid (unbounded recursion, use-after-free/teardown, stateless FFI, no fsync, silent error sinks). |
| agent-uat-framework-2026-06-20/ | **T6 agent-driven journey UAT design** (why, tiering, YAML scenario encoding, AX-first + vision fallback) | **current** | **CRITICAL:** the framework solves the render-verification gap (the #1 blocker in the audit). Two modes: Partial T6 = mandatory per-change on-screen confirmation; Full T6 = nightly/release regression suite. **Carry-forward:** YAML scenario encoding, AX-id hints, recovery clauses, batch journeys (one launch, N features). |
| autorun-2026-06-04/ | **Agent autonomous-loop research** (Claude dir layout, explorer patterns, hooks, perf hotpaths, image approach) | **stale** | **Context:** pre-handoff framework iteration. The agent loop SOP has since settled into `docs/TASK_WORKFLOW.md` + board-driven batching. **Skip carry-forward** (superseded by current `TASK_WORKFLOW`). |
| build-test-speedup-2026-06-14/ | **Pipeline analysis & recommendations** (SwiftPM, Rust, disk/cache fragmentation, 16 ranked free/approval-gated wins) | **current** | **Key findings:** `.build` is 4.4 GB (duplication: index-build tree 1.7 GB + git mirrors 1.6 GB cloned twice). Rust target-dir fragmented 3 ways (~9.7 GB). **Carry-forward:** F1–F6 are free wins (disable index-store on gate, share one Rust cache, reap stale dirs). T1 (cargo-nextest) + T2 (grammar vendoring) need approval. **For greenfield:** design one shared artifact cache from day 1 (avoid the post-hoc fragmentation). |
| canvas-2026-07-01/ | **Visual-authoring epic research** (22 supporting deep-dives on document models, layout, theming, tools, animation) | **parked** | **Owner decision:** greenlit then parked for owner review. **Key ideas:** flat `{id, parentId, index}` record map (not tree) + fractional indexing = O(1) reparent + CRDT-ready; flow/flex eliminates overlap by construction (avoid constraint solvers — fail silently); W3C DTCG token JSON (semantic tier + CSS compile). **Skip commit** without explicit owner go-ahead. |
| cm-lezer-vs-treesitter-parity-2026-06-20/ | **CodeMirror Lezer-packs vs native tree-sitter decorations — feature-parity gaps** | **current** | **Context:** the plan to replace 6-language Lezer highlighting with ~22-language native tree-sitter. **Key gaps:** (1) Markdown fenced-code injection (real regression for editor), (2) large-file perf (whole-doc non-incr reparse vs Lezer's viewport-bounded worker), (3) highlight granularity flattens (20 TokenKind vs rich tag set), (4) silent keyboard-only feature regressions (comment-toggle, auto-indent, structural-select). **Carry-forward:** hybrid path (highlighting + fold + cheap config features) + defer expensive ones (injection, auto-indent). |
| editor-perf-791-2026-06-13/ | **"Was CM6 a mistake?" — typing latency root-cause analysis** | **current** | **Finding:** CM6 is sound; slowness is 3 separable causes: (1) **cm_apply is stateless** — whole doc crosses FFI per batch (S3 design issue) = highest-leverage fix, (2) grammar-query compile ~400ms on main (already ticketed TSK-619), (3) WebView mount cost (structural, mitigated by pane-retention). **Carry-forward:** architecture decision: stateful Rust editor session (like CSV) vs stateless snapshots (impacts migration contract). **For greenfield:** design editor session as stateful from the start to avoid the later redesign. |
| feature-parity-2026-06-11/ | **TextView vs TextEdit / Sublime / VS Code / IntelliJ — inventory + gap ranking** | **current** | **Verdict:** TextView is "viewer-first workbench" (renders markdown/media, viewing surfaces trump text-editing polish). **Top 10 gaps:** (1) multi-cursor (near-free), (2) autocomplete (none), (3) print/PDF (nearly free via WKWebView), (4) unified Goto-Anything, (5) project-wide replace, (6) LSP rename+actions (plumbing exists), (7) spellcheck, (8) local-history (unwired!), (9) markdown outline (unwired!), (10) git gutter. **Carry-forward:** the "intentional non-goal" framing (deliberately below VS Code on IDE axis). **For greenfield:** pick the tier explicitly upfront; prioritize gap #1 (multi-cursor, +3 lines). |
| formula-rust-port-spike-2026-06-21/ | **Should formula evaluator port to Rust? Crate landscape + boundary design** | **current** | **Decision:** hand-write in Rust (not `formualizer-eval`). **Key learnings:** (1) Adopt landscape = 1 option (formualizer-eval v0.7, heavy Arrow dep, pre-1.0), (2) stateful `FormulaSession` handle (coarse API, transport-agnostic) beats stateless snapshots, (3) reuse existing `mdvcore_call` MessagePack envelope, (4) defer recalc to later slice, (5) pin size flags (lto=fat, panic=abort, strip). **Carry-forward:** the stateful-handle pattern (applies to any core service), the versioning discipline (field-id not JSON), the binary-codec lesson. |

---

## Key Learnings from This Batch

### 1. Architecture & Design Patterns

#### **1.1 Stateful vs Stateless FFI Boundaries**
- **Adversarial review + Editor-perf + Formula spike** converge on: **design Rust cores stateful from day 1**.
  - **Stateless snapshots** (send whole doc/grid per call) = architectural lock-in; scaling kills you later (TSK-543's "typing is slow" becomes: whole 50MB doc crosses FFI per keystroke-batch).
  - **Stateful handles** (Rust owns the data, Swift sends coarse commands) = transport-portable, recalc-friendly, remote-core ready.
  - **Design decision now:** "formula-port shows the shape works for new engines; editor-perf shows the cost of choosing wrong early."
- **Lesson:** CSV is the pattern; apply it to every core service from the start (editor, formula, etc.).

#### **1.2 Message-Shaped, Coarse-Grained Command/Event Boundaries**
- **Formula spike** names the latency hierarchy: in-process FFI ~ns · IPC ~µs · network RPC ~ms+.
  - A one-call-per-cell API is catastrophic over the wire (chained deps = pure RTT stall).
  - **Design for "coarse/batched from day one or it can't go remote later."**
- **Lesson:** the existing `mdvcore_call` MessagePack envelope is the right shape; don't build per-method symbols (adversarial-review flags them as dead-but-exported).

#### **1.3 Flat Record Maps with Fractional Indexing (not trees)**
- **Canvas research** identifies this as the convergent shape across tldraw, Figma, Quadratic.
  - `{id, parentId, index}` (vs nesting) = O(1) reparent + CRDT-friendly + patch-friendly.
  - Fractional indexing (siblings ordered by `0.5 < index < 1.5`, not ordinals) allows concurrent edits.
- **Lesson:** if building a document model, start with flat records, not AST nesting.

#### **1.4 Defensive FFI Seams**
- **Adversarial review** finds patterns in the Rust–Swift boundary:
  - **C1 (MessagePack SIGSEGV):** unbounded recursion. **Fix:** depth counter + throw, not panic.
  - **M6–M7:** rich error out-buffers silently dropped; skewed method-ids indistinguishable from faults. **Fix:** log every error; distinct status codes.
  - **M4:** non-async-signal-safe work in fork child (malloc between fork/exec deadlock hazard). **Fix:** precompute in parent; child does only exec.
- **Lesson:** every FFI seam needs: (a) panic guard (`catch_unwind`), (b) error logging, (c) pre-validation of inputs.

### 2. Performance & Optimization

#### **2.1 Whole-Document Parsing = Performance Cliff**
- **CM6 vs TreeSitter parity** + **Editor-perf** both identify: native TS engine parses whole doc every call (no incremental), while Lezer's CM6 worker is viewport-bounded + incremental.
  - **Large-file regression risk:** a 1 MB file re-parses on every edit with no incremental path.
  - **Lesson:** if moving to native highlighting, either:
    1. Implement `applyEdits` incremental TS reparse (the hard path),
    2. Debounce + viewport-bound + size-cap (the pragmatic path), or
    3. Accept the limitation for now and defer.

#### **2.2 Hidden Duplication in Build Caches**
- **Build-test-speedup** uncovers 4.4 GB in `.build` is NOT "the app is big" — it's duplication:
  - LSP's background indexer maintains a separate `index-build/` tree with **duplicate full clones of every grammar** (814 MB git mirrors, 798 MB already in `repositories/`).
  - `.build/release/` coexists with debug (two ModuleCache @ 225 MB each, two index stores, two dSYMs).
  - Rust cache fragmentation: 3 separate `CARGO_TARGET_DIR` paths (mdv-rust-{csv,gate,target}) = cold compiles when switching.
- **Lesson for greenfield:** design one unified cache from day 1; catch duplication in CI (`du` checks on artifact dirs).

#### **2.3 The Grammar-Parsing Startup Cost**
- **Editor-perf** finds tree-sitter grammar query-compile ~400ms on main (one-time per grammar, felt as stall when first opening a source file).
  - Lezer pre-compiles at bundle-build time; TS compiles on-demand.
- **Lesson:** if using TS, pre-compile queries into static bytecode at build time (or accept the stall).

### 3. Testing & Validation Strategy

#### **3.1 The UAT Framework Solves the Render-Verification Gap**
- **Agent-uat-framework** is the answer to "how do agents validate on-screen behavior without owner involvement?"
  - **Partial T6 (mandatory):** agent screenshots its own change on the real UI before calling it fixed.
  - **Full T6 (nightly):** regression suite of agent-driven journeys (YAML scenarios + AX-first clicks, vision fallback for visual asserts).
- **Why it matters:** model-green ≠ on-screen-works (the compositor-occlusion + ImageRenderer false-greens). Partial T6 is the gate.
- **Lesson:** build the AX-first harness into the toolchain early (macOS Accessibility API + CGEvent). Start with simple AX-id based clicking, add vision later.

#### **3.2 Real-Event Tests > Script-Verbs for UI Validation**
- **Agent-uat-framework** emphasizes: drive via **System Events (AX)** targeting `accessibilityIdentifier`s, **not pure script verbs**.
  - Verbs are cheap for deterministic setup; AX is how the OS knows the app is real.
  - Vision (screenshot + Read PNG) is expensive; use sparingly (assertions you can't express structurally).
- **Lesson:** litter the UI with `accessibilityIdentifier`s from day 1 (cheap insurance for future UAT).

#### **3.3 Test Teeth: Prove the Negative Control Works**
- **Adversarial review + CLAUDE.md feedback** flag: a test that's never failed on broken code is not a guard.
- **Solution:** gate a deliberate break behind `MDVNegativeControl.isBroken("<NAME>")` (reads env var); assert the test **fails** when the break is active.
- **Lesson:** for any regression-critical test (scroll position persistence, render quality), build in the negative control.

### 4. Security & Integrity Findings

#### **4.1 Sanitizer Alone ≠ Defense; CSP Must Backstop**
- **H1 (stored XSS):** the HTML export deliberately ships **no CSP** (to permit external images). The regex sanitizer has confirmed bypasses:
  - `<a href="x"onmouseover=…>` (no space after attr, so `\s+on[a-z]+` misses it).
  - `jav&#x09;ascript:` (entity encoding defeats literal-string match).
- **Single defense = single point of failure.** Without CSP, one sanitizer miss = stored XSS.
- **Lesson:** defense-in-depth (CSP *and* sanitizer), or escape output (not HTML pass-through).

#### **4.2 FFI Boundary Validation Is Not Optional**
- **M3 (Int(UInt64) trap):** unchecked remote offset `Int(try a[0].u64Value())` traps at runtime.
- **M7 (skewed method-id):** unknown method returns `Internal` (indistinguishable from real fault).
- **M13 (EINTR):** I/O reads treat any `-1` as fatal (not retrying EINTR).
- **Lesson:** every value from the Rust side needs bounds-checking or type-safe conversion. Log all errors richly (not silent nil drops).

#### **4.3 Hot-Exit Data Loss (Dual-Failure Mode)**
- **L-data1 cluster:** when the app closes, unsaved edits are clobbered if the disk file changed externally (no external-change guard; hot-exit re-reads fresh from disk, no conflict prompt).
  - Plus: large edits (>1 MiB) are silently dropped in the persist buffer.
  - Plus: no fsync on any session/bookmark/history writes (power-loss = truncated files).
- **Lesson:** persist `(mtime, size, hash)` with every tab snapshot; always conflict-check on restore. Atomic-rename ≠ durable; add fsync.

### 5. Build System & Tooling

#### **5.1 Shared Rust Target Dir from Day 1**
- **Build-test-speedup** identifies fragmentation across 3 cargo caches as a hidden time cost (alternating "build app" / "run gate" pays cold compiles).
- **Lesson:** use one `CARGO_TARGET_DIR` globally from the start; make it a `.gitignore`d tmp path (e.g., `/private/tmp/mdv-rust-target`).

#### **5.2 Grammar Distribution (Caret-Ranges Are a Trap)**
- **H8:** every tree-sitter grammar uses `from:` (resolves to `>=x, <1.0.0`), violating the manifest's own comment saying `from:` is too open.
  - Parsed grammars are untrusted (attack surface); drift window is wider than expected.
- **Lesson:** pin all grammar deps to exact versions; never `from:` on untrusted inputs. Consider T2's vendoring option (grammars as generated parser.c, not full clones).

#### **5.3 Supply-Chain Audits Must Gate the PR, Not Just Nightly**
- **H9:** `cargo audit` / `cargo deny` run only on nightly, not the PR gate. A deliberate lock edit adding a yanked/banned dep passes CI.
- **Lesson:** add supply-chain checks to the merge gate (not post-merge nightly).

### 6. Editor Architecture & Syntax Highlighting

#### **6.1 The Lezer-to-TreeSitter Switch Has Real Regressions (Hidden in Keyboard-Only Features)**
- **CM6-vs-TS parity** details the cost of dropping Lezer:
  - **High-impact:** Markdown fenced-code injection (Lezer highlights JS/Python inside \`\`\` blocks; TS returns @none). **Real regression for a Markdown editor.**
  - **Perf:** whole-document non-incremental re-tokenize vs Lezer's viewport-bounded incremental worker.
  - **Silent regressions:** comment-toggle (`Mod-/`), auto-indent on Enter, structural-selection (`expand-selection`) are keyboard-only, so missing them feels like UI just broke (not a feature-gap).
- **Lesson:** the phased hybrid path (highlighting → fold → config features → defer injection/indent) is safer than a pure cutover.

#### **6.2 Highlight Granularity Matters (20 TokenKind vs Rich Tags)**
- **CM6-vs-TS parity:** native engine flattens to 20 TokenKind (keyword, string, etc.), but Lezer's tags allow distinguishing `keyword.control` vs `keyword`, `function` vs `property`.
- **Without expansion, colors flatten** vs the source view.
- **Lesson:** if adopting TS highlighting, expand TokenKind + CaptureMap upfront to preserve visual distinctions.

#### **6.3 Code Folding Without a *-folds.scm Query = No Folding**
- **CM6-vs-TS parity:** Lezer folds fallback to language data; native TS folds require a `*-folds.scm` query file.
  - **Python has no `python-folds.scm` in the repo** → folding disappears for Python on the switch.
- **Lesson:** author `*-folds.scm` for all languages before dropping Lezer (or accept regression).

### 7. Rust-Core Strategy

#### **7.1 Hand-Write (Don't Adopt Crates) for Load-Bearing Logic**
- **Formula spike:** crate landscape = 1 viable option (formualizer-eval, v0.7, pre-1.0, heavy Arrow).
  - **Decision:** hand-write the evaluator (29-test corpus already written; minimal-deps + size-cap).
- **Lesson:** a pre-1.0, heavy dep on hot path is a liability. Own the logic if you own the requirements.

#### **7.2 Versioning Discipline: Field-IDs, Not JSON, from Commit #1**
- **Formula spike:** a message-shaped FFI boundary (coarse, batched, RPC-style) is transport-portable.
  - **Wire discipline:** protobuf-style (stable field ids, never reuse/retype, ignore-unknown for forward-compat).
  - **Codec:** binary (not JSON — the xi-editor lesson).
- **Lesson:** even in-process, adopt the discipline so the remote future has a migration path.

#### **7.3 The Stateful-Handle Pattern Applies Everywhere**
- **Formula spike** validates the pattern (from CSV, applied to formula, generalizable to editor, etc.):
  - Rust owns the data (opaque `Box` handle + `Arc<Mutex>` for Sendability).
  - Swift calls set-cells / eval / get-viewport (coarse commands).
  - Rust returns deltas (dirty-mark → topo output).
- **Lesson:** when porting an engine to Rust, use this shape from day 1.

#### **7.4 Don't Go Out-of-Process Prematurely**
- **Formula spike** cites xi-editor's mistake: in-process vs out-of-process is a later choice, not an early one.
  - **The win is the message-shaped API.** Whether it lives in-process (FFI) or on a socket (RPC) is implementation detail.
- **Lesson:** design the message boundary; defer the transport.

### 8. UI/UX Completeness & Feature Prioritization

#### **8.1 "Intentionally Below VS Code" Is a Valid Position**
- **Feature-parity** review shows TextView is "viewer-first workbench," not an IDE.
  - Viewer features (markdown/hex/CSV/SQLite/media + git panel) are the wins.
  - Text-manipulation ergonomics (multi-cursor, snippets, minimap) are lower-priority or absent by design.
- **Lesson:** pick the tier upfront; communicate it (not every feature gap is a bug).

#### **8.2 Multi-Cursor Is Cheap to Enable (But Silent if Not Wired)**
- **Feature-parity:** CM6 bundle includes `rectangularSelection`, but not `allowMultipleSelections` or `selectNextOccurrence`.
  - Enabling is 3–5 lines; the gap is unknown (keyboard-only, no menu item).
- **Lesson:** audit for silent feature gaps (keyboard shortcuts wired to missing facets). Wire a menu item if it's a real feature.

#### **8.3 Several Features Are Architecturally Built but Unwired**
- **Feature-parity:** `LocalHistoryStore` exists (tested), `MarkdownOutline` parses headings (tested), but no UI consumes them.
  - A second pass on the codebase would reap "free" features.
- **Lesson:** for greenfield, distinguish "not implemented" from "built but unwired" in the tracking backlog.

#### **8.4 Print/PDF Is Nearly Free (WKWebView Provides It)**
- **Feature-parity** flags: `NSPrintOperation` is unused; WKWebView's `printOperation` + `createPDF` are nearly free.
  - For a viewer-first product, "⌘P the rendered markdown" is a baseline expectation.
- **Lesson:** low-cost baseline features (print, spellcheck system-integration) are worth the 1–2 function calls.

### 9. Data Persistence & Error Handling

#### **9.1 Silent Error Sinks Are the Worst Kind**
- **L-eh2 cluster:** 7 confirmed sites where failures are swallowed (`try?`) with zero user feedback:
  - "Open in Browser" silently fails if the temp HTML write fails.
  - git-log markdown tab opens even when the file write failed.
  - SQLite schema-listing failures show as "successfully opened but empty."
- **Lesson:** every user-facing write must surface feedback (do/catch + NSAlert). Silent failures are data-loss seeds.

#### **9.2 Atomic Rename ≠ Durable; fsync Is Mandatory**
- **L-data1:** `Data.write(.atomic)` + rename is not crash-safe without fsync.
  - Power-loss window: temp write succeeds, rename succeeds, crash before fsync → truncated file.
  - **Session/bookmark/history are the vulnerable paths** (critical state).
- **Lesson:** for every atomic-write operation, add `fsync(temp_fd)` → rename → `fsync(dir_fd)`.

#### **9.3 Conflict Detection on Restore Is Mandatory**
- **L-data1:** hot-exit re-reads fresh from disk with no external-change check.
  - If the file changed while the app was closed, the next save clobbers it (silent data loss).
- **Lesson:** persist `(mtime, size, hash)` with every tab snapshot; conflict-check on restore.

### 10. Remote-Core Transport Hazards

#### **10.1 Unbounded Structures at RPC Boundaries**
- **M12:** `orphanEvents` dict grows unboundedly by attacker-chosen sub-id (cap per-list, not dict keys).
  - A buggy server streams events with monotonic sub-ids → client OOMs.
- **Lesson:** at every RPC boundary, cap unbounded collections (dict keys, list length, total bytes). Cap globally, not per-item.

#### **10.2 Signal Handling Is Fragile**
- **M13:** I/O reads treat EINTR as fatal (don't retry).
- **M4:** fork child runs non-async-signal-safe code (malloc hazard).
- **Lesson:** signal-safe coding is rare in Swift. Use `posix_spawn` / `posix_openpt` instead of fork+exec if possible. Retry EINTR everywhere.

#### **10.3 Use-After-Teardown in Async Subscriptions**
- **M1:** RemoteTransport handler can fire after `unsubscribe` returns (captured copy outlives the nil-out).
- **Lesson:** async callbacks must sync-barrier on teardown, or document the "trailing call" contract explicitly.

---

## Decision Records Found

| Decision | Rationale | How It Played Out |
|---|---|---|
| **Formula: hand-write, don't adopt** | Minimal-deps + size-cap (26 MB exec) + own logic + 29-test corpus. | Landed (TSK-1213). Slices 1–3 committed; 4–5 in progress. Recalc deferred. |
| **Formula: stateful handle** | Coarse API beats per-call snapshots (transport-portable, recalc-friendly). | Validates CSV pattern; applies to future engine ports. |
| **CM6 is sound; typing-latency root is stateless cm_apply** | Slowness is architectural (whole doc crosses FFI), not the technology. | Parked on owner decision (TSK-791): invest in stateful redesign now, or accept perf / reconsider editor? |
| **Lezer-to-TS switch: phased hybrid, not pure cutover** | Regressions concentrate in hard features (injection, indent); cheap ones (comment, bracket) can be rebuilt. | Currently in-flight. Phase A (highlighting) validated; Phase B–D sequenced. |
| **UAT framework: AX-first, vision fallback** | Deterministic (no coordinates), cheap (no vision per-step), scalable (hint caching). | Framework designed; tools (`mac-computer-use` MCP) still building. |
| **Build/test: free wins early, approval-gated later** | F1–F6 (index-store, Rust cache, reap stale) are instant; T1 (nextest), T2 (grammar vendor) need owner approval. | F1–F3 landed (TSK-832/833); F4 pending cleanup; T1–T2 owner-gated. |

---

## Portable-Artifact Candidates

### **MUST PORT** (nearly verbatim, decision-critical)

1. **Formula evaluation port** (rust-core/crates/core/src/formula.rs slices 1–3)
   - Arithmetic core + cell refs + function library.
   - Already carries 29-test golden corpus for validation.
   - **Why:** accelerates greenfield formula support; pattern applies to other engines.

2. **Stateful-handle FFI boundary pattern** (formula/CSV/editor)
   - Opaque Rust handle + Arc<Mutex> + coarse command/event API + binary codec.
   - Minimal-example: formula session (set-cells, eval, get-viewport).
   - **Why:** unblocks both in-process scalability and future remote-core.

3. **UAT scenario YAML format + runner framework**
   - Step encoding (do/see/hint/assert/recovery), AX-id hints, vision fallback.
   - Drift loop (execute → observe → match → classify → recover/update/fail).
   - **Why:** the tested solution to render-verification; saves design time.

4. **Build & test recommendations** (F1–F6 free wins)
   - Disable index-store on gate, share Rust cache, reap stale dirs, codegen-units tuning.
   - Scripts already exist; greenfield repeats the setup.
   - **Why:** avoids 10+ GB of waste + multi-second gate overhead.

5. **Security & integrity patterns from adversarial review**
   - Panic guards at every FFI seam, error logging (never silent drops), depth-bounded recursion, fsync on atomic writes, conflict-check on restore.
   - **Why:** the 44 findings are new in this codebase; avoid repeating them.

### **SHOULD DISTILL** (idea worth carrying, adapt context)

1. **The CM6-vs-TS parity matrix** (which features live where, rebuild costs)
   - The "service seams" taxonomy (Seam 1 = service facets tree-free; Seam 2 = language-data config; hard tree dependency).
   - Greenfiel editor: choose highlighting path early (lezer/native TS/hybrid) + budget for regressions.

2. **Feature-parity framing** ("intentionally below VS Code")
   - The viewer-first tier clarifies priorities (rendering + git + search > multi-cursor + IDE polish).
   - Define greenfield's tier explicitly upfront (not post-hoc apologizing for gaps).

3. **TreeSitter adoption lessons** (from CM6-vs-TS, editor-perf)
   - If using TS, pre-compile queries, implement incremental reparse or accept viewport-bound + debounce, expand TokenKind, author fold queries.
   - **Why:** TS is powerful; the adoption tax is real if not budgeted.

4. **FFI boundary hazards** (from adversarial review)
   - Unbounded structures, signal-safe coding, use-after-teardown, Int conversion traps, error logging.
   - **Why:** the patterns repeat across remote-transports and FFI seams.

5. **Canvas research (design tokens, layout, document models)**
   - Flat records + fractional indexing (not nesting).
   - Flow/flex safety (constraints fail silently — avoid them).
   - W3C DTCG token JSON (semantic tier).
   - **Why:** if the greenfield includes visual-authoring, these are the convergent ideas (owner approval needed first).

### **SAFE TO SKIP**

1. **autorun-2026-06-04** — pre-handoff agent-loop iteration; superseded by current TASK_WORKFLOW.md.
2. **canvas detailed deep-dives** — parked for owner review; don't implement without go-ahead.
3. **formula deep-recalc research** — deferred to later slice (currently at slice 3).
4. **CM6 grammar-compile perf** (TSK-619) — already ticketed; not a design pattern.

---

## Key Learnings Summary

### **Architectural**
1. Stateful Rust cores (not stateless snapshots) from day 1.
2. Coarse-grained, message-shaped FFI boundaries (transport-portable, versioned).
3. Flat data models (not nested ASTs); fractional indexing for concurrent edits.

### **Performance**
1. Avoid whole-document parsing without incremental path (viewport-bound or debounce).
2. Unify artifact caches; catch duplication in CI.
3. Pre-compile expensive resources (TS queries, grammar tables).

### **Validation**
1. Partial T6 (agent UAT of own changes) is the gate for render-path work.
2. AX-id harness (not coordinates); litter UI with identifiers from day 1.
3. Negative-control tests prove the assertion works (not just passes).

### **Security**
1. Defense-in-depth (CSP + sanitizer, not one alone).
2. Panic guards + error logging at every FFI seam.
3. Validate all remote inputs; cap unbounded collections.

### **Durability**
1. Persist metadata with snapshots (mtime/hash); conflict-check on restore.
2. fsync is mandatory for crash-safety (atomic-rename alone is not).
3. Zero silent error sinks; surface failures to the user.

### **Completeness**
1. Pick the feature tier upfront (viewer-first workbench ≠ IDE).
2. Audit for "built but unwired" features (LocalHistory, Markdown outline).
3. Low-cost baseline (print, spellcheck) = quick wins if in scope.

---

## Context for Downstream Analysis

These documents are point-in-time investigations (April–July 2026) conducted as the markdown_viewer project neared feature-completion. They reveal:

- **Production risks identified too late:** the adversarial review found 44 NEW issues across 13 dimensions (the codebase was well-hardened in audited areas, but gaps concentrated in remote-transport, export, and persistence seams).
- **Architectural decisions that paid off:** stateful cores (CSV → formula validates), message-shaped FFI (transport-ready), flat data models (canvas research confirms convergence).
- **Paths not taken:** Canvas feature is greenlit but parked (owner review pending); formula recalc is deferred; editor-perf stateful redesign is owner-gated.
- **Tooling debt:** build fragmentation, grammar versioning traps, UAT framework (designed, tools in progress).

**For the greenfield rebuild:** treat the security findings as anti-patterns (apply defensive seams from commit #1), adopt the stateful-core pattern early (saves a later redesign like TSK-543), and design the test/validation layer alongside the product (UAT framework is the difference between "model-green" and "works on screen").

