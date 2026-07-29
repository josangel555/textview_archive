# Archive Tracking & Process Learnings — Greenfield Summary
**Source batch:** `archive/tracking-2026-06-22/` + `archive/research/` + BACKLOG archives
**Extracted:** 2026-07-11

---

## Document Inventory

### Research: Rust Production & Ecosystem (2026-05-30)
**Status:** FOUNDATIONAL; validated via crate-health verification (May–June 2026)

**archive/research/rust-production-and-ecosystem-2026-05-30/README.md** — Cross-cutting synthesis of 13 per-dimension research reports + crate-health verification
- **Learnings:**
  - **From-the-get-go production checklist (Tier 0):** panic strategy + FFI firewall; error-type architecture (hand-rolled enums, not `anyhow` in the library); time injection (ban `Instant::now()` in the core); on-disk format versioning (magic headers, tolerant deserialize); breaking-change insurance (`#[non_exhaustive]`, `cargo-semver-checks`). These are **impossible to retrofit** later.
  - **Tier 1 cheap-now-awkward-later:** `tracing` facade (emit-only, never install subscriber in core), panic-hook record capture, diagnostic snapshots (pure `fn` over state), panic-lints as policy (`forbid(unsafe_code)`, `deny(clippy::unwrap_used)`), secrets/PII as types (`secrecy::SecretBox`), supply-chain gates (`Cargo.lock`, `cargo-deny`, `cargo-audit`).
  - **Cross-org convergence:** sans-IO synchronous core (quinn-proto, str0m, rust-analyzer, Dropbox); unsafe confined to audited edge (Google ~4%, Microsoft 2019 rule); type-system-enforced invariants (Stylo parallelism); CI gate from commit one (clippy -D, nextest, semver-checks); async strictly at I/O edge (Tokio only for I/O-bound, not CPU-bound document cores).
  - **Non-obvious DON'Ts:** don't transfer ownership across FFI (different allocators = disastrous); don't pass non-POD types by value; don't read C-set integers as Rust enums; don't make FFI chatty (aim for ~10 coarse functions per component); don't reach for `Rc<RefCell<T>>`; don't trust strictness as force field (Google CVE-2025-48530 was safe-ish Rust with allocator guard pages); don't over-genericize (monomorphization blowup); don't expect telemetry forgiveness (desktop telemetry must be opt-in default-off).
  - **Retrofit cost patterns:** color-baked errors in library raise blindness across 4 embeddings; format untagged → classic prod incident; unsafe-free mandate late = weeks of cleanup; clippy adoption late = "demoralizing".
- **Carry-forward:** PORT — these decision tables + the Tier 0/1/2 checklist + the ecosystem patterns are immediately applicable to greenfield Rust work.

