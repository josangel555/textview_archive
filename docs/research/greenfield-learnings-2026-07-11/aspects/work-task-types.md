# Work & task types + board archaeology

Dimension: what kinds of work items existed in this project (feature/bug/regression/audit-finding/
infra/process/validation), their proportions and flow, and the board's structural pathologies.
Evidence-first — every claim below cites a report, commit range, or file.

Sources used: `summaries/commits/INDEX.md` (19 era reports, 3,733 commits), the c-18 era report
(board-vs-code reconciliation), `project-meta-analysis-2026-07-04/SYNTHESIS.md` (repo+board
archaeology), `TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md` (session-jsonl struggle ledger),
`BACKLOG.md` (current curated worklist + chunking/mandate structure), and `CLAUDE.md` (codified
lifecycle rules that emerged from these failures). Live board queried directly not performed this
pass — the 07-04/07-07/07-10 archaeology is < 1 week stale and the cap (~10 calls) buys little over
reusing three independent, convergent studies; this is noted as a limitation, not skipped for cost
alone.

## Taxonomy — distinct work-item types

1. **Feature / epic work (`feat`)** — 13%–52% of commits per era, second-largest category
   everywhere, spiking to 45–52% in shipping-heavy eras (c-13, c-17, c-19).
   Evidence: `summaries/commits/INDEX.md` whole-history taxonomy table. Concrete epics: the
   Rust-core engine ports (CSV→hex→diff→formula, spanning c-03→c-14), the Canvas epic
   (TSK-1342, M0–M6, ~3 months), DocumentModel SRP extraction (40 slices, c-16).

2. **Bug fix (`fix`)** — steady 3%–17% share, spiking during audit-response windows (c-04, c-18).
   Two structurally different sub-populations, per the repo-meta-analysis "re-fix loops vs epic
   buildouts" finding: **healthy additive epics** (TSK-1110 ×63 commits, TSK-1213 ×35, TSK-585
   ×26) vs **re-fix loops** (TSK-1046 ×13 — scroll-restore, wrong hypothesis repeated; TSK-1243
   ×21 — VM UAT harness iteration). Evidence: `project-meta-analysis-2026-07-04/SYNTHESIS.md`
   Finding 3.

3. **Regression / audit-finding work** — discovered in fanout audits, not organic bug reports.
   The pattern recurs at scale 4 times across the project's life: 47-agent/172-finding pre-launch
   audit (c-03, G1–G14 severity batches), 80-finding deep audit (c-04), 17-pass quality sweep
   (c-18), crash-class audit (c-19). Evidence: `summaries/commits/INDEX.md` "big rework arcs" +
   "top learnings" #5. Most recent instance: the 2026-07-09 pre-launch audit
   (`docs/research/prelaunch-audit-2026-07-09/`, ~30 dimension reports, 27 with real file:line
   evidence) triaged into 6 themes in `BACKLOG.md` (data-safety, crash/stability,
   security/control-surface, licensing/packaging, dead-render-tails, perf/UX/architecture) —
   this triage-into-themes step is itself a work-type: **audit-synthesis / dedup**, distinct from
   the raw finding.

4. **Infra / test-harness / validation-tooling work** — VM/UI harness bring-up recurs in nearly
   every era (c-01 pixel-test genesis → c-06 TCC/ulimit/launchctl unblock → c-14 coverage-merge
   ARG_MAX fix → c-15 AX catalog+driver → c-19 pixel-proof-as-default). Evidence:
   `summaries/commits/INDEX.md` "VM/UI test-harness bring-up" row: "never a single clean landing;
   each new validation surface... needed its own multi-commit unblock." This is a **standing tax
   type**, not a feature or a bug.

5. **Process / tracking / documentation work** — `docs` commits are the single largest category
   in 14 of 19 eras (16%–63%, mode ~45–56%), and were **36.5% of ALL 3,489 commits** as of
   2026-07-04, with 17% of the entire history being appends to one file
   (`docs/AUTONOMOUS_PROGRESS.md`, 1,031 touches). Evidence: `project-meta-analysis-2026-07-04/
   SYNTHESIS.md` Finding 1. This taxonomically splits into (a) legitimate design/decision docs,
   (b) compaction-survival apparatus (handoffs, progress logs — "the cost of having no durable
   execution substrate"), and (c) pure process-noise commits (the pre-2026-06-22 pattern of a
   standalone doc-only commit per logged item).

