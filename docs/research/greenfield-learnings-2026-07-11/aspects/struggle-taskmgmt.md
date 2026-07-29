# Struggle dimension: Task-management (the tracker/process itself)

Scope: not app bugs — the friction of running a 3,733-commit, ~1,500-ticket, 7.5-week
agent-driven project through a task tracker. Evidence drawn from the pre-digested corpus
(`summaries/INDEX.md`, `summaries/commits/INDEX.md`, `summaries/docs/d-progress-*.md`,
`summaries/docs/d-archive-tracking.md`), the 1.3GB session-transcript study
(`TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md`), the repo+board archaeology
(`project-meta-analysis-2026-07-04/SYNTHESIS.md`), `BACKLOG.md`, and project `CLAUDE.md`.

---

## Taxonomy — the distinct types in this dimension

### 1. Task-tracker lifecycle violations
Agent tries illegal state transitions (`reported→fixed`, `progress→review`, `ack→fixed`
shortcuts) or omits required fields on a transition call.
- **Frequency/severity: #2 error class overall, 180 of 791 tool errors (23%), NEVER improved
  across 7.5 weeks** despite constant rejection feedback (`TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md`
  §1.A row 2). This is a flat, non-learning error curve — the single strongest evidence that
  prose-enforced lifecycle discipline doesn't stick over a long agent-driven run.
- Evidence: same doc §2 marks it "DELETED" (not merely fixed) under the v4 design, because the
  fix is architectural (runner walks the state machine; agents only emit data-plane verbs) —
  implying no amount of CLAUDE.md instruction closes this class.

### 2. Ticket-identity confusion — `TSK-###` (board) vs `#NNN` (Claude Code's built-in TaskList)
Two independent numbering schemes collide; an agent updates/closes the wrong item, or records
work against one system's id while believing it's the other's.
- **Frequency: ~8 corrections in the session-transcript sample**, but disproportionately costly —
  it manifests as *false "fixed"* on a ticket whose actual underlying work is untouched.
- Concrete instances: TSK-276, 279, 326 confirmed mislabeled-as-fixed (`summaries/docs/d-progress-3of3.md`
  §2, "Three mislabels surfaced in the fixed-lane drain"). Codified as a standing check in project
  `CLAUDE.md`: *"Before validating/closing any `fixed` board ticket, match its recorded
  `understanding`/transition reasons against the board TITLE."* Also a standing memory
  (`reference_board_vs_tasklist_numbering.md`): "task_get before acting."
- Root cause: two competing "ticket" concepts occupying the same short-numeric-id namespace in the
  agent's working memory, with no structural disambiguator (both render as "#NNN"-shaped).

### 3. Over-decomposition (ticket fragmentation)
Filing a separate ticket per implementation step of one coherent change (write model → write
test → wire view → add command) instead of one ticket per shippable unit.
- **Frequency: became severe enough to require an explicit owner directive on 2026-07-10**
  (`feedback_avoid_over_decomposition.md`) — i.e. this was not a one-off, it was a systemic drift
  that needed correction mid-project, ~8 weeks in.
- Board archaeology found "over-decomposed clusters (multi-sibling rows implementing one feature
  together)" as one of five board-hygiene defect classes in the 2026-06-19 dedup pass
  (`summaries/docs/d-archive-tracking.md` §BOARD_CUT_DEDUP_PROPOSAL — 134→107 rows, −27 via
  cut/dedup/merge).
- Cost mechanism named explicitly: *"a fragmented board hides the real state and multiplies
  grooming/gate/commit overhead per unit of actual work"* — i.e. the cost is multiplicative
  (every extra ticket re-pays grooming + gate + commit ceremony), not additive.

### 4. Grooming/gate overhead accumulating per-ticket (before the batch-loop fix)
Early- and mid-project cadence ran close to one gate-pass + one commit per ticket. This is
economically distinct from over-decomposition (which inflates ticket *count*); this is the
cost model *per* ticket regardless of count.
- Evidence of the fix and its ROI: the 2026-07-07 work-loop mandate replaced per-ticket
  ceremony with **batch execution — pull 5–15 RELATED items, implement code+tests in one pass,
  ONE full gate pass, batch higher-order (WV/AX/T4/T5) tests only if render changed, ONE commit
  per batch** (`summaries/docs/d-archive-tracking.md` §NEXT_30_TASKS_2026-06-18.md;
  `BACKLOG_batches_2026-07-07.md`: 25 batches completed, typical 5–15 items/batch).
