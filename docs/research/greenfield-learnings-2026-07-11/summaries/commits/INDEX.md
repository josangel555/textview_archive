# Commit-History Index — markdown_viewer greenfield run (3,733 commits, 2026-05-14 → 2026-07-10)

Aggregates 19 era reports (c-01of19.md … c-19of19.md), each covering ~197 sequential
commits (last slice 187), 100% coverage of the repo's commit history.

## Timeline of eras

| Slice | Commits | Date span | Era in a phrase |
|---|---|---|---|
| c-01 | 1–197 | 05-14 → 05-18 | Bootstrap sprint: skeleton→features in one day, compositor bug reworked twice, TreeSitter lands, first code-review wave |
| c-02 | 198–394 | 05-18 → 05-29 | Feature-epic staging: LSP v1, Sessions, CM6 phases; 20-fix correctness quality-gate day (05-25) |
| c-03 | 395–591 | 05-29 → 06-03 | Pre-launch audit & UAT campaign: 47-agent/172-finding fanout (G1–G14), Rust-core CSV FFI debut, testing-pyramid reframe |
| c-04 | 592–788 | 06-03 → 06-06 | UX overhaul + infra hardening: terminal/dockable windows/zoom audit alongside Rust-core Phase-A and 80-finding security audit |
| c-05 | 789–985 | 06-06 → 06-08 | Core-completion consolidation: pixel-test infra, security-coverage lane, VM harness build-out |
| c-06 | 986–1182 | 06-08 → 06-09 | Validation/closure wave: 62% doc-logging, VM UI-lane unblocked (TCC/ulimit/launchctl), audio synth lands |
| c-07 | 1183–1379 | 06-09 → 06-10 | Validation drain 7 + audit synthesis: measurement-first perf discipline, exact-closure UAT harness prerequisite |
| c-08 | 1380–1576 | 06-10 → 06-12 | Staged Rust-engine soak rollouts (A/A0/round2-4), continuous security integration |
| c-09 | 1577–1773 | 06-12 → 06-13 | Cohesive feature delivery + validation drain: perf pool close-out, feature sprint, VM sweep (4,942 tests) |
| c-10 | 1774–1970 | 06-13 → 06-14 | Docs-as-audit-trail (1.54:1 ratio); perf audit → targeted fixes; supply-chain gates land |
| c-11 | 1971–2167 | 06-14 → 06-19 | Feature velocity + infra maturation in parallel; zero reverts across 6 days |
| c-12 | 2168–2364 | 06-18 → 06-19 | Closure of the 6-week "Spring Platform Wave" (193/197 commits on one day): multi-window sessions, LSP rename/actions, FFI thin-waist envelope |
| c-13 | 2365–2561 | 06-19 → 06-21 | Shipping-phase feature blitz (image editor, export, viewers) with 69% doc overhead per feature |
| c-14 | 2562–2758 | 06-21 → 07-10* | Formula-engine port completion + differential fuzzing as production insurance (*slice spans a long tail) |
| c-15 | 2759–2955 | 06-22 → 06-27 | Production-readiness push: scroll-restore + UAT env-delivery crises root-caused, PM store vertical slice, AX automation framework |
| c-16 | 2956–3152 | 06-27 → 06-29 | Refactor sprint: DocumentModel SRP split (40 slices, 7542→5150 lines), test-hermeticity + 36x speed fix, rust-core proptest vein |
| c-17 | 3153–3349 | 06-29 → 07-02 | Render-drain + Canvas epic transition; costly 75-agent subagent-fanout lesson recorded |
| c-18 | 3350–3546 | 07-02 → 07-07 | Board-vs-code reconciliation audit (code found more complete than tickets); Canvas M0–M6 milestone slicing; 17 audit passes |
| c-19 | 3547–3733 | ~07-07 → 07-10 | Final phase: 25-batch cycle + 37-tick drain, crash-class audit, VM-first UAT with pixel-proof as default |

## Whole-history taxonomy

Aggregate commit-type shares (approximate — per-slice % is table-reported, not always
strictly summable due to differing categorization granularity across analysts):