6. **Board reconciliation / meta-work** — a distinct, recurring work type: auditing the board
   itself against code reality. c-18's `42f61606` ("app-wide feature/usability/cohesion audit —
   foundation pass, code-first correction") discovered the board *understated* completion — wired
   features filed as missing UI. Evidence: `summaries/commits/c-18of19.md` lines 92, 140-141:
   "the tracking board had become a stale liability, listing 'missing UI' for features that were
   actually wired but undiscovered."

7. **Validation-drain work** — moving items already `fixed`/`review` to `done`/`validated`,
   distinct from producing new work. Named explicitly as its own loop mode ("batch loop + drain",
   25 batches + 37 drain ticks, c-19) and is where the board pathology below concentrates.

## What worked — practices that earned their keep

- **Severity-triaged batch audits, reused as a standing ritual.** The G1–G14 pattern from the
  first 47-agent audit (c-03) was reused near-verbatim 3+ more times through the project's life
  (c-04, c-18, c-19) and by the current `BACKLOG.md` (6 THEME clusters from the 2026-07-09 audit).
  Evidence: `summaries/commits/INDEX.md` top-learning #5; `BACKLOG.md` THEME 1-6 structure. This
  is the single most durable process pattern in the corpus — audit → dedup into themes → file
  per-theme tickets → batch-fix by severity, repeated at a cadence rather than once pre-ship.

- **Vertical epic slicing with a gate per slice.** DocumentModel SRP split: 40 slices,
  7542→5150 lines, **zero render regression** across the whole decomposition (c-16). Formula
  engine port: 28 input-to-output vertical slices with differential fuzzing as the parity gate
  (c-14), catching 5 silent bugs. Evidence: `summaries/commits/INDEX.md` rework-arcs table +
  top-learning #8. Contrast: horizontal layering (all-UI-then-all-logic) elsewhere correlated
  with rework loops (same INDEX.md learning).

- **Chunked batch-loop worklist (current state, `BACKLOG.md`).** A single owner-curated,
  priority-ordered backlog (replacing 5+ superseded dated tracking docs) grouped into 3–5-ticket
  CHUNKS that ship together with ONE gate + ONE commit + ONE shared evidence artifact. This
  directly targets two measured pathologies: doc-churn (folds CHANGELOG/HANDOFF/LESSONS into the
  chunk commit) and board-lifecycle overhead (walks the whole chunk through lanes together
  instead of per-ticket). Evidence: `BACKLOG.md` "★ WORK-LOOP MANDATE" section.

- **"Fold docs into the code commit" directive, once actually adopted, visibly worked.** Docs-to-
  code ratio fell from a 1.5–1.7:1 mid-project peak (c-06–c-12) to ~0.3–0.5:1 in the back third
  (c-16: 0.30:1, "79% folded into code commits"; c-19: 0.48:1, "zero standalone process-noise
  commits"). Evidence: `summaries/commits/INDEX.md` docs-to-code ratio trend + "process evolution"
  bullet. Proves the fix is real and cheap, not aspirational — the gap is only that it took ~5
  weeks to adopt.

- **Codified lifecycle guardrails eventually converted a chronic error class into a checked
  invariant.** `task_advance` auto-walking lanes, `task_validate` requiring a hard `checks`
  artifact, and the "self-validation only with automated regression proof" rule (CLAUDE.md
  "Agent self-validation" policy) are direct responses to the 180 lifecycle-shortcut violations
  measured in the jsonl study (see below) — codifying the fix in tooling rather than exhortation.

## What hurt — costly failures, with root-cause mechanism

- **Task-tracker lifecycle violations: 180 errors, second-largest error class, NEVER improved
  across 7.5 weeks despite constant rejection feedback.** Pattern: agents attempted
  `reported→fixed`, `progress→review`, `ack→fixed` shortcuts, omitting required fields. Evidence:
  `TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md` §1 row 2, §C. **Root-cause mechanism:** the
  lifecycle was enforced by *convention + agent memory* (a state machine the agent had to hold in
  its head and re-derive every session), not by the tool structurally refusing illegal
  transitions with a clear, immediate error the agent could act on in-loop. A rule that is
  "written down and expected to be remembered" reliably loses to context compaction — this is the
  same failure shape as the 260 post-compaction file-amnesia errors (#1 error class, 33% of all
  791), just applied to board state instead of file state. **This did not self-heal** — the fix
  had to be structural (a v4 tracker where "the runner walks the machine," not the agent) rather
  than a stronger reminder.

- **The board's two dominant piles are both "waiting on a human to look at it."** As of
  2026-07-04: `review` = 284 tasks (48% of all open), `validated`-awaiting-`done` = 735 tasks.
  Blockers: 83 `live-validation`, 23 (deprecated) `owner-decision`. `progress` = **0** — nothing
  was ever mid-flight; everything either hadn't started or was parked waiting on a gate.
  Evidence: `project-meta-analysis-2026-07-04/SYNTHESIS.md` "The numbers" + Finding 2.
  **Root-cause mechanism:** self-validation was capped at `fixed`/`review` by policy (owner
  validates `validated`/`done`), so *every* item that passed automated checks still required a
  human touch to fully close — the queue structurally re-forms in front of the single human
  regardless of how much automated work happens upstream. This independently corroborates the
  jsonl study's own finding (39.8% of the session's task-state time was spent in a "validated,
  stalled" condition, per the same SYNTHESIS) — two different data sources (commit ledger vs.
  session transcript) converging on the identical bottleneck shape.