**ecosystem-learnings/02-agentic-rust.md** — What helps an agent produce correct Rust (21.2% → 28.6% on Rust-SWE-bench with scaffolding)
- **Learnings:**
  - **Rust inverts into agentic advantage:** `cargo check` + `clippy` + trait solver form a tight machine-verifiable loop that mechanically rejects unsound output before review. This is the strongest reason Rust suits agents.
  - **Agent failure modes (quantified):** 43.7% of compile errors = failure to model repo-wide structure (module/namespace resolution); 32.6% = violating type/trait semantics; 44.5% of repo-level tasks fail at reproduction stage. Reproduction/observability beats model quality.
  - **Mitigation structure:** many small crates + small files (keeps working set in context), strong types + small APIs (constrains what agent can write), trivial reproducibility (sans-IO pure functions + automated test workspace + runtime tracing = 71.3% of framework's successful fixes used dynamic tracing).
  - **Policy enforcement:** agents obey compiler far more reliably than prose — `#![forbid(unsafe_code)]`, `#![deny(clippy::unwrap_used, expect_used)]`, centralized `[lints]` in `Cargo.toml`, `cargo clippy --all-targets -D warnings` in CI are the enforcement gates.
  - **Gotchas:** `.clone()` spam / `Arc`/`Rc` to escape borrow-checker compiles and passes tests but silently accretes allocations (compiler won't flag; human review must catch); older models fix lifetime errors by adding random annotations (current models better but not immune); agents silence compiler with stray `unsafe` (only `forbid(unsafe_code)` reliably guards); agents hallucinate crate versions (pin explicitly, gate with `cargo-deny`/`cargo-audit`); IDE tools sometimes ignore context-loaded rule files — CLI agents respect them more consistently.
- **Carry-forward:** PORT — the agentic-Rust playbook (lint-as-policy, small crates, contracts/invariants, cargo check + nextest loop, structured diagnostics) is a proven pattern to build in day one.

**production-mechanisms/ (6 files)** — Logging, telemetry, crash reporting, debug mode, testing, other mechanisms
- **Learnings:**
  - **Logging:** `tracing` 0.1.44 + `tracing-subscriber` ≥0.3.20 (RUSTSEC-2025-0055 floor) + `tracing-appender` for persistence; structured fields (`info!(doc.bytes = n, "opened")`); core emits, host installs subscriber. Don't set `release_max_level_*` in core.
  - **Crash reporting:** `std::panic` + `std::backtrace` (zero deps); panic-hook + offline symbolication covers the common case first; defer in-process minidump capture until native crashes become a support burden; don't use `sentry` in core (heavy + panics only); for WASM, `console_error_panic_hook` + JS host detects `RuntimeError` and recreates instance.
  - **Testing Tier 0:** `cargo-nextest` (per-test isolation, retries, slow-test timeouts) day one; property testing with `proptest` + persisted failing-seed corpus; parser fuzzing with `cargo-fuzz` (fuzzing early compounds corpus value; late fuzzing forfeits it); FFI layout verification via `ctest` (not `ctest2`, which is winding down) + `cbindgen` checked-in and CI-diffed; snapshot tests with `insta` + `CI=true` so CI fails on drift.
  - **Mutation testing:** `cargo-mutants` diff-scoped in CI (not whole-tree); slow if unscoped; coverage % lies; mutants tell whether tests *assert*.
  - **Dual-profile CI:** debug + release-like (overflow-checks + debug-assertions) catches UB at your callsites via std's unsafe-precondition checks (since Rust 1.78).
  - **Supply-chain gates:** `Cargo.lock`; build `--locked`; `cargo-deny` + `cargo-audit` on first green CI; `cargo auditable`; `--remap-path-prefix`; pin exact versions (agents hallucinate).
- **Carry-forward:** DISTILL — the production mechanisms (esp. Tier 0 panic+error+time+format+breaking-changes) are foundational; the testing strategy (no `#[should_panic]`, no `#[ignore]`, contracts + props + fuzz) is a high-ROI pattern.

### Tracking Documents: Board & Process Evolution (2026-05-30 through 2026-07-07)
**Status:** SUPERSEDED (these were consolidated into single BACKLOG.md + tasked board at live :8787); process insights remain valid

**BOARD_CUT_DEDUP_PROPOSAL_2026-06-19.md** — Board dedup/cut homework (TSK-780)
- **Learnings:**
  - **Board hygiene discipline:** stale-lease zombies (11 items in `progress` with expired leases from weeks-old agent runs = false "in-flight" signals) must be reset to `reported`/`ack` rather than silently clogging; true duplicates (5 pairs where two rows describe identical work) deserve a canonical keeper + dup dismissal (not merge); over-decomposed clusters (multi-sibling rows implementing one feature together) should merge children under parent epic.
  - **Aspirational/vague items:** `very-large` with no design/slice/path → demote to single icebox epic so they stop padding active count; vague stubs (one-word titles with no content, e.g. "Markdown" without context) → restate concretely or cut; already-decided `wontdo`/`parked` → confirm-close so they leave actionable view.
  - **Off-board:** internal tracker-feedback tasks (about the tasked tool itself, not the app) belong to the `internal` project, not the markdown_viewer board.
  - **Net proposal:** 134 actionable rows → 107 (−27 rows) via legitimate cut/dedup/merge, zero loss of real intent.
- **Carry-forward:** DISTILL — board hygiene as standing discipline: reset expired leases regularly; merge true dups and over-decomposed clusters; icebox aspirational; close decided items. This keeps the active pool scannable and honest.

**FEATURE_BACKLOG_AUDIT_2026-06-05.md** — Feature audit against code (373 items classified)
- **Learnings:**
  - **Conflicting items:** 6 items directly contradict the design mandate (e.g., code runner conflicts with read-only viewer mandate; xterm.js conflicts with the shipped custom native PTY). Owner must arbitrate these explicitly.
  - **Not-needed items:** 4 items are superseded by shipped work (PoC plugins, walkthrough, MCP all shipped to v1; no need to keep "PoC" rows open).
  - **Not-possible items:** 1 item (iOS Notes/iCloud reader) is outside the macOS-only architecture.
  - **Extremely-ambiguous items:** 21 items lack actionable specificity (bare section headers like "Filenav" when filenav already exists fully; underspecified asks like "Tokens" could mean JWT decode, token counting, or random generation; open-ended research prompts like "Explore more what we can do in headless mode").
  - **Duplicates:** 6 items are substantively identical to existing work (e.g., "Mini VS Code type" + "Sublime type" + "VS-Code-like core" are the same aspiration).
  - **Ownership signal:** this audit revealed a **gap in owner intake process** — the braindump contained contradictions, aspirations, and vagueness that should have been triaged to owner decisions BEFORE filing on the board.
- **Carry-forward:** DISTILL — process: owner braindump should be run through a "audit against code + flag contradictions/ambiguities" gate BEFORE tickets are filed. This prevents duplicate/vague/aspirational rows from inflating the board.

**BACKLOG_historical_2026-06-22.md, CURATED_TASKS_2026-06-19.md, WORK_QUEUE.md** — Superseded tracking docs
- **Learnings:**
  - **Consolidation rationale:** tracking scattered across multiple files (CURATED_TASKS, WORK_QUEUE, HANDOFF, periodic snapshots) becomes a maintenance burden. Single BACKLOG.md + live tasked board is the system of record; documents are human-readable index + context only, not mutable source.
  - **Lane discipline:** `reported` → `ack` → `triaged` → `progress` → `fixed` → `review` → `validated` → `done`. Agent completes to `fixed`; owner validates to `done`. Leaving items in `progress` with no movement signals stalled work.
  - **Gating tags:** `[render-VM]` = must build + validate on the VM; `[host]` = host-gate-completable; `[owner]` = awaits owner decision; `[built→flip]` = done, gated off. Tags guide work routing.
  - **State reconciliation:** a periodic audit of board vs code (2026-06-19, 2026-06-29) catches items marked `done` that are actually open, `progress` that is stalled, and items that became obsolete.
- **Carry-forward:** DISTILL — single-source tracking (board + one backlog doc) + state reconciliation sweeps + gating tags are the hygiene pattern.

**HANDOFF_2026-05-30 through 2026-06-06.md** — Session handoff snapshots (superseded by HANDOFF.md in repo root)
- **Learnings:**
  - **Handoff format:** context budget (12 KB cap enforced), state of record (not a log), re-injected post-compaction; durable docs (BACKLOG.md, LESSONS.md) survive the document; memory pointers for institutional knowledge.
  - **Transition signals:** when handoffs grow beyond budget or sessions are ending, extract durable learnings into LESSONS.md, file new tickets on board, write HANDOFF.md with re-orientation pointers, then `/compact`.
- **Carry-forward:** PORT — the handoff discipline (12 KB cap, durable docs, memory pointers, re-orientation before compact) is directly portable to greenfield work.

**NEXT_30_TASKS_2026-06-18.md** — Priority queue snapshot (superseded by BACKLOG.md §THE 200-QUEUE)
- **Learnings:**
  - **Queue shape:** ~200 items ranked P0 (felt bugs + perf) through P2 (internal/rust/test). Explicit TIER 0 (Fable/XL only, get-right-first-time) + numbered slices (#1–10 finish-in-flight, #11–19 stage-B twins, #20+ feature tails).
  - **Work-loop mandate (2026-07-07 refinement):** pull 5–15 **related** items as ONE batch → implement code + unit tests in one go → ONE full gate pass → batch higher-order tests (WV/AX/T4/T5) only if batch changed render → ONE commit per batch → board records as batch. Do NOT babysit one change per gate/commit.
  - **Discipline:** blocked item ⇒ park it, take next. No "all work is done" stops; always pull from the board. One backlog per agent.
- **Carry-forward:** DISTILL — batch-work-loop discipline (5–15 related items, one gate, one commit) is a proven efficiency pattern. The 200-queue structure (P0/P1/P2 + TIER 0 + numbered slices) is a useful template.

**BACKLOG_archive_2026-07-07.md** — Final consolidated BACKLOG state (most comprehensive)
- **Learnings:**
  - **VM availability flip (2026-06-29):** when VM came online, the entire `[render-VM]` queue became active work, NOT a held tail. This unlocked build + validate on real hardware for UI/render items (T4 `LiveAppTestCase`, T5 pixel tests, WebView suites). The mandates: build on VM, run UI tests on VM, never on Mac host (host stays window-free).
  - **Owner-gated decisions:** explicit unblocks required for TSK-838 (DOM-patch flip), TSK-1215 (formula flip), TSK-1202 (fold flip), TSK-1129 (LSP RCE-guard enforcement: prompt-first vs block-default), TSK-543 (cm_apply redesign). These are architectural/product decisions, not agent-implementable.
  - **Landed-but-parked work (usability drain):** TSK-1411 tree drained 25 batches + 37 ticks; everything persisted on branches (`worktree-wf_dadf7ab6-e88-{1..9}`). Resume via TSK-1506 (branch↔ticket map + rebase→gate→ff recipe). Worktree dirs reaped; branches kept for recovery.
  - **Rendering-stack policy (owner-ratified 2026-07-04):** "web for content, native for chrome, brain in Rust" — CSS/JS paid for by CM6 editor; migrations (git diff, CSV, XLSX, hex, transcripts, git history) move to WebView + Rust backend (TSK-1524 epic M1–M9). AntiElectron guard (TSK-1534) prevents creep.
  - **Rust-core commitment breakdown (filed 2026-07-04):** "do all" (TSK-775) had no breakdown. Filed TSK-1508 (stateful-core spike entry point) + TSK-1509–1512 (domain placeholders: LSP, Git, Sessions, Automation) + TSK-1513 (roadmap revision) + TSK-1514 (umbrella reconcile). These govern the phase-in schedule + owner gates.
  - **Board size discipline:** ~1658 total; ~417 await owner close (review + fixed). Agent-complete items in `✅ DONE` section; active queue is P0/P1/P2 (numbered slices). Gating tags route work; tasked board is the system of record.
  - **Coverage state (2026-06-29):** 69.74% region / 64.72% line (host); uncovered = render UI (VM-tested); pure-logic comprehensive. Snapshot: `archive/BACKLOG_archive_2026-06-27.md`.
- **Carry-forward:** PORT/DISTILL — the final state doc (board size, owner decisions, work-loop discipline, VM mandate, rendering-stack policy, rust-core scope) is the authoritative snapshot for greenfield setup; owner flips and scope boundaries are the key decision records.

**BACKLOG_batches_2026-07-07.md** — Batch-work-loop execution summary (supplementary)
- **Learnings:**
  - **Batch sizes:** 25 batches completed; typical size 5–15 items per batch. Clusters (image editor, terminal, menus, sessions) batched as related work. Single commit per batch; one gate pass.
  - **Discipline:** no inline ad-hoc work; everything pulled from the board. Blocked item ⇒ `task_park` with context, take next. One ticket per batch (all TSK ids in message + session trailer).
- **Carry-forward:** DISTILL — batch execution discipline (pull from board, no inline work, one commit per batch) is the enforcement pattern.

---

## Key Learnings by Category

### Process Evolution & Discipline

**Board Hygiene**
- Single source of record (`tasked` board at localhost:8787) + one backlog doc (BACKLOG.md) is the model. Scattered tracking docs create maintenance burden.
- Stale-lease zombies (items in `progress` with expired leases from dead agent runs) must be reset regularly; they falsely signal "in flight."
- True duplicates, over-decomposed clusters, and aspirational items must be actively culled; the board accrues 30–40 rows per quarter that are noise without discipline.
- `[render-VM]`, `[host]`, `[owner]`, `[built→flip]` gating tags guide work routing; explicit lane discipline.

**State Reconciliation**
- Periodic audits (2026-06-19, 2026-06-29) catch board drift from code; items marked done but still open, stalled progress items, obsolete rows. Recommend quarterly sweeps.
- Feature audit against code (373 items, 6 contradicting / 4 not-needed / 1 not-possible / 21 ambiguous / 6 duplicates) revealed that owner braindump → board filing is a lossy process; audit BEFORE filing.

**Work-Loop Discipline**
- Batch-work-loop mandate (2026-07-07): pull 5–15 **related** items per batch → code + unit tests → ONE gate pass → ONE commit with all TSK ids + session trailer.
- No inline ad-hoc work; all work pulled from board. Blocked item ⇒ `task_park` with context, take next.
- No "all work is done" stops; always pull from backlog. One backlog per agent.

**Owner-Gated Decisions**
- Architectural/product decisions (DOM-patch flip, formula/fold flips, LSP RCE-guard posture, cm_apply redesign, rendering-stack policy, rust-core scope breakdown) cannot be agent-implemented; must be explicit owner calls.
- These are recorded as `[owner]` / `[built→flip]` items on the board with homework attached (design doc, comparison, rationale); owner flips trigger continuation.

### Rust Production Patterns

**From-the-Get-Go Checklist (Tier 0 — Impossible to Retrofit)**
- Panic strategy + FFI firewall (`panic = "unwind"`, `catch_unwind` on every `extern "C"`)
- Error-type architecture (hand-rolled enums, `thiserror`, not `anyhow` in libraries)
- Time injection (ban `Instant::now()` in core, inject as parameter)
- On-disk format versioning (magic headers, tolerant deserialize, compat upgrade)
- Breaking-change insurance (`#[non_exhaustive]`, `cargo-semver-checks`)

**Tier 1 — Cheap Now, Awkward Later (Wire During Initial Scaffolding)**
- `tracing` facade (emit-only, never install in core)
- Panic-hook record capture (while stack is intact)
- Diagnostic snapshot (pure `fn` over core state)
- Panic-lints as policy (`forbid(unsafe_code)`, `deny(unwrap_used, expect_used)`)
- Secrets/PII as types (`secrecy::SecretBox`)
- Supply-chain gates (`Cargo.lock`, `cargo-deny`, `cargo-audit`)

**Ecosystem Convergence (Every Large Shop Agrees)**
- Sans-IO synchronous core (quinn-proto, str0m, rust-analyzer, Dropbox, Microsoft)
- Unsafe confined to audited edge (Google ~4%, Microsoft policy unchanged since 2019)
- Type-system-enforced invariants (Stylo, Dropbox, Microsoft)
- CI gate from commit one (clippy -D, nextest, semver-checks, cargo-deny)
- Async strictly at I/O edge (never cargo-cult "tokio everywhere" into CPU-bound cores)

**Agentic Rust Setup**
- Agent failure modes: 43.7% structure (crate/module navigation), 32.6% type/trait semantics, 44.5% reproduction. Mitigate via many small crates + strong types + trivial reproducibility (sans-IO pure functions + automated test workspace).
- Encode policy as lints, not prose; agents obey compiler far more reliably than CLAUDE.md.
- Make compiler loud (`cargo check` inner loop, `--message-format=json`), lint enforcement hard (`[lints]` in Cargo.toml, CI -D warnings), reproducibility trivial (property tests, contracts, fuzz).

### Testing & Validation Strategy

**Tier 0 Testing Gates**
- `cargo-nextest` (per-test isolation, retries, slow-test timeouts, deterministic output)
- Property testing with `proptest` + persisted failing-seed corpus (compounds in value)
- Parser fuzzing with `cargo-fuzz` (early fuzzing compounds corpus; late fuzzing forfeits it)
- FFI layout verification (`ctest` 0.5.0 + `cbindgen` checked-in, CI-diffed; prefer `ctest` over `ctest2` which is winding down)
- Snapshot tests (`insta` + `CI=true` so CI fails on drift, not auto-write)

**Supply-Chain Gates**
- Commit `Cargo.lock`; build `--locked`
- `cargo-deny` + `cargo-audit` on first green CI
- `cargo auditable` + `--remap-path-prefix`
- Pin exact versions; agents hallucinate semver

**High-ROI Patterns**
- Mutation testing (`cargo-mutants` diff-scoped, not whole-tree) reveals whether tests *assert*, not just compile
- Dual-profile CI (debug + release-like with overflow-checks + debug-assertions) arms std's unsafe-precondition checks at your callsites
- Contracts (pre/post-conditions, invariants as test-build asserts) more effective than tests alone for AI-generated code

### VM & UI Validation (Render Lane)

**VM Availability Mandate (2026-06-29 Owner Correction)**
- When VM came online, entire `[render-VM]` queue became active, not held. Build + validate on real hardware (T4 `LiveAppTestCase`, T5 pixel tests, WebView suites).
- Host stays window-free; UI/render work is agent-workable on VM.
- Only off-limits lane is brand-new AX-based testing (TCC permission blocker).

**Rendering-Stack Policy (Owner-Ratified 2026-07-04)**
- "Web for content, native for chrome, brain in Rust"
- CM6 + rendered-markdown + Mermaid + Canvas are already browser-native JS (paid-for cost); migrations move read-only surfaces to WebView + Rust backend.
- AntiElectron guard (TSK-1534) prevents creep; cross-element selection (SelectionView) stays native.

---

## Decision Records

### Board Consolidation (2026-06-22)
**Decision:** Fold CURATED_TASKS, WORK_QUEUE, periodic HANDOFF snapshots into single BACKLOG.md + live tasked board.
**Rationale:** Scattered tracking files create maintenance burden, stale sync, and accidental-authoritative-document confusion.
**How it played out:** BACKLOG.md became system of record for humans (prioritized worklist, gating tags, owner decisions). `tasked` board at :8787 is system of record for task state (lifecycle, dates, comments). Post-2026-07-07, the 200-queue discipline (numbered slices, batch work-loop) made the split clear: humans read BACKLOG.md to scope; agents read board via MCP tools.

### Feature Audit → Board Intake Process (2026-06-05)
**Decision:** Run feature braindump through "audit against code + flag contradictions/ambiguities" gate BEFORE filing tickets.
**Rationale:** Braindump contained 6 contradictions, 4 not-needed items, 1 not-possible, 21 ambiguous, 6 duplicates (38 of 373 = 10.2% were effectively noise). Filing them straight inflated board by 38 rows of no-decision items.
**How it played out:** Feature audit became a standing pre-intake gate. Owner-facing intake now requires triaging contradictions + aspirations to explicit decisions before items hit the board.

### VM Availability Flip (2026-06-29)
**Decision:** When VM UI testing lane became operational (Screen Recording permission + xctest harness), open the entire `[render-VM]` queue as active work (not held pending owner).
**Rationale:** Host stays window-free; VM is where UI/render work is built AND validated. Only off-limits lane is new AX-driven testing (permissions).
**How it played out:** Unlocked ~50 render items from "pending VM" to active queue. Changed the pipeline: host-testable items + unit tests → one gate pass → batch render items → one VM validation run (not per-item). Efficiency gain: 1-2 weeks of calendar time per batch.

### Rendering-Stack Policy (2026-07-04)
**Decision:** "Web for content, native for chrome, brain in Rust" — CSS/JS paid for by CM6 editor; migrations (git diff, CSV, XLSX, hex, transcripts, git history) move to WebView + Rust backend.
**Rationale:** Avoiding Electron-creep; browser text stack already paid for; SwiftUI cross-element selection is structural native (SelectionView). Migrations planned as epic TSK-1524 (M1–M9).
**How it played out:** Gave a clear rendering boundary (content surfaces = web; chrome/menus/panes/modals = native) to eliminate vague requests like "make it more like VS Code." Decoupled rendering decisions from architecture debates.

### Rust-Core Scope Breakdown (2026-07-04)
**Decision:** "Do all" (TSK-775, move whole editor to Rust) had no breakdown. File spike + domain placeholders (LSP, Git, Sessions, Automation) + roadmap revision + umbrella reconcile before starting migrations.
**Rationale:** Large architectural commitment with no phase-in plan; agent runs need explicit entry point (TSK-1508 stateful-core spike) + sequenced slices (S-series) + supervised cutovers (S5/S6).
**How it played out:** TSK-1508–1514 filed; owner gates identified on critical path (soak-window number, formula display, eviction policy). Phase-in no longer speculative.

---

## Portable Artifacts & Patterns

### Day-One Rust Setup (PORT)
The production-mechanisms research + agentic-Rust playbook form a complete day-one kit:
1. **Panic strategy + FFI firewall** (explicit `extern "C-unwind"` posture, `catch_unwind` pattern)
2. **Error-type architecture** (hand-rolled `thiserror` enums, no `anyhow` in lib, structured causes)
3. **Time injection** (no `Instant::now()` in core; pass as parameter for determinism)
4. **On-disk format versioning** (magic header + tolerant deserialize + compat upgrade path; test the downgrade)
5. **`tracing` facade** (emit-only, never subscriber/hook in core; structured fields)
6. **Panic-lints as policy** (`forbid(unsafe_code)`, `deny(clippy::unwrap_used)`, centralized `[lints]`)
7. **CI gates from commit one** (`clippy -D`, `cargo-nextest`, `cargo-semver-checks`, `cargo-deny`)
8. **Contracts + property tests** (invariants as runtime asserts + `proptest` for reproducibility)
9. **Agentic structure** (many small crates, strong types, sans-IO pure functions, JSON diagnostics loop)

### Board Hygiene Playbook (PORT)
1. **Reset expired leases regularly** (monthly sweep); they falsely signal "in flight"
2. **Merge duplicates + over-decomposed clusters** (true dups get canonical keeper; siblings under parent epic)
3. **Icebox aspirational items** (demote `very-large` with no design/slice to single epic; don't count against active queue)
4. **Audit braindump before filing** (flag contradictions, ambiguities, not-needed; owner triages to decisions)
5. **Gating tags guide routing** (`[render-VM]`, `[host]`, `[owner]`, `[built→flip]`; explicit lane assignments)
6. **Reconcile quarterly** (board vs code audit; catch stalled/obsolete/done items)

### Work-Loop Discipline (PORT)
1. **Batch 5–15 related items** as one unit (not one-off ad-hoc)
2. **Implement code + unit tests** in one pass (minimal check interleaving)
3. **One full gate pass** for the batch (not per-item)
4. **Batch higher-order tests** (WV/AX/T4/T5) only if batch changed render behavior
5. **One commit per batch** (all TSK ids in message + session trailer)
6. **Board records as batch** (not itemized)
7. **Blocked item?** `task_park` with context, take next. No "all work is done" stops.

### Session Handoff / Compaction (PORT)
1. **HANDOFF.md** context budget: 12 KB (hard cap enforced); re-injected post-compaction
2. **LESSONS.md** durable learnings (process, gotchas, decisions; survives compaction)
3. **BACKLOG.md** standing worklist (human-readable, gating tags, owner decisions)
4. **Board** system of record for task state (via MCP tools, not manual edits)
5. **Memory pointers** in HANDOFF for institutional knowledge (links to key docs)
6. **Re-orientation before compact:** what happened this session? What's next? What's the state of decisions?

---

## Anti-Patterns & Gotchas

**Board Anti-Patterns**
- Leaving expired leases in `progress` (falsely signals "in flight"; reset to `reported` monthly)
- Filing contradictions/ambiguities directly (owner braindump → audit → decisions BEFORE filing)
- Keeping aspirational items as active rows (demote to icebox epic; they stop padding counts)
- Scattered tracking docs (single BACKLOG.md + live board is authoritative; documents are read-only index)
- Not tagging work with explicit lane assignments (gates become ambiguous; work routes incorrectly)

**Rust Production Anti-Patterns**
- `anyhow` in libraries (type-erases errors; every embedder loses ability to match; retrofit = large refactor across 4+ embeddings)
- Untagged on-disk format (untagged format + strict deserialize = classic prod incident day an old binary opens new file)
- Unsafe-free mandate adopted late (weeks of cleanup; day-one cost is low)
- `Rc<RefCell<T>>` reflexively (discards static aliasing guarantees; converts compile-time errors to runtime panics; is a smell ownership graph is wrong)
- FFI chatty API (defeats inlining; Servo perf regression; aim for ~10 coarse functions per component)
- Over-genericization (`impl Trait` / generics everywhere → monomorphization blowup: slower builds, bigger binaries)
- Telemetry opted-out (desktop telemetry backlash; must be opt-in default-off, show-the-payload, no pre-checked boxes)

**Agentic Rust Anti-Patterns**
- `.clone()` spam to escape borrow-checker (compiles, passes tests, silently accretes allocations; only human review catches)
- Agents hallucinating crate versions (pin explicitly; gate with `cargo-deny`/`cargo-audit`)
- IDE-based tools ignoring context-loaded rule files (CLI agents respect them; back conventions with enforced lints)
- Random lifetime annotations to "fix" errors (current models better; constrain via strong types + small APIs)
- Stray `unsafe` to silence compiler (only `forbid(unsafe_code)` reliably guards)
- Marketing claims ("58% of tasks, best of 9 languages") vs academic reality (Rust mid-pack SWE-bench Multilingual; ~21–30% on repo-level bugs)
- Line-count metrics ("100K lines in 4 weeks") without architectural coherence (HN flagged 1,300 tests for consensus engine as LOW; each later change takes longer)

---

## For Next Project: Setup Checklist

1. **Day-one Rust decisions:** commit panic strategy, error types, time injection, format versioning, breaking-change guards (Tier 0 checklist above)
2. **Agentic structure:** many small crates, strong types, sans-IO pure functions, `[lints]` enforcement, CI gates, property tests + contracts
3. **Board setup:** single BACKLOG.md, tasked board at :8787, gating tags, state reconciliation cadence (quarterly), feature audit gate before filing
4. **Work-loop discipline:** batch 5–15 items, one gate pass, one commit per batch, pull from board (no ad-hoc), `task_park` blockers
5. **VM validation:** when UI testing comes online, open render queue as active (not held); host stays window-free
6. **Rendering boundary:** decide "web for content vs native for chrome" early; codify in epic (e.g., TSK-1524 M1–M9)
7. **Owner-gated decisions:** scope the architectural decisions (panic posture, error arch, format versioning, rendering split, rust-core scope) up front; file as `[owner]` items with homework attached
8. **Session transitions:** HANDOFF 12 KB budget, durable LESSONS, memory pointers, re-orientation before compact

---

## Sources & Confidence

**Confidence: HIGH** on all learnings extracted

**Research docs verified via:** crate-health fact-check (May–June 2026); ecosystem sources corroborated (Mozilla, Microsoft, Linux, Google, Dropbox, rust-analyzer, Servo); agentic-Rust study (Rust-SWE-bench, RustForger 2026)

**Tracking docs extracted from:** live board via `mcp__tasked__task_list` (2026-06-19, 2026-06-29); FEATURE_BACKLOG_AUDIT 373-item classification; BACKLOG_archive final state (2026-07-07); batch-loop discipline records (25 completed batches)

**Process discipline verified via:** git log of landed commits (one per batch discipline); board reconciliation audits (board vs code catches drift); feature audit finding (10.2% of braindump was noise without audit gate)

---

*Report generated: 2026-07-11 · Archive batch size: ~27 files · Consolidated findings: 11 key learnings + 6 decision records + 4 portable-artifact categories*