| Type | Typical range across slices | Notes |
|---|---|---|
| `docs` | 16%–63% (mode ~45–56%) | Dominant category for 14 of 19 slices; almost entirely "log +N" progress entries, CHANGELOG pairings, handoff/BACKLOG checkpoints |
| `feat` | 13%–52% | Second-largest category everywhere; spikes to 45–52% in shipping-heavy slices (c-13, c-17, c-19) |
| `fix` | 3%–17% | Steady low-double-digit share; spikes during audit-response windows (c-04, c-18) |
| `test` | 1%–33% | Spikes hard in fuzzing/parity era (c-14: 33%) and refactor era (c-16: 24%) |
| `perf` | 0.5%–13% | Small but persistent; concentrated in dedicated perf-audit slices (c-01, c-07, c-10) |
| `refactor` | 0.5%–28% | Near-zero most slices; spikes to 28% in the dedicated c-16 SRP-extraction sprint |
| `merge`/`revert`/`chore`/`ci`/`build` | <5% combined | `revert` essentially never used (2 total across 3,733 commits — compositor c-01, signing c-03) |

**Docs-to-code ratio trend over time:**

```
c-01  ~0.7:1   bootstrap — moderate logging
c-02  ~0.25:1  lowest of the run — feature-epic focus, tests ship with code
c-03  ~0.5:1   audit fanout — doc load starts climbing
c-04  ~1:1     autonomous-run logging becomes heavy
c-05  ~0.3:1*  (*normalized ~1:1 once embedded progress-log entries counted)
c-06  1.7:1    validation/closure phase — logging dominates
c-07  ~1:1     steady heavy-logging plateau begins
c-08  1.3:1    ↑
c-09  1.2:1    ↑ (peak-adjacent)
c-10  1.54:1   PEAK — "docs as audit trail" era
c-11  0.94:1   pulls back — feature velocity outpaces docs
c-12  1.21:1   closure-day logging spike
c-13  ~0.69:1 (77 docs / 112 code) — shipping-phase, still doc-heavy per feature
c-14  ~0.18:1 (32 docs of 178) — code/test dominant, fuzzing era
c-15  0.82:1   (90 docs / 107 code) — SOP-codification bulge
c-16  0.30:1   BEST DISCIPLINE — bundled-docs pattern (79% folded into code commits)
c-17  0.35:1   Canvas epic — design-doc heavy but bundled
c-18  ~0.97:1  quality-sweep audit — near-1:1, intentional
c-19  0.48:1   FOLD-docs directive fully operational — zero standalone process-noise commits
```

**Reading the trend:** ratio climbed steadily from bootstrap (~c-01–c-03) through a
mid-project peak (c-06–c-12, driven by "log every item" autonomous-run discipline,
peaking 1.5–1.7:1), then **improved markedly in the back third** once the owner's
"fold docs into the code commit, don't create standalone doc-churn commits"
directive (2026-06-22) took hold — c-16 and c-19 show the ratio nearly halved
versus the mid-project peak, with c-19 explicitly noting "zero standalone
process-noise commits." The one late outlier (c-18, ~0.97:1) is a deliberate
17-pass quality-audit sweep, not a regression in discipline.

## The big rework arcs

Named cross-era rework/epic arcs, merged from per-slice findings:

| Arc | Subsystem | Commit volume (approx) | Verdict |
|---|---|---|---|
| **Compositor occlusion** | SwiftUI/AppKit layer ordering | 3 re-attempts (c-01) + TSK-488 9-commit rework (c-05) | Didn't-stick until pixel-level (WindowServer `screencapture`) regression test was mandated — became a permanent owner standard afterward. Root cause: in-process/ImageRenderer snapshots gave false-green. |
| **Scroll-restore timing race** | Session/tab restore, render pipeline | TSK-1046/1047 — 24 commits (c-15) | Didn't-stick for 3 patch attempts (sequencing side effects across an async chain); fixed permanently only by collapsing to a single source of truth (`tab.renderedScrollY` pull-based read) instead of more sequencing patches. Textbook "collapse the fragile chain, don't add a stage-patch" lesson. |
| **UAT env-delivery / harness crisis** | VM UAT automation (`open --env` under `sudo -u`) | TSK-1243 — 11 commits over 10+ VM round-trips (c-15); related VM-lane fragility scattered across c-06, c-07, c-14, c-17 | Didn't-stick via harness-level patching (probe timeouts, async-await bridges); fixed by a config-file side-channel bypassing the silent LaunchServices env-var drop. Broader pattern: ~24 commits (12% of one slice) went to harness introspection debugging — the app wasn't designed for synchronous observability. |
| **DocumentModel SRP extraction** | Core document model | 40-slice extraction, 7542→5150 lines (c-16) | Healthy epic — zero render regression across the full 40-slice decomposition; textbook incremental-slice-with-gate discipline. |
| **Rust-core engine ports** (CSV, hex, diff, formula, wire protocol) | Cross-language migration | Spans c-03 (CSV FFI debut) through c-14 (formula parity via differential fuzzing) — dozens of commits per engine across 6+ weeks | Healthy — staged soak rollouts (A/A0/round2-4, c-08), vertical vs. horizontal slicing (formula's 28 input-to-output slices, c-14), and parity fuzzing catching 5 silent bugs pre-ship. No thrashing; Swift-twin deletions in c-18 landed with zero reverts because the bridge + fallback was built first. |
| **Pre-launch audit fanout** | Security/correctness/reliability, 14 subsystems | 47 agents, 172 findings, 32 G1–G14 bulk-fix commits (c-03); recurs as 80-finding deep-audit (c-04), 17-pass quality sweep (c-18), crash-class audit (c-19) | Healthy pattern reused across the whole project — systematic severity-triaged batch response, not ad-hoc patching. Became the standard "audit cadence" tool. |
| **Canvas epic (agent-driven UI authoring)** | New subsystem, greenfield-within-greenfield | Giga-epic TSK-1342: design-spike fanout ballooned to ~75 subagents (c-17) before M0–M6 milestone slicing (c-18) | Mixed — the *research* phase was a costly process failure (~75-agent runaway, ~half a session's quota, became a standing "no broad subagent fanout" lesson); the *build* phase that followed (Rust-first, design-doc-locked, milestone×slice decomposition) was healthy and shipped cleanly. |
| **VM/UI test-harness bring-up** | T4/T5/AX validation infrastructure | Recurring investment across nearly every slice from c-01 (pixel-test genesis) through c-19 (pixel-proof as default) — TCC/ulimit/launchctl (c-06), AX catalog+driver (c-15), coverage-merge ARG_MAX (c-14) | Healthy but expensive — never a single clean landing; each new validation surface (webview, T4, T5, AX) needed its own multi-commit unblock. Treat as permanent infrastructure tax, not a one-time cost. |

## Process evolution

- **Doc discipline tightened mid-project, not at the start.** Early slices (c-01–c-03)
  had moderate, feature-paired documentation. A mid-project autonomous-logging mandate
  ("log every landed item") pushed the docs-to-code ratio to its 1.5–1.7:1 peak
  (c-06–c-12) — durable but heavy. The owner's 2026-06-22 "fold docs into the code
  commit, no standalone doc-churn" directive visibly took hold by c-16/c-19, roughly
  halving the ratio and eliminating standalone process-noise commits.
- **Audit-then-fix became a repeatable ritual, not a one-off.** The first large fanout
  audit (47 agents/172 findings, c-03) established the G1–G14 severity-batching pattern;
  it was reused nearly verbatim for the 80-finding deep audit (c-04), the 17-pass quality
  sweep (c-18), and the crash-class audit (c-19). By the end of the run, "run an audit,
  batch by severity, land per-subsystem" was muscle memory.
- **VM/render validation moved from "owner's lane" to "agent's lane."** Early slices treat
  UI/render bugs as something requiring hand-off; by c-12/c-18 the render-drain pool and
  pixel-proof harness (scene code + `screencapture`) made VM-validation agent-executable
  end-to-end, formalized later as explicit owner directives in CLAUDE.md.
  Headless/ImageRenderer snapshots were repeatedly proven insufficient (compositor
  occlusion false-greens) before this lane matured.
  matured.
- **Rust-core migration went from "spike" to "standing staged-rollout playbook."** CSV's
  FFI debut (c-03) was a first-of-its-kind monolithic scaffold commit; by c-08 the team
  had a named soak-stage pattern (A/A0/round2/3/4) reused for every subsequent port, and
  by c-14 differential fuzzing was baked in as a mandatory parity gate before ship.
  refactoring, features, or test backfill on ported Swift twins — subsequent slices
  reflect this ("bugfix-only" language appears from c-14 onward).
- **Ticket/board hygiene tightened late.** c-18 discovered the board was *understating*
  actual completion (code more complete than tickets claimed) — a "board ≠ code" trust
  problem that triggered a reconciliation audit. c-19's batch-loop (25 batches +
  37 drain ticks) shows the terminal state: tight, closure-gated iteration replacing the
  earlier looser "log everything and keep going" mode.
- **Subagent/workflow fanout got a hard lesson.** c-17's Canvas research spike
  recursively expanded to ~75 agents and burned ~half a session's quota — recorded
  immediately as a standing lesson ("never delegate broad research to general-purpose
  agents"), visible afterward in tighter, scoped fanouts.
- **Refactoring shifted from opportunistic to a dedicated sprint.** Most slices show
  refactor as a near-zero share; c-16 is the deliberate outlier (28.4%, the DocumentModel
  SRP split) — a scheduled architectural-debt sprint mid-project rather than continuous
  opportunistic cleanup, executed with zero render regression.

## Top learnings for the rebuild

1. **Establish pixel-level (real WindowServer) UI regression tests from day one**,
   not in-process/ImageRenderer snapshots — the compositor-occlusion bug recurred
   because headless and in-process snapshots gave false greens; only real pixel capture
   caught it, and became the permanent standard.
2. **When a timing/race bug survives 2+ patch attempts, stop patching stages of the
   async chain and collapse to a single source of truth** — the scroll-restore arc
   (24 commits) and UAT env-delivery arc (11 commits) both resolved only once the fix
   moved from "sequence the handoff correctly" to "eliminate the handoff."
3. **Fold documentation into the code commit it describes; avoid standalone doc-churn
   commits.** The mid-project 1.5–1.7:1 docs-to-code peak was real overhead; the
   back-third recovery (down to ~0.3–0.5:1) proves the fold-in discipline works and
   should be the default from the start, not a mid-course correction.
4. **Budget VM/render test-harness investment as permanent infrastructure, not a
   one-time setup cost.** Every new validation surface (webview, T4 live-app, T5 pixel,
   AX automation) needed its own multi-commit unblock (TCC, ulimit, launchctl,
   env-delivery, ARG_MAX) spread across the whole timeline — bring the harness up early
   and expect recurring maintenance tax.
5. **Run systematic, severity-triaged audits repeatedly, not once.** The 47-agent/
   172-finding fanout (pre-launch) was reused as a playbook at least three more times
   (80-finding deep audit, 17-pass quality sweep, crash-class audit) — schedule these as
   recurring checkpoints (e.g., every N features or before each release), not a single
   pre-ship gate.
6. **Stage risky cross-language/engine migrations with named soak steps and parity
   fuzzing**, not big-bang cutover. The Rust-core port pattern (A/A0/round2-4 soak +
   differential fuzz vs. Swift reference) caught 5 silent parity bugs that would have
   shipped otherwise; codify this as the standard port playbook up front.
7. **Cap subagent/research fanout explicitly.** An unbounded "explore this epic" research
   spike recursively grew to ~75 agents and consumed roughly half a session's quota;
   set a hard fanout ceiling (or single-pass/read-only) for exploratory research from
   the start.
8. **Slice features vertically (input-to-output) rather than horizontally
   (all-UI-then-all-logic).** Vertical slicing (formula's 28 slices, PM store's 14-commit
   vertical land) shipped with zero rework; horizontal layering elsewhere correlated
   with rework loops.
9. **Treat the task board as a live index, not a trust anchor — periodically reconcile
   against actual code state.** Late in the project the board was found to *understate*
   completion versus code; a code-first (not ticket-first) reconciliation pass should be
   a standing checkpoint, not a one-time surprise fix.
10. **Schedule refactors as deliberate sprints when architectural debt accumulates**,
    rather than only opportunistically — the one dedicated refactor sprint (DocumentModel
    SRP, 40 slices) achieved zero render regression precisely because it was planned and
    gated slice-by-slice, not squeezed in alongside feature work.

## Coverage note

All 19 slices analyzed; 3,733 total commits, 100% coverage. No failed slices — every
report on disk was read and incorporated. Total commits covered across the 19 reports:
197 × 18 + 187 = 3,733.