- **Board understated actual completion — the "board ≠ code" trust break (c-18).** A code-first
  audit discovered features (conflict-resolution 3-pane, HTML network-consent grant UI, dynamic
  content menu) were fully wired in code but the board still tracked them as "missing UI" or
  unaddressed. Evidence: `summaries/commits/c-18of19.md` line 92, 140-141: "the tracking board
  had become a stale liability." **Root-cause mechanism:** the board was populated and updated by
  agents working forward from tickets, but nothing forced a periodic reverse check (does the
  *code* match what the board claims?) — drift accumulates silently in one direction (code moves,
  board doesn't get told) until a dedicated audit catches it. Same class of bug as the render
  false-greens: an artifact that's supposed to mirror reality has no forcing function keeping it
  synced.

- **Re-fix loops burn disproportionate commit volume without landing.** TSK-1046 (scroll-restore
  timing) took 13 commits across `progress`; TSK-1243 (VM UAT env-delivery harness) took 21+
  commits (11 in one era alone, "12% of one slice's commits went to harness introspection
  debugging"). Evidence: `project-meta-analysis-2026-07-04/SYNTHESIS.md` Finding 3;
  `summaries/commits/INDEX.md` rework-arcs table. **Root-cause mechanism (both cases): patching
  one stage of a multi-hop async/sequencing chain moves the bug to the next stage instead of
  removing it** — fixed permanently only once the design collapsed to a single source of truth
  (pull-based scroll read; a config-file side-channel instead of an env-var handoff). This is a
  *task-shape* problem as much as a code problem: neither ticket's contract required "hold ≥2
  competing hypotheses + a discriminating test" before landing a fix, so the same wrong hypothesis
  got re-attempted.

- **Over-decomposition inflated ticket count without adding shippable value**, prompting an
  explicit owner reversal. `CLAUDE.md` "⛔ AVOID OVER-DECOMPOSITION (owner directive 2026-07-10)"
  and `BACKLOG.md`'s matching rule exist specifically because the board had been shattering one
  coherent PR-sized change into a swarm of micro-tickets (a separate ticket per model-edit /
  test-write / view-wire / command-wire step). **Root-cause mechanism:** "file generously" (a
  correct instinct, to avoid losing threads) was applied at the wrong granularity — per edit
  instead of per shippable unit — because no heuristic distinguished a "thread" from a "checklist
  item" until the owner supplied one ("if closing the sub-ticket alone leaves nothing a user or
  test can observe, it wasn't a ticket").

- **Cost of the process-tracking apparatus itself was ~1/3 of all motion.** 36.5% of all commits
  doc-only; six of the ten highest-churn files in the repo are tracking docs, not code
  (`AUTONOMOUS_PROGRESS.md` #1 at 1,031 touches, `CHANGELOG.md` #2, `HANDOFF.md` #4). Evidence:
  `project-meta-analysis-2026-07-04/SYNTHESIS.md` Finding 1. **Root-cause mechanism:** this is
  the load-bearing workaround for the *absence* of a durable execution substrate — with no system
  that survives compaction on its own, the agent has to manually re-derive "what's going on" by
  writing it to a file, over and over, at real token/time cost. The 260 file-amnesia errors and
  the 180 lifecycle violations are the *same root gap* (no durable substrate) surfacing as tool
  errors instead of doc bloat.

## Design implications for the rebuild

**Fix from day 1 (structural, not process):**

1. **Make the tracker a state machine the tool enforces, not one the agent remembers.**
   Transitions the agent cannot legally make should be a hard tool-level rejection with a
   specific "here is the legal next state" response — not a convention documented in `CLAUDE.md`
   that erodes across compactions. This directly targets the 180-violation class that "never
   improved... despite constant rejection feedback" (rejection feedback alone is proven
   insufficient over 7.5 weeks).

2. **Design the "close the loop" step to not require a human per item.** The 735-item
   `validated`-awaiting-`done` pile and the 284-item `review` pile are both structural — every
   completed item still needs a human touch. Build an automated-runner-posted "usable" /
   time-boxed-auto-accept path (the v4 direction already scoped: "merge-queue-closes + runner-
   posted usable + 30-second accepted") so throughput isn't capped by one human's attention, while
   still giving the human veto power, not mandatory review power, on the common path.

3. **Make code the source of truth; treat the board as a cache that gets invalidated, not
   trusted blindly.** Schedule a recurring, cheap "does the board match the code" check (even a
   lightweight automated pass: grep for wired-but-untracked surfaces) rather than waiting for a
   dedicated audit to discover drift after months. This is explicitly the c-18 lesson: "A
   greenfield rebuild must make code the source of truth from day 1."

4. **Bake a "≥2 hypotheses + discriminating check" field into the bug-ticket contract**, required
   before a fix lands — not just for retrospective review. This is cheap (one required field) and
   targets the exact mechanism behind both re-fix-loop arcs (TSK-1046, TSK-1243).

5. **Ship an explicit ticket-granularity heuristic on day 1**, not after the board has already
   fragmented. "A ticket = what closes in one PR/commit; if closing the sub-ticket alone leaves
   nothing observable, it's a checklist item, not a ticket" — stated up front avoids the
   over-decomposition cycle this project had to reverse mid-course.

6. **Design doc/log capture as structured state, not markdown files needing manual folding.** If
   the tracker natively holds "what happened and why" per item (evidence rows, comments, a
   timeline), there is no `AUTONOMOUS_PROGRESS.md`-style append-only log competing for the same
   information — eliminating the highest-churn file in the corpus by construction, not by a
   later "fold into commit" discipline.

**Accept as inherent / ongoing cost (budget for it, don't expect to eliminate):**

- **Fanout audits are a recurring, healthy cost, not a one-off.** Budget a recurring cadence
  (e.g. every N features / before each milestone) rather than treating "pre-launch audit" as a
  single gate — this project needed 4+ rounds and each found real, distinct issues.
- **VM/render validation-harness maintenance is permanent infrastructure tax**, not bring-up-once
  cost — every new validation surface (webview, live-app, pixel, AX) needed its own multi-commit
  unblock throughout the entire timeline.
- **Some volume of re-fix looping is inherent to genuinely hard timing/race bugs** — the goal is
  capping it (discriminating-check requirement) not eliminating it outright.

## Portable rules

1. **Illegal board-state transitions are a tool-level hard rejection with the legal next state
   named in the error, not a documented convention.** (Targets the 180-violation class that never
   self-healed across 7.5 weeks of rejection feedback alone.)
2. **A ticket closes to "done" via an automated runner-posted signal + time-boxed default-accept,
   with human veto — not mandatory human review as the only path to closure.** (Targets the
   review=48%-of-open / validated=735 piles.)
3. **Schedule a recurring code-vs-board reconciliation check** (lightweight, automatable) rather
   than discovering drift only via a dedicated late-stage audit. Treat the board as a cache, not
   a ledger of record — code is the ledger of record.
4. **Bug tickets require a "competing hypotheses + discriminating check" field before a fix is
   accepted as landed** — prevents re-attempting an already-falsified hypothesis (TSK-1046/1243
   class).
5. **Ticket granularity = "closes in one PR/commit and leaves something a user/test can observe."**
   State this on day 1; don't let file-generously drift into a per-edit micro-ticket swarm before
   correcting it.
6. **Run severity-triaged fanout audits on a fixed cadence** (not once pre-ship), triaging raw
   findings into deduped themes before ticket-filing — this was the single most reused, most
   durable process pattern in the whole 3,733-commit history.
7. **Fold process/tracking documentation into the code commit it describes by default**, and
   prefer the tracker's own structured fields (evidence, comments, timeline) over hand-maintained
   markdown logs — don't wait for a mid-project doc-churn crisis to adopt this.
8. **Slice epics vertically (input-to-output, gated per slice) by default**; treat horizontal
   layering (all-model-then-all-UI) as the exception requiring justification, since it correlated
   with rework loops here and vertical slicing shipped both major epics (formula port,
   DocumentModel split) with zero regression.
