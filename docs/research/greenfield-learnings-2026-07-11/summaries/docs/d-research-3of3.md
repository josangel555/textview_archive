# Research Batch 3/3 Learnings — Docs Index

Batch 3/3 covers 9 dated research directories (2026-05-31 through 2026-07-04) spanning testing strategy, performance audits, Rust migration, and architectural decisions. These are point-in-time investigations grounding decisions on the production codebase.

---

## Document Inventory

### `testing-strategy-2026-05-31/` — Testing pyramid, tier model, and migration plan

**Testing_STRATEGY.md** — synthesis of testing research + audit. Establishes the honest layer model for UI testing (T1 pure logic, T1m @MainActor model, T2' in-process tree walk, T2-px in-process raster, T4 real app, T5 screencapture live window). Status: **current** — the tier model and guardrails (tier as base class, TIER-JUSTIFY convention, headless-safe default) shipped and in use.

- **learnings:**
  - **The "real screen" line is between SwiftUI layout-commit and WindowServer pixel composition** (not between logic and UI). T2-px (`cacheDisplay`, `ImageRenderer`) renders views in isolation and is structurally blind to compositor bugs.
  - **The most valuable UI tests are headless ones** — `RepublishInvariant` and coordinator suites (T1m) catch perf/correctness bugs that "drive the app" tests (T4/T5) cannot observe (quadratic re-renders, memory leaks, fan-out storms).
  - **The `--script` runner predated coordinator extraction**, leaving tests over-placed at T4. The demotions were never done after `DocumentModel` became cleanly DI-constructible — a pure plumbing debt.
  - **TUI (ratatui): the "real screen" line is far to the right** — ~90% of TUI correctness (state → cell grid) is testable at the `Buffer` layer with style-fidelity assertions; only termios/SIGWINCH/mouse protocol require PTY.
  - **Vanilla web has a hard cliff** — jsdom layers 1–2 (logic + DOM structure) are faithful; layers 3–5 (layout, computed style, hit-test, raster) require a real browser engine.
- **carry-forward:** PORT — the tier model and TIER-JUSTIFY guardrail pattern are directly reusable for the greenfield project. The specific tool advice (DiagnosticDump, ViewInspector scoping, no `swift-snapshot-testing`) is implementation-specific but the reasoning is durable.

**audit-uitests-first-half.md, audit-uitests-second-half.md** — systematic inventory of 579 test files, 5,022 methods. Audit findings: 11 "over-placed" suites (T4 that should be T1m), `#192` WebView-gate over-poisoning the headless gate, the `NSRulerView` compositor bug exploited for one T5 meta-test. Status: **current** — the over-placement diagnosis held true; migration ongoing.

- **learnings:** not repeated from TESTING_STRATEGY synthesis above.
- **carry-forward:** DISTILL — the audit *method* (read-only inventory of what assertions read, categorize by tier, diagnose over-placement) is a reusable auditing pattern for the new project.

**research-ui-pyramid-firstprinciples.md** — open-ended research on tier definitions across mobile (Android/iOS), web, native desktop. Verifies the T1/T1m/T2'/T2-px/T4/T5 model against industry practice. Status: **current** — the conclusions match production experience.

- **learnings:** the model (headless, in-process, live-app, pixels) is conventional, not novel. Headless first, UI tiers as the residue, is the consensus.
- **carry-forward:** SKIP — this is background research; the synthesis in TESTING_STRATEGY is the payload.

**research-swiftui-testing.md, research-offscreen-vs-live-render.md, research-tui-ratatui-testing.md, research-vanilla-web-testing.md** — unprimed deep dives on test tooling for each platform. Status: **current** — the findings ground the TESTING_STRATEGY tier assignments.

- **learnings:** SwiftUI testing is author-intended headless (body eval + `@Published` observation); ViewInspector reads declared tree but not resolved layout; CodeMirror in-process WebView hosting is host-testable via the existing `ContentViewHostingTests` pattern.
- **carry-forward:** DISTILL — each platform's testing affordances and constraints (what layers are observable headlessly vs require live) are the durable guidance. Tool choices are implementation-specific.

---

### `test-stack-audit-2026-06-13/` — Swift Testing vs XCTest, test coverage, and tier enforcement

**FINDINGS.md** — empirical survey of the test tree at commit 809bb2f. Verdict: stay XCTest (tier machinery is XCtest-bound), allow Swift Testing for NEW pure-logic suites only (after a pilot). Four concrete gaps identified: (G1) no code-coverage measurement, (G2) live-WebView suites mis-based on plain XCTestCase (not a heavy tier), (G3) doc drift on PR-gate WebView lane, (G4) teeth discipline is convention, not enforced. Status: **current** — the gaps exist; G1/G2 filed as follow-up tickets (TSK-793a/b).

- **learnings:**
  - **XCTest's `XCTestObservation` gate is load-bearing** — the tier-gate observer (TierGateObserver) watches `testCaseDidFinish` and asserts heavy tiers skip in the merge gate. Swift Testing has no equivalent (uses struct-based suites, not class hierarchy) — a wholesale migration would require reimplementing the gate from scratch.
  - **Tier-is-the-type enforcement closes a silent-regression hole** — without machine-checkable tier, a heavy test can slip into the host gate undetected (and spawn a window). Codifying tier as the base class makes it opt-up, not implicit.
  - **Parameterized tests are high-value for table-driven suites** — FileTypeDetector, golden tokenizers, matrix tests. Swift Testing's `@Test(arguments:)` is cleaner than XCTest's hand-rolled loops, but the payoff is local to specific suites, not bulk migration.
- **carry-forward:** DISTILL — the gate-observer pattern (an XCTestObservation that asserts tier placement at test finish) is reusable architecture. The "tier as base class" and "TIER-JUSTIFY convention" are portable tier-enforcement ideas. Swift Testing's parameterization is worth adopting for new pure-logic suites in the greenfield if the framework is chosen.

---

### `rust-perf-2026-06-05/` — Rust core performance audit and quick wins

**README.md** — background research on rust-core hot paths. Measured opt-level impact: switching `dist` from `opt-level = "z"` (size) to `opt-level = 3` yields 1.6–4× speedup across CSV/wire/diff/hex with **zero net binary-size cost** after dead-strip. Six quick wins identified (no-alloc case-fold, borrow-based FFI snapshot, stop discarding table clones in filter). One dep ask: `memchr` (SIMD substring search for filter + hex search). Status: **current** — the profile findings are grounded; the quick wins are low-risk, mostly landed or in progress.

- **learnings:**
  - **The shipped profile optimizes for the wrong metric** — size over speed. Owner priority is latency; the profile flip (z→3) is the single biggest, lowest-risk win.
  - **Per-element allocations in loops dominate remaining perf** — filter `String` per cell, wire encode two vecs instead of one, CSV string arena. Structural fixes beat micro-opts.
  - **Borrow-based encoding is a seam principle** — `snapshot_frame` (borrow) exists but the FFI shim calls the owned `snapshot()`. Reusing existing patterns beats adding new paths.
  - **Measured > guessed** — the hex search naive path was already 3.4× slower than the quick-win no-alloc filter; profiling the Swift side (MsgPackReader decode) is next.
- **carry-forward:** PORT — the measured perf baseline (1.6–4× speedups from opt-level changes and quick wins) and the quick-win catalog (no-alloc case-fold, borrow encoder, single-allocation frame) are directly reusable. The `memchr` dep ask is approved; the pattern of measuring before refactoring is the discipline to carry forward.

---

### `source-perf-audit-2026-06-14/` — Swift + Rust hot-path inefficiency survey

**SYNTHESIS.md** — read-only audit of `Sources/` and `rust-core/` for hot-path allocations, quadratic loops, unnecessary copies. Headline: the codebase is "unusually perf-disciplined" — narrow observation, per-tab caches, borrowed wire decode. Remaining wins are "second-order": FFI double-copy (7 sites), per-element allocations in tokenize/render loops, one O(N) ObjC message-send in line-number ruler, status-bar memory timer unconditionally publishes every 1.5 s, cross-file search is single-threaded. Status: **current** — findings are grounded; #1 (FFI double-copy) is the highest-leverage remaining win; #2–#5 are measured/obvious with low effort.

- **learnings:**
  - **The recurring pattern is per-element work inside document-scale loops** — String per token, per run, per char, per response frame. Individually small; in aggregate, the bulk of what's left.
  - **The FFI boundary (#1 and #11) is the highest-leverage area** — every ported engine (find, markdown, transcript, highlight) funnels through it; a copy saved at the seam is a copy saved for all.
  - **Status-bar metrics are cached smartly** (TTL cache on (url, byteCount/mtime)), but the memory sampler publishes unconditionally every 1.5 s even when unchanged.
  - **Nothing here is a correctness risk** — these are optimizations on a healthy base.
- **carry-forward:** PORT — the numbered findings and the prioritization method (impact × confidence × effort/risk matrix) are reusable. The specific findings are implementation-specific, but the audit discipline (read code on hot paths, tag measured/obvious/suspected, propose measurement plan) is portable.

**notes-swift-ui-render.md, notes-swift-core-parsers.md, notes-rust-core-ffi.md, notes-large-file-io.md** — deep notes per area. Status: **current** — support the synthesis above.

- **carry-forward:** DISTILL — the per-area categorization of good patterns (narrow observation, caching, borrowed wire decode, sweep-line paint-over, scalar-streaming parsers) and the anti-patterns (unconditional publishes, per-element allocations, O(N) message-send loops) are architectural patterns worth documenting for the greenfield.

---

### `swift-rust-additions-2026-06-19/` — Language/stdlib feature adoption survey

**README.md** — survey of Swift 6.0–6.3 and Rust 1.80–1.88 additions. Landed adoption: `Sequence.count(where:)` (11 sites in ViewerCore, avoiding allocating `filter{…}.count`). Recommended future: typed throws `throws(E)` at the FFI boundary (selective, not blanket), `package` access-level tightening. Rust side already on edition 2024 with compat lints on. Status: **current** — one foundation slice landed with tests; follow-ups filed.

- **learnings:**
  - **Top-left of the value/churn matrix is the only place to act** — `count(where:)` is high-value, low-churn; noncopyable/InlineArray/gen blocks are deferred (low value, high churn).
  - **Typed throws pay off selectively** — functions throwing exactly one concrete enum (RustCore FFI, small engines) where callers switch on cases. Don't blanket-convert functions propagating heterogeneous errors.
  - **Rust edition 2024 wins are *already adopted structurally*** — the migration compat lint is on; new action is mostly verification + opportunistic small-batch cleanup.
- **carry-forward:** DISTILL — the survey method (grep the tree for the pattern each feature replaces, count real sites, judge value vs churn) is reusable for a greenfield baseline. The specific recommendations are version/codebase-specific but the framework ("adopt the high-value, low-churn slice; defer the high-churn work") is durable.

---

### `rust-migration-plan-2026-06-13/` — Consolidated Rust migration roadmap

**PLAN.md** — synthesis of the 4-month migration (Stage A: engines to default-ON, Stage B: Swift-twin deletion, Phase F1–F6: contract finish, stateful tier, remote-core, hardening, WASM). Headline: **the migration is much further along than the framing implies**. All 11 stateless engines are ported, shipping default-ON, validated. The thin-waist FFI envelope is production. Remote `mdv-serve` daemon + `CoreTransport` seam exist and work. Open work: finish the contract (aux bulk side-channel), delete the Swift twins (owner-gated), land the DocId registry (TSK-583, stateful tier), hardening + WASM. Status: **current** — the plan is a finishing plan, not greenfield.

- **learnings:**
  - **The sans-IO discipline is load-bearing** — it is why remote is a carrier swap, WASM is nearly free, and every engine is deterministically A/B-testable. Every future port must preserve it.
  - **Thin-waist FFI is the leverage point** — one safe-Rust dispatch registry (`Method` enum) means adding a port = one enum arm + one Swift row, not a new extern symbol + codec.
  - **Measured parity is teeth** — each engine (find/markdown/transcript/fuzzy/hex/diff/csv) shipped with cross-language A/B parity suites + capability-bit pins on both sides.
  - **The remote tier is end-to-end real** — `CoreTransport` seam, `mdv-serve` daemon, duplex subscriptions, wire-boundary redaction. Engine remote, UI local is proven.
  - **The "approved but pending" four engines are validated and shipping** — TSK-630/631/632/633 (find/markdown/transcript/fuzzy) are all `validated`, not queued.
- **carry-forward:** PORT — the sans-IO discipline and the thin-waist FFI envelope design pattern are directly reusable for a greenfield Rust core. The contract foundations (ABI version, capability bitmap, error-model v2, windowed snapshot) are reference architecture. The phase sequencing (engine ports → twin deletion → stateful tier → remote completion) is a reusable roadmap template.

---

### `session-switch-perf-2026-06-20/` — Session-switch latency spike + ranked proposals

**FINDINGS.md** — code-level audit of the session-switch path. Headline: **pane retention is defeated by the shared DocumentModel drain + fresh Tab.id rebuild**. The incoming focused tab's WebView rebuilds from scratch every switch, re-paying ~94% of a rendered-MD open (per TSK-598). Four ranked proposals: P1a (stable tab identity), P1b (per-session DocumentModel, the durable fix), P1c (warm-WebView LRU above the model), P2 (move hydrate work off main), P3 (kill transient materialize), P4 (dedup snapshot work). Status: **current** — the grounded facts are solid; P1c (warm cache) landed; P1b (per-session model) is a design awaiting VM measurement.

- **learnings:**
  - **The session switch is dominated by WebView rebuild** (grounded: the retention is keyed by Tab.id, which is lost on switch). The TSK-598 measurement (WKWebView load ~94% of a rendered-MD open) is the proof point.
  - **Retention survives within a session (TabCoordinator LRU) but not across** — the model is shared; switch drains all tabs, LRU drops all panes, new tabs get fresh UUIDs.
  - **Hydrate work (sidebar setRoot, expansion readdirs) is on the main thread** — fs walks for git root discovery + transcript FS scan + per-dir readdirs scale with tree depth/breadth.
  - **Redundant snapshot/capture work happens 2–3× per switch** — equality-guarded so not wrong, but a constant-factor cleanup candidate.
  - **Measurement is blocked on the VM** — the proposed signpost intervals (session.switch, switch.drain, switch.hydrate, etc.) are the plan to get VM numbers before landing fixes.
- **carry-forward:** DISTILL — the problem diagnosis method (grounded facts from code, hypothesis from measurement gaps, measurement plan with signposts) is reusable perf-spike methodology. The per-session DocumentModel seam is a reference architecture decision (Phase 2 documented in the code; P1b is the design to prove it). The warm-cache win (TSK-1042, landed) is a pragmatic interim over a bigger refactor.

**P1b-per-session-documentmodel-design.md** — design for the durable session-switch fix. Per-session DocumentModel = each session owns its own model holding its tabs + WebViews, never drained on switch. Switch becomes a view re-bind to a different model. Blast radius is broad (model referenced pervasively). Migration plan is incremental (5 slices, each landable). Risk R1: memory (N live models = N live WebContent processes); mitigation = LRU of live models (default cap 1). Recommendation: measure warm-cache win first, then decide whether P1b is worth the blast radius. Status: **design-only** — awaiting VM measurement before owner sign-off on Slice 2+ (raising the live-model cap). 

- **learnings:**
  - **The seam is already documented in code** (SessionsAppCoordinator.swift:12-23 anticipates Phase 2). It is not a novel idea but a planned next step.
  - **The five slices are incremental and gating-friendly** — Slice 0 (introduce activeModel indirection) is a risk-free rename; Slice 1 (models registry with cap=1) maintains today's behavior. Win lands at Slice 2-3 (raise cap + swap ContentView binding).
  - **Memory is the trade** — six sessions × 4-pane LRU = lots of resident WebKit. LRU cap of live models (2–3 recent sessions hot, cold ones snapshot + rebuild) is the mitigation.
  - **The warm cache (TSK-1042, landed) is complementary** — path-keyed park/re-attach handles cold-model rebuilds. If warm cache collapses felt latency, P1b can stay a documented seam, not built.
- **carry-forward:** DISTILL — the "per-model" seam pattern (each session/document owns its own state object, switch is re-bind not drain) is a reusable architecture for multi-session/multi-document apps. The risks (memory, global state split, shared singletons) are the design checklist.

---

### `stateful-core-spike-2026-07-04/` — Stateful EditorSession registry and DocumentModel projection

**DESIGN.md** — design for the stateful core tier (TSK-583/1117). Verdict: **feasible as an 8-slice shadow-first migration**. `EditorSession` in core = CmDoc + saved-baseline hash + append-only op-log + meta. Registry = `CoreRuntime<EditorSession>`, `DocId(u64)`, never-reused handles, eviction under `EvictionBudget{max_bytes,max_count}`. Dirty ⇒ pinned (never evicted, owner rule). Mutation: CM6 deltas → `doc.apply_delta` → `ChangedRegion`. Undo stays in CM6 (battle-tested). Buffer authority: dual-doc, core is authority-of-record, CM6 is interaction surface (resolves TSK-1507 "separate editor vs live view" fork). Shadow-first via `MDV_RUST_DOCSTORE=shadow` (every CM6 delta mirrors to core; differential text-equality assert per debounce). Two supervised cutover moments: S5 (save-path authority swap) and S6 (DocumentModel/Tab projection cutover). Status: **design-only**, auto-approved lane; awaiting owner calendar for supervised sessions.

- **learnings:**
  - **The foundations exist in-tree** — CmDoc + delta apply + registry pattern + eviction budget + windowed snapshots + handle protocol. The missing pieces are the `EditorSession` type and the projection.
  - **Buffer authority is the fork resolution** — core is source of truth for persistence/remote/search; CM6 is the interaction surface. Keystroke hot path unchanged (no per-keystroke FFI).
  - **Shadow-first migration de-risks data-loss** — every change mirrors; differential assert has teeth; Swift path is deleted only after shadow validates.
  - **Eviction vs unsaved work is a law, not a code-path comment** — the pinned-dirty invariant is a property test (all-dirty + over-budget ⇒ zero evictions).
  - **Op-log provides durability + local-history + audit**, but interactive undo/redo stays in CM6 (zero-latency, correct UX grouping, battle-tested).
- **carry-forward:** PORT — the stateful registry pattern (`CoreRuntime<D>`, `DocId`, handle-based access, eviction budget) is reusable for multi-document editors. The buffer-authority seam (dual-doc, core as source, UI as surface) and the shadow-first validation pattern are directly applicable.

---

### `unified-version-diff-viewer-2026-06-20/` — Local history + git version viewer design

**README.md** — design for one unified version-history + diff viewer serving both Local History (snapshots on save) and Git history (commits). The rethink: generalize the existing `FileHistoryView`/`FileHistoryModel` (git-specific) into a `VersionSource` protocol so both back-ends conform. `VersionRef` is back-end-agnostic (snapshot id OR git SHA). Two new capabilities: `UnifiedDiffGenerator` (string→unified-diff text via line-based LCS, no deps); `GitClient.fileContent(rev:path:)` (missing git capability). `UnifiedHistoryView` is master-detail: version list, single/range selection, view-version OR diff-vs-current toggle, Restore button (undoable edit, not blind write). Shipped this pass: `VersionSource` + `VersionRef`, `UnifiedDiffGenerator`, LocalHistoryVersionSource + GitVersionSource, the VM + view-model. Deferred: migrate git UI onto the unified viewer (TSK-1191, separate ticket). Status: **shipped** — the Local History path is wired end-to-end; GitVersionSource conformance is adoptable immediately; git UI migration deferred.

- **learnings:**
  - **The seam is existing, just generalized** — `FileHistoryView`/model are already the shape the owner wants (list + select + diff pane). The rethink is replacing "git-specific data calls" with "a VersionSource protocol." Reuse over reinvention.
  - **Round-trip tests (generate→parse→reconstruct) are teeth for a new component** — the LCS generator is new code; proving it emits exactly the unified-diff dialect the parser consumes is the guard.
  - **Local History is end-to-end now** — snapshot-on-save hook in editor save path; `DocumentModel.openLocalHistory(forTabID:)`; menu + context entry.
  - **Restore is undoable (edit, not write)** — coordinates with the normal save flow; Cmd-Z works; snapshot-on-save captures the restored content.
- **carry-forward:** DISTILL — the `VersionSource` protocol pattern (back-end-agnostic interface for two conformances: LocalHistory, Git) is a reusable design for multi-source viewers. The "round-trip test" pattern (generate→parse→reconstruct) is a useful testing discipline for new codecs/serializers.

---

## Key Learnings from This Batch

### Testing & Validation Discipline

1. **Tier-is-the-type enforcement** (TIER-JUSTIFY convention, base-class hierarchy, TierGateObserver) closes a silent-regression hole where heavy tests can slip into the headless gate undetected.
2. **The "real screen" line is between layout-commit and WindowServer pixels** — T2-px (offscreen raster) is structurally blind to compositor bugs. The #1 regression-catching tier is T1m (headless @MainActor model observation), not T5 (live window).
3. **Headless first, UI as the residue** — the pyramid inverts from the naive assumption; the most valuable tests are the ones that *don't* require a window.
4. **Measurement gates guard against silent rot** — VM-only tests (T4/T5) need sentries to prevent bitrot in the absence of local repro. The `MDV_ENABLE_BROKEN_*` pattern codifies the negative-control discipline.

### Performance & Efficiency

1. **Measure before refactoring** — the profile flip (opt-z → opt-3) yields 1.6–4× with zero binary cost. Guessing leaves wins on the table.
2. **The FFI boundary is the leverage point** — every ported engine (find, markdown, hex, transcript, fuzzy, diff) funnels through it; a copy saved at the seam saves for all.
3. **Per-element allocations in loops dominate remaining perf** — not micro-opts but structural fixes (borrow-based snapshot, no-alloc case-fold, single-allocation frame encode).
4. **Redundant work happens more than expected** — snapshot/capture runs 2–3× per session switch; status-bar timer publishes unconditionally every 1.5 s; updateDerived fires N+1 times per switch.

### Rust Core & Architecture

1. **Sans-IO discipline is load-bearing** — it is why remote is a carrier swap, WASM is nearly free, and every engine is deterministically testable. Must be preserved in every new port.
2. **Thin-waist FFI is the leverage point** — one safe-Rust dispatch registry means adding a port is one enum arm + one Swift row, not a new extern symbol + codec.
3. **Stateful tier (DocId registry, `CoreRuntime<D>`) is the next unlocking force** — it closes the UAF/double-free class, enables remote stateful docs, and removes the need for raw pointers.
4. **Measured parity is teeth** — every engine shipped with cross-language A/B suites + capability-bit pins on both sides. The corpus is reusable as a regression gate.

### Architectural Patterns

1. **Per-model/per-session state ownership** (Phase 2 seam) is a durable fix for multi-document apps. Switch becomes re-bind, not drain + rebuild. The blast radius is broad; measure before committing.
2. **Buffer authority (dual-doc, core is source, UI is surface)** resolves the edit-vs-live-view fork. Keystroke hot path unchanged; reads that matter (save, search, remote) come from core.
3. **Shadow-first migration de-risks data-loss** — mirror every change, differential assert, delete only after validation. The discipline is stricter than a feature flag.
4. **VersionSource protocol** (back-end-agnostic interface for multi-source viewers) is a reusable design. Round-trip tests are teeth.

---

## Decision Records Found

| Decision | Date | Rationale | How It Played Out |
|---|---|---|---|
| **Tier-is-the-type + TIER-JUSTIFY guardrail** | 2026-05-31 | Implicit tier (target + filename + env gate) lets regressions slip. Enforce tier at the type level so it's opt-up. | Shipped; the merge gate now refuses heavy tiers in the headless sweep (TierGateObserver + `#192` gate + tier bases). Regressions still happen (the live-WebView mis-base was a gap), but the seam is in place. |
| **Stay XCTest, allow Swift Testing for NEW pure-logic only (after pilot)** | 2026-06-13 | Wholesale migration is churn; the gate observer is XCTest-bound. Pilot one suite to confirm mixed targets parse correctly and gate still arms. | Deferred; no pilot ran. The recommendation is still valid and de-risks future adoption. |
| **Opt-level 3 on dist (not z)** | 2026-06-05 | Measured: 1.6–4× speed, zero binary cost. Owner priority is latency first. | Shipped; every hot path saw real speedup (CSV, hex, wire). |
| **Rust ports are default-ON, Stage A complete** | 2026-06-13 | Eleven engines (csv/diff/hex/find/markdown/fuzzy/transcript/indent/cmEdit/hexSearch/highlight) validated, parity-proven, no regressions. All stateless work routes Rust; Swift twins are fallback-only. | Shipped; Stage B (twin deletion) is owner-gated, awaiting soak confirmation per engine. Remote tier proved to work; stateful tier (DocId registry) is the next unlock. |
| **Phase 2 seam: per-session DocumentModel** | 2026-06-20 (design) | The shared model drain defeats pane retention on switch. Durable fix: each session owns its model, switch is re-bind. Blast radius is broad; measure warm cache first. | P1c warm cache shipped; P1b design documented; awaiting VM measurement before owner sign-off on raising the live-model cap. The seam is already anticipated in code; P1b is the plan, not a surprise. |

---

## Portable-Artifact Candidates

### Direct Ports (use nearly verbatim)

1. **Testing tier model + TIER-JUSTIFY guardrail** (`testing-strategy-2026-05-31/TESTING_STRATEGY.md`)
   - The T1/T1m/T2'/T2-px/T4/T5 layer model
   - The "tier as base class" + "TIER-JUSTIFY convention" enforcement pattern
   - The headless-first pyramid (T1m is higher-value than T5)
   - Applied to the greenfield Swift UI + Rust core + TUI + WASM tiers

2. **Rust core sans-IO discipline + thin-waist FFI** (`rust-migration-plan-2026-06-13/PLAN.md`)
   - The `forbid(unsafe_code)` + no-IO enforcement + `clippy::disallowed_methods` pattern
   - The safe-Rust dispatch registry (Method enum) + cbindgen codegen'd method ids
   - Contract foundations: ABI version, capability bitmap, error-model v2, windowed snapshot, handle protocol
   - Applied to greenfield core from day 1

3. **Stateful registry + DocId pattern** (`stateful-core-spike-2026-07-04/DESIGN.md`)
   - `CoreRuntime<D>` + `DocId(u64)` + never-reused handles
   - Eviction budget policy + pinned-dirty invariant + law-test discipline
   - Buffer authority seam (dual-doc, core is source, UI is surface)
   - Applied to multi-document editors in greenfield

4. **Performance audit discipline** (`source-perf-audit-2026-06-14/SYNTHESIS.md`)
   - The "measure don't guess" signpost-based profiling method
   - Per-area categorization of good patterns (narrow observation, caching, borrowed codecs, scalar-streaming parsers)
   - Numbered findings + impact/effort/risk matrix for prioritization
   - Applied to greenfield from day 1

5. **Perf quick-wins catalog** (`rust-perf-2026-06-05/README.md`)
   - Build-profile impact (opt-z vs opt-3): 1.6–4×
   - Per-element allocation patterns to avoid (String per cell/token/char, double-copy at FFI boundary)
   - Borrow-based encoding as a seam principle
   - Applied to greenfield build config + core design

### Distill (idea worth carrying)

1. **Audit method: read-only tier inventory** (`test-stack-audit-2026-06-13/FINDINGS.md`)
   - For each test file, read what assertions observe; categorize by tier; diagnose over-placement
   - Repeatable audit pattern for codebase health

2. **Per-session model seam** (`session-switch-perf-2026-06-20/P1b-per-session-documentmodel-design.md`)
   - Each session owns its model, switch is re-bind, not drain
   - Documented Phase-2 seam; design is reference architecture
   - Adoption decision: measure warm-cache win first, then decide if full P1b is worth the blast radius

3. **VersionSource protocol pattern** (`unified-version-diff-viewer-2026-06-20/README.md`)
   - Back-end-agnostic interface for multi-source viewers
   - Two conformances (LocalHistory, Git) from same code shape
   - Round-trip tests (generate→parse→reconstruct) for new codecs

4. **Language-feature adoption survey method** (`swift-rust-additions-2026-06-19/README.md`)
   - Grep the tree for the pattern each feature replaces; count real sites; judge value vs churn
   - Top-left of value/churn matrix is the only place to act
   - Applicable at greenfield baseline and periodically (e.g., annually)

5. **Shadow-first migration pattern** (`stateful-core-spike-2026-07-04/DESIGN.md`)
   - Mirror every change; differential assert has teeth; delete old path only after shadow validates
   - De-risks data-loss; discipline is stricter than a feature flag
   - Applicable to any major core restructuring

### Skip (too specific or superseded)

- Unprimed research files (research-ui-pyramid-firstprinciples.md, etc.) — the synthesis in TESTING_STRATEGY is the payload
- Test-stack-audit depth > findings — the finding (no coverage measurement, mis-based WebView suites) is the lesson; the inventory itself is specific to this codebase

---

## Recommendations for Greenfield Application

1. **Tier discipline from day 1:** Adopt the T1/T1m/T2'/T2-px/T4/T5 model + tier-as-base-class + TIER-JUSTIFY convention from the start. The cost of retrofitting tier enforcement is high (this batch cost weeks of cleanup).

2. **Sans-IO core from day 1:** Enforce `forbid(unsafe_code)` + no-IO + `clippy::disallowed_methods` in the Rust core. This is the load-bearing invariant for remote, WASM, and deterministic testing.

3. **Thin-waist FFI envelope:** Use the safe-Rust dispatch registry pattern (Method enum, cbindgen codegen'd method ids) from the first port. It scales to 11+ engines and pays off immediately.

4. **Measure before refactoring:** Signpost all hot paths early. The opt-level profile flip and per-element allocation patterns are wins that compound; measure to prioritize.

5. **Tier audit checklist:** At greenfield grooming / pre-release, audit the test tree by tier. The "read what each test asserts" method is repeatable and inexpensive.

6. **Per-session/per-document seam:** Design the architecture to support per-document model/state ownership from day 1 (even if not needed immediately). The Phase-2 seam for markdown_viewer cost weeks of retrofitting; make it day-1.

7. **Shadow-first for risky changes:** When major core restructuring is needed (e.g., stateful tier, buffer authority swap), use shadow-first migration with differential asserts. The discipline is stricter and de-risks data-loss.

---

**Prepared:** 2026-07-11  
**Batch:** 3/3 (docs research, 9 directories, 23 markdown files)  
**Covered:** 2026-05-31 through 2026-07-04  