- Explicit anti-pattern named after the fact: *"Per-ticket validation ceremonies (the project
  moved to batch gates + lane consolidation)"* and *"Overly granular task tracking"* both listed
  under SKIP in `summaries/docs/d-progress-3of3.md`'s final "Avoid" section.

### 5. Board-as-noise: duplicates, stale leases, aspirational stubs, contradictions
Distinct from over-decomposition — this is entropy accumulating from the *intake* side, not the
work-breakdown side.
- **Quantified 2026-06-05 feature-braindump audit: 373 items classified, 38 (10.2%) were
  noise** — 6 contradicted the design mandate, 4 already superseded, 1 architecturally
  impossible, 21 too vague to action, 6 duplicates (`d-archive-tracking.md`
  §FEATURE_BACKLOG_AUDIT_2026-06-05.md).
- **2026-06-19 dedup pass: 134 actionable rows → 107** (−27, zero loss of real intent) via
  stale-lease reset (11 zombie `progress` rows from dead agent runs), true-duplicate merge
  (5 pairs), over-decomposed-cluster merge, aspirational-icebox demotion, decided-item close.
- Repo-wide corroboration: board state (2026-07-04 snapshot) showed **validated:735,
  review:284, reported:224, progress:0** — i.e. everything that starts moving either completes
  or stalls at the human-gated end states; nothing sits mid-flight
  (`project-meta-analysis-2026-07-04/SYNTHESIS.md` "The numbers").

### 6. The human-as-serializer bottleneck (validated/review pile-up)
Distinct failure shape from #5: tickets that ARE correctly worked and self-validated pile up
waiting for a human `done`/`review` transition that never structurally had to be human-gated.
- **Quantified: review=284 (48% of the open pool) + validated-awaiting-done=735**
  (`project-meta-analysis-2026-07-04/SYNTHESIS.md` Finding 2). Independently corroborated by the
  session-transcript study's "39.8%-validated-stall finding."
- Root cause named directly: *"the queue always re-forms in front of the human"* — self-validation
  authority (agent may move to `validated`/`done` with a `checks` artifact — see project `CLAUDE.md`
  §Agent self-validation) reduced but did not eliminate this, because render/UI evidence still
  routes through a VM tier that itself needs a human glance for some gap classes ("owner-eye" —
  see Taxonomy #7).

### 7. Evidence-class ambiguity / "runs green" ≠ proof (false-teeth risk)
A ticket is marked `fixed`/`validated` on host-green evidence that doesn't actually cover the
claimed behavior (headless-only proof for a rendered/pixel behavior).
- Root mechanism: `ImageRenderer`/`cacheDisplay`/headless frame-walks give **false greens** for
  SwiftUI+AppKit compositor occlusion — proven repeatedly (the terminal-tab-strip miss recurred
  **4 times** before pixel-level `screencapture` (T5) became mandatory; project `CLAUDE.md`
  §"Compositor occlusion + the ImageRenderer false-green trap (TSK-488, 2026-06-07)").
- Quantified test-pyramid mismatch: real-UI apex held only **24 T4/T5 functions for ~30
  surfaces**, while "every change ships with tests" was satisfied headlessly
  (`project-meta-analysis-2026-07-04/SYNTHESIS.md` Finding 4).
- The fix that finally stuck: **named required-evidence-classes per ticket** (e.g. "WV DOM +
  AX press + T5 pixel") baked into the ticket contract itself, gate refuses `fixed` without them
  — codified as the four testing MANDATES 2026-07-04 (`CLAUDE.md` §The four testing MANDATES).

### 8. Board ≠ code drift (both directions)
The board was found, at different points, to both **overstate** completion (mislabeled-fixed,
taxonomy #2) and **understate** it.
- c-18 era: *"the board was found to UNDERSTATE completion versus code; a code-first (not
  ticket-first) reconciliation pass"* triggered (`summaries/commits/INDEX.md` §Process evolution,
  "Ticket/board hygiene tightened late").
- Portable rule extracted: *"Treat the task board as a live index, not a trust anchor —
  periodically reconcile against actual code state"* (`summaries/commits/INDEX.md` Top learnings
  #9).

---

## What worked — practices/designs that earned their keep

- **Guard-teeth-before-close discipline.** For any item closed as `fixed`, the recipe (write
  test → run pass → revert fix → confirm test goes RED → restore → pass again) was applied
  systematically across the drain waves (`summaries/docs/d-progress-2of3.md` §4, "68
  'teeth-demonstration reverts'" in the session-transcript study). This is the one lifecycle
  practice that DID visibly harden over time and became a non-negotiable CLAUDE.md mandate.
- **Lane discipline (`reported→ack→triaged→progress→fixed→review→validated→done`) plus explicit
  gating tags** (`[render-VM]`, `[host]`, `[owner]`, `[built→flip]`) gave work a routable shape
  once adopted consistently (`d-archive-tracking.md` §Board Hygiene).
- **Agent self-validation authority, bounded by evidence.** Letting an agent move its own work to
  `validated`/`done` — but ONLY with an automated-test artifact that would fail on regression —
  cut human-gate load without reintroducing false-done (project `CLAUDE.md` §Agent
  self-validation, 2026-06-07 policy).
- **Batch work-loop (5–15 related items, one gate, one commit).** Directly measurable ROI: 25
  batches + 37 drain ticks cleared a large usability backlog with sustainable overhead
  (`d-archive-tracking.md` §BACKLOG_batches_2026-07-07.md; `project_batch_drain_2026_07_07`
  memory).
- **Periodic board reconciliation as a standing checkpoint**, not a one-off — caught both
  overstated (#NNN mislabels) and understated (c-18) drift when run.
- **Stage-gated feature rollout** (independent, undoable, owner-visible stages — soak A/A0/round2-4
  for Rust-engine ports; M0–M6 for Canvas) let large epics progress without forcing a false
  binary done/not-done and without blocking on owner review of the whole epic
  (`d-progress-3of3.md` §7).
- **`task_park` for genuine owner-gated decisions**, keeping the autonomous loop unblocked while
  still surfacing the decision with homework attached (options + rationale), rather than silently
  resolving ambiguity in code (the TSK-322/321 "resolved by design" trap it was designed to
  prevent — `d-progress-3of3.md` §D2).

## What hurt — the costly failures, with root-cause mechanism

- **Lifecycle violations (180 errors) that never improved.** Root cause: lifecycle correctness was
  enforced *only* by prose (CLAUDE.md instructions + rejection feedback from the tool), which the
  agent re-violates every session because there is no structural barrier — the tool *accepts* an
  attempted illegal call as an ordinary tool-call attempt and merely errors, so the agent pays the
  cost per-attempt with no cross-session learning signal. This is a class of bug where "tell it
  again more clearly" cannot work; the fix has to be that the agent literally cannot express the
  illegal transition (a runner that walks state on its own, agents only emit data-plane verbs).
- **TSK vs #NNN identity confusion → false-fixed.** Root cause: two independently-numbered systems
  sharing the same short "#NNN" surface form in agent working memory, with the built-in
  `TaskList` re-appearing every session as a name-space collision the agent has no way to
  permanently suppress. Cost: multiple tickets closed for the *wrong* underlying work,
  requiring a dedicated "match title vs recorded work" audit pass to catch.
- **Over-decomposition's multiplicative overhead.** Root cause: "file generously" as a standing
  rule was applied without a lower bound on ticket granularity, so an agent under an
  autonomous-loop cadence (favoring visible progress signals — closing tickets) drifted toward
  filing a ticket per edit/step. Each extra ticket re-pays grooming + gate + commit ceremony —
  cost scales with ticket COUNT, independent of actual work volume, until an explicit owner
  correction (2026-07-10) and a "closing the sub-ticket alone leaves nothing observable" heuristic
  were introduced.
- **Human-as-serializer bottleneck (735 validated + 284 review = a majority of the open board
  sitting at human-gated end states).** Root cause: the lifecycle design routes final-state
  transitions through a human touchpoint by default, and self-validation authority (added
  2026-06-07) only partially closed this because render/UI evidence classes still require a VM
  tier some of whose gap classes ("owner-eye" — "file open feels slow") are irreducibly
  subjective and can't be automated away. This is a genuinely-structural residual, not a process
  bug — see Design implications below.
- **Evidence-class ambiguity (false greens).** Root cause: "the letter of 'every change ships with
  tests' [was] satisfied headlessly while pixels went unguarded" — a ticket contract that only
  said "add tests" without naming WHICH evidence class was required let an agent satisfy the
  letter of the mandate with the cheapest available test tier (headless), even when that tier
  structurally cannot observe the claimed behavior (compositor occlusion, SwiftUI+AppKit
  co-hosting — see `CLAUDE.md`'s ImageRenderer false-green trap). The recurrence (4× on the same
  bug class) shows this isn't a one-time gap; it's what happens by default whenever a contract
  names an outcome ("tests pass") instead of a required evidence CLASS.
- **Board noise from ungated intake.** Root cause: owner braindumps were filed to the board
  directly, with no audit step between "raw idea" and "ticket," so contradictions (6),
  already-shipped duplicates (4), out-of-scope asks (1), and vague stubs (21) entered the
  same queue as real, actionable work — diluting every downstream selection/prioritization pass
  by ~10%.
- **Doc-corpus process tax as a *symptom* of the same root cause as lifecycle violations and
  amnesia.** 36.5% of all commits were doc-only; one file (`AUTONOMOUS_PROGRESS.md`) alone
  received 1,031 touches / 14,987 lines (`project-meta-analysis-2026-07-04/SYNTHESIS.md` Finding
  1). This is explicitly interpreted as "the compaction-survival apparatus... the cost of having
  no durable execution substrate" — i.e. task-management overhead and session-substrate overhead
  are the same underlying problem (no durable state outside the transcript) viewed from two
  angles (commit ledger vs. session errors).

## Design implications for the rebuild

**Do differently from day 1:**

1. **Make illegal lifecycle transitions structurally inexpressible, not merely rejected.** A
   runner/orchestrator process should own state-machine walking; agent-facing tools should be
   data-plane only (post evidence, claim work, request review) — never an API surface that lets
   an agent attempt `reported→fixed`. This directly kills the #2 error class (180 errors, 0%
   improvement over 7.5 weeks is empirical proof prose-enforcement doesn't work here).
2. **One ticket ID namespace, period.** Do not let a generic agent-harness feature (e.g. Claude
   Code's built-in TaskList) coexist with the project tracker's own numbering in a form that
   looks the same to the agent. Either disable/ignore the harness-native tracker entirely for
   tracked work, or give the two systems visually/structurally non-confusable ids (e.g. never
   bare `#NNN` for the tracker — always `TSK-NNN`, and instruct/tool-gate against ever writing
   bare `#NNN`).
3. **Every ticket contract names its required evidence classes at creation, not at review time.**
   Encode the evidence taxonomy (host-unit / WV-DOM / AX-interaction / T4-live / T5-pixel /
   owner-eye) as a first-class ticket field; the gate mechanically refuses a `fixed`/`validated`
   transition whose posted evidence doesn't cover the named classes. This is the single highest
   -leverage fix for the "engine ported ≠ feature shipped" / false-green class, and it is cheap
   to build in from day 1 versus retrofitting after the pattern has recurred 4 times.
4. **Ticket granularity floor, encoded as policy from the start**, not discovered 8 weeks in: a
   ticket = the smallest unit a reasonable engineer would ship as one PR/commit. Concretely,
   before filing, ask "if I close only this sub-item, is there something a user or automated test
   can observe?" — if no, it's a checklist line inside the parent ticket, not a new ticket.
5. **Gate/commit at batch granularity, not per-ticket, as the DEFAULT cadence**, with per-ticket
   evidence still individually recorded. The project discovered this only via a mid-project
   mandate (2026-07-07); build the batch-loop (pull 5–15 related items → implement → one gate →
   one commit, all ticket ids recorded) as the standard loop shape from the start.
6. **Gate braindump intake before it becomes tickets.** A lightweight "audit against current code
   + flag contradictions/duplicates/vagueness" pass before filing prevents ~10% permanent board
   noise (measured). This is cheap and should be a standing step, not a recovery action.
7. **Design the human touchpoint out of the default path, in explicitly**, rather than
   discovering the pile-up after the fact. Decide up front which evidence classes are fully
   automatable (headless, WV, AX, T4, most T5) vs. which are irreducibly a human judgment
   ("feels slow," aesthetic taste calls) and route ONLY the latter through a human gate by
   design — the v4 tracker redesign's "merge-queue-closes + runner-posted usable + 30-second
   accepted" mechanism is exactly this; adopt its shape from day 1 rather than retrofitting
   self-validation authority piecemeal as this project did.
8. **Periodic board↔code reconciliation is a scheduled checkpoint, not a reactive fire drill.**
   Both directions of drift (overstated via mislabeling, understated via stale tickets) were only
   caught when someone deliberately ran a reconciliation pass. Schedule it (e.g. every N tickets
   or weekly), don't wait for a "the board feels wrong" trigger.

**Accept as inherent cost (don't over-engineer against):**

- **Some human-eye gate will always remain** for genuinely subjective evidence classes ("feels
  slow", visual taste) — the goal is to *minimize the fraction* routed there, not eliminate the
  human touchpoint entirely. Budget for it rather than promising zero.
- **Epic-scale work will still generate legitimately high ticket counts and long-running "repeat
  -TSK" commit chains** (TSK-1110 ×63 commits, TSK-1213 ×35 — additive slices, healthy per
  `project-meta-analysis-2026-07-04/SYNTHESIS.md` Finding 3). Don't conflate high commit-count
  against one ticket with over-decomposition; that's healthy epic buildout. The pathology is the
  opposite pattern (many tickets, each contributing almost nothing observable).
- **VM/render validation infrastructure is a permanent maintenance tax**, not a one-time setup —
  budget ongoing engineering time for it (per `summaries/commits/INDEX.md` Top learnings #4),
  which indirectly keeps *some* tickets legitimately routed through a slower evidence lane.

## Portable rules — candidate directives for the next project (adopt verbatim)

1. **The tracker's state machine is walked by the runner/orchestrator, never by agent-issued
   transition calls.** Agents post evidence and claims; illegal-transition errors should be
   structurally impossible to attempt, not merely rejected on attempt.
2. **One ticket-id namespace only.** Never let a harness-native task list and the project tracker
   coexist under confusable identifiers; if the harness has its own, disable or ignore it for
   tracked work.
3. **Every ticket names its `required_evidence_classes[]` at creation** (e.g. `host-unit`,
   `WV-dom`, `AX-press`, `T4-live`, `T5-pixel`, `owner-eye`), derived from a fixed surface-catalog
   → evidence-class matrix; the merge/close gate mechanically refuses a `fixed`/`validated`
   transition missing a named class.
4. **Ticket granularity floor:** a ticket is the smallest unit a user or an automated test could
   observe the completion of. "Step N of implementing X" is a checklist line in the parent ticket,
   not a new ticket. Batch 5–15 related tickets per implementation/gate/commit cycle by default.
5. **Audit intake before filing.** Run new braindumped items through a cheap "contradicts existing
   code / already shipped / architecturally impossible / too vague / duplicate" check before they
   become tickets — measured to remove ~10% pure noise at zero real cost.
6. **Reconcile board vs. code on a fixed schedule** (not reactively) — check both directions of
   drift: tickets marked done that aren't, and code that's more complete than the board admits.
7. **Route only genuinely-subjective evidence classes through a human gate; automate the rest by
   design**, and let agents self-close with a `checks` artifact for anything with an automatable,
   regression-proof test. Minimize, don't eliminate, the human touchpoint — and design this in
   from day 1 rather than adding self-validation authority as a later patch.
8. **Demand demonstrated teeth before any `fixed`/`validated` close**: test written → run green
   → underlying fix reverted → test goes RED → fix restored → test green again. No exceptions,
   including for "obviously already fixed" backlog items — spot-check with the same recipe rather
   than trusting inference.
