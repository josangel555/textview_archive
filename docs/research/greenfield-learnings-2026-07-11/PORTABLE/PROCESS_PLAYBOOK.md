# Process Playbook — working process for an agent-driven greenfield build

Copy this into the new repo on day 1 (e.g. `docs/PROCESS_PLAYBOOK.md`) and treat it as binding
process, not background reading. It distills what worked and what plateaued across a prior
57-day, 3,733-commit, ~1,500-ticket agent-driven build of a comparable app (a native-shell +
Rust-core editor with a coupled tracker). Every rule below is evidence-backed; the prior project's
own numbers are cited parenthetically as `(learned: ...)` — you don't need that project's
history to use this document, only its conclusions.

The one-sentence thesis: **prose-enforced process decays to zero improvement over a long run;
only mechanisms (structural constraints, tool-level rejections, evidence-gated transitions) hold.**
Every design choice below follows from that.

---

## 1. Ticket contracts — the unit of work

A ticket is **the smallest unit a user or an automated test could observe the completion of** —
roughly, what closes in one PR/commit. Not a step inside that unit.

- **Test before filing:** "if I close only this sub-item, is there something a user or test can
  observe?" If no, it's a checklist line inside the parent ticket, not a new ticket
  (learned: over-decomposition needed an explicit owner reversal 8 weeks into the prior project,
  after a 134→107 board dedup pass had already fired once).
- **Legitimate splits** (do file separately): a genuinely different tier/lane that can't ship
  together (e.g. host-testable model work vs. a render/UI tail that needs a different validation
  lane); an independently-shippable slice of an epic; a real blocker; unrelated work discovered
  along the way.
- **Illegitimate splits** (fold into the parent): "step N of implementing X" (write model → write
  test → wire view → wire command is ONE ticket); near-duplicates; a sub-ticket whose only
  acceptance criterion is a fragment of the parent's.
- **Every ticket names its `required_evidence_classes[]` at creation, not at review time.**
  Fixed vocabulary, e.g.: `host-unit`, `integration`, `rendered-DOM/UI`, `real-interaction`
  (synthesized real input, not a parallel reimplementation of the handler), `live-app`,
  `pixel-capture`, `owner-eye` (irreducibly subjective — the one class that stays human). The
  merge/close gate mechanically refuses a `fixed`/`validated`/`done` transition whose posted
  evidence doesn't cover every named class (learned: the prior project's "every change ships
  with tests" mandate was repeatedly satisfied by the *cheapest available* tier — a headless
  check — for behavior that tier structurally cannot observe, e.g. one compositor-occlusion bug
  class recurred 4 times before pixel-capture became mandatory per-ticket).
- **Bug tickets carry a `discriminating_check` field** — at least two competing hypotheses plus
  the test that would distinguish them — required before a fix is accepted as landed. If a fix
  needs a second patch attempt on the *same* bug, stop patching the current stage and look for a
  single source of truth to collapse the async/sequencing chain into, rather than adding another
  stage-patch (learned: two multi-week re-fix arcs — one 24 commits, one 21+ commits — both only
  resolved once patching stopped and the design collapsed to one source of truth; "2 failed
  patches → collapse the chain" is the actionable trigger).
- **Engine/model-layer tickets name their consuming surface at grooming.** A ticket that lands a
  model/API/engine without a named UI or caller is not "done" when the engine is green — wiring
  the consumer is a blocking child ticket by construction, not a follow-up someone might file
  (learned: a fully-ported, differentially-fuzzed engine shipped as "done" in the changelog with
  zero view callers; a generated output file was never actually copied into the shipped bundle;
  both were caught only by a late, dedicated audit).

## 2. Lifecycle — states a runner walks, not a state the agent remembers

- **Design the tracker so illegal state transitions are structurally inexpressible**, not merely
  rejected on attempt. A separate runner/orchestrator process walks the state machine; agent-facing
  tools are data-plane only (post evidence, claim work, request review, comment) — there is no
  tool call an agent can make that *attempts* `reported→fixed`.
  (learned: illegal-transition attempts were the #2 error class in the prior project's tool-error
  ledger, ~23% of all tool errors, and **never improved across the full run** despite constant
  rejection feedback — proof that "the tool rejects it and tells you why" is not a self-correcting
  signal over a long agent-driven run; only removing the affordance works.)
- **One ticket-ID namespace only.** If the agent harness has its own built-in task list, disable
  or ignore it for tracked work — never let two independently-numbered systems coexist under a
  visually-confusable id shape (learned: a generic-agent-harness task list and the project tracker
  both rendered as bare `#NNN`; the collision produced tickets closed as "fixed" against the
  wrong system's actual work, caught only by a dedicated "match recorded understanding against the
  ticket title" audit pass).
- **Closure does not require a human touch per item by default.** Route only genuinely-subjective
  evidence classes (`owner-eye`) through a human gate. For everything with an automatable evidence
  class, the shape is: runner re-runs the check itself → merge queue closes on green → a
  runner-posted `usable` signal → a time-boxed default-accept with human veto (not mandatory
  review) as the common path. Design this in from day 1, not as a later self-validation patch
  (learned: even after granting agents self-validation authority up through `fixed`/`review`, the
  two largest board piles were still both "waiting on a human to look at it" — 48% of all open
  items sitting in `review`, and roughly 3x that many sitting `validated`-awaiting-`done`; the
  median stall at that final human-gated stage measured in hundreds of hours. The arithmetic is
  the root cause: dozens of commits/day against one human reviewer cannot clear through a
  mandatory-human-touch path no matter how much automated verification runs upstream.)

## 3. Chunk-loop mechanics — the default cadence

- **Batch, don't ticket-at-a-time.** Pull 5–15 related tickets → implement code + tests for all of
  them → ONE full gate pass → higher-order render/UI tests only for the tickets that actually
  changed render → ONE commit referencing all ticket ids → advance the whole batch through the
  lifecycle together (learned: per-ticket ceremony was the default for roughly the first two-thirds
  of the prior project; switching to 5–15-item batches cleared a large backlog — 25 batches + 37
  drain ticks — at sustainable overhead; the earlier per-ticket cadence is explicitly named an
  anti-pattern in that project's own retrospective).
- **Slice epics vertically (input-to-output), gated per slice — the default shape, not the
  exception.** Horizontal layering (all-model-then-all-UI) correlates with rework loops; vertical
  slicing with a gate at each slice shipped two separate large epics — a 40-slice model
  decomposition and a differentially-fuzzed engine port — with zero regression across the full
  decomposition. Treat horizontal layering as requiring explicit justification.
- **Fold process/tracking documentation into the code commit it describes, by default, from
  commit #1.** Never make a standalone doc-only commit for a progress log, handoff note, or
  changelog entry — write it as part of the commit that does the work.
  (learned: docs-only commits reached 36.5% of *all* commits at peak — a mid-project "log every
  landed item" mandate pushed the docs-to-code commit ratio to 1.5–1.7:1; a single one-sentence
  "fold docs into the code commit" directive nearly halved it within a few weeks, down to
  0.3–0.5:1, with zero standalone process-noise commits by the end. One file alone accumulated
  over 1,000 touches and ~15,000 lines under the "log everything" regime — that whole class of
  cost is avoidable by defaulting to fold-in from the start.)

## 4. Grooming and gates

- **Gate lattice, cheapest-first, built before the thing it guards exists:**
  1. Compiler/import-level module-boundary enforcement (a CI grep/lint that a forbidden import
     never lands).
  2. A headless merge gate that runs on every commit, window-free, fast.
  3. Structural lint gates: dead-code/zero-caller detection on merge, no-discarded-result on
     persistence writes, budget tests with actual teeth (size caps, complexity caps, perf budgets)
     set *before* the thing exists — not raised reactively after 3x overshoot.
  4. A per-surface required-evidence-class matrix (see §1) with negative-control "teeth" switches:
     for any guard that's supposed to catch a class of regression, deliberately break the guarded
     behavior behind a flag and assert the guard actually goes red. A guard that has never been
     shown to fail is not a guard (learned: this is the "ImageRenderer/cacheDisplay/headless
     frame-walk gives a false green" trap — a rasterizer or in-process snapshot can render a
     UI element that is actually invisible/occluded on real screen pixels perfectly correctly in
     isolation; the only class of check immune to this is a real end-to-end capture of what the
     compositor actually produced).
  5. Evidence classes named per ticket at grooming (§1), enforced at the merge gate — not
     discovered missing at review time.
- **Audit intake before it becomes tickets.** Run any batch of raw ideas/feature requests through
  a cheap pass — contradicts existing code / already shipped / architecturally impossible /
  too vague to action / duplicate — before filing tickets from it (learned: one 373-item braindump
  audit found 10.2% pure noise: 6 contradicted the design mandate, 4 already superseded, 1
  architecturally impossible, 21 too vague, 6 duplicates — diluting every downstream
  prioritization pass by that fraction until caught).

## 5. Teeth discipline — the practice that actually held

This is the single practice in the prior project that visibly hardened over time rather than
decaying, and it should be a non-negotiable mandate from day 1, not an evolved norm:

**For any item closed as fixed/validated: write the test → run it green → revert the underlying
fix → confirm the test goes RED → restore the fix → confirm green again.** No exceptions,
including for items that look "obviously already fixed" — spot-check with the same recipe rather
than trusting inference. Where hand-reverting is impractical, gate a deliberate break behind a
named negative-control switch and have the test assert the guard goes red with that switch set —
a repeatable, committed proof rather than a one-time manual revert.

This is real cost, not free — budget for it (68 deliberate revert-to-red demonstrations were
recorded across the prior project's full run) — but it is the honesty mechanism that measurably
reduced false "done" claims reaching the owner, and unlike prose-only rules it is a *check*, not
an instruction, so it doesn't decay the way lifecycle discipline did.

**Real-render / UI claims specifically need the strongest tier of proof available in your stack**
— for a native UI over a compositor (SwiftUI/AppKit, or any layered-view system), that means
actual on-screen pixel capture of the composited window, not an in-tree snapshot renderer. A
snapshot renderer that rasterizes only the framework's own tree gives a false green for anything
that depends on real compositor layering/occlusion/z-order — this bug class alone recurred 4
times in the prior project before pixel-capture became the mandatory bar.

## 6. Audit cadence — the reusable severity-triaged fanout ritual

The single most durable process pattern across the prior project's whole life, reused at least
4 times independently and converging to the same shape each time. Adopt it as a **scheduled
cadence** (e.g. every N features shipped, or per milestone) rather than a single pre-launch gate:

1. **Fan out** a bounded set of read-only, single-pass exploration agents across the surface
   being audited (a subsystem, a security/correctness dimension, a UAT journey set). Each agent
   writes its own findings report to disk on completion — this alone bounds the blast radius of a
   quota/session death, since a mid-run kill loses only in-flight agents, not already-written
   findings.
2. **Dedup/triage the raw findings into severity-batched themes** before any fix work starts —
   don't fix findings as they arrive; cluster first.
3. **File per-theme tickets, ticket contract per §1** (including required evidence classes),
   then batch-fix by severity using the chunk-loop (§3).
4. **A multi-stage pipeline (fanout → dedup/synthesis → fix) needs per-stage checkpointing, not
   just per-agent output capture.** Write-as-you-go protects only the embarrassingly-parallel
   fanout stage; an aggregation/synthesis stage that depends on all upstream agents completing
   needs its own resumable checkpoint, or a quota death at 95% loses 100% of the synthesis value
   (learned: this happened twice to the same audit workflow in the prior project — the second
   death lost the entire verify+synthesis+fix phase a second time, leaving ~30 dimension reports
   permanently "plausible, unconfirmed").
5. **Reserve at least one blank-slate, unprimed explorer per audit round.** Don't hand every
   fanout agent the same pre-digested hypothesis set or prior findings — an agent seeded only
   with the raw surface and no steering finds angles the primed agents are structurally blind to.

Don't treat "pre-launch audit" as a single late gate — schedule this cadence from the first
milestone; every round in the prior project's history found real, distinct issues, including
rounds run late (a crash-class audit and a final quality sweep both found issues the earlier
rounds missed).

## 7. Reconciliation checkpoints — board vs. code, both directions

Schedule a recurring, lightweight "does the board match the code" check — not a reactive fire
drill triggered by "the board feels wrong." Check **both** drift directions on every pass:

- **Board overstates completion:** items marked fixed/validated whose actual behavior wasn't
  wired, tested at the right evidence tier, or actually shipped into the bundle/consumer. Catch
  by: matching a ticket's recorded understanding/evidence against its own title before trusting a
  closure; a zero-caller/dead-code grep as a standing gate; per-surface evidence coverage audits.
- **Board understates completion:** code that's more complete/wired than the tickets admit —
  happens when agents wire something as a side effect of other work and never file the ticket
  update. Catch by: a periodic code-first (not ticket-first) sweep that samples the actual
  codebase against what the tracker claims, filing corrections as findings when they diverge.

(learned: the prior project's board was independently found to fail in *both* directions at
different points — a late audit found the board understating completion, discovered ~18/19ths of
the way through the project's life, well after a "false-fixed" honesty apparatus had already been
built to catch only the *overstating* direction. Guard both from day 1; don't assume the honesty
tooling built for one direction also covers the other.)

Make code the source of truth by construction: derive ticket status from attached, evidence-tagged
proof, never from an assertion the agent or the tracker made independently of that evidence.

## 8. Handoff / compaction survival

- **Design the working unit to be short-lived and stateless by construction, not by discipline.**
  If a unit of work cannot be fully re-derived from a written ticket contract plus a small set of
  curated references at the start of a fresh session, it is scoped wrong — split it. Do not build
  correctness on cross-compaction memory of what was read or decided earlier in a long session
  (learned: post-compaction "I no longer hold state I need" errors were the single largest tool-
  error class in the prior project — a third of all tool errors, recurring roughly every 90
  minutes for the entire run, and **never trending down** across the whole project; this is not an
  agent-discipline problem, it's a session-architecture problem, and no amount of "remember to
  re-read" instruction fixed it).
- **Put durable state in the tracker itself (structured evidence rows, comments, a timeline),
  not in hand-maintained markdown files that need periodic pruning.** A markdown handoff/progress
  apparatus is a symptom of a missing structural need, not documentation — if it becomes the
  highest-churn set of files in the repository, that's the tell (learned: one narrative-log file
  alone accumulated over 1,000 edits and ~15,000 lines in the prior project; several of the
  ten highest-churn files repo-wide were tracking docs, not code — this is compaction-survival
  insurance manufactured out of markdown because no durable substrate existed elsewhere).
- If you do keep a handoff doc as a stopgap: cap its byte budget with a test that fails loudly
  when exceeded, update it in place (never append tick-by-tick history — that belongs in the
  commit log / tracker), and treat exceeding the cap as "prune the file," never "raise the cap"
  without an explicit decision to do so.

## 9. Autonomy escalation — what parks to a human, and how

- **Spike and design work is auto-approved.** For any non-trivial ticket, the agent runs its own
  scoping/feasibility spike and produces a design + breakdown autonomously, then implements. Do
  not park a ticket just because it "needs design" or "a decision about approach."
- **Escalate to a human only for:**
  1. A genuine **dependency/library/repository approval** (new supply-chain surface).
  2. A **true undifferentiated ambiguity** — cannot tell WHAT is being asked, not merely which of
     several reasonable approaches to take.
  3. A hard **blocker** (a lane is genuinely broken, or a needed capability doesn't exist yet).
  4. A **genuine product/taste decision** — "does this feel right," a one-way-door choice with no
     objectively-better answer, aesthetic judgment.
- **When escalating, always attach homework**: options considered, trade-offs, a recommendation —
  never a bare "what should I do?" The bar is "did the homework, needs a decision," not "didn't
  want to decide."
- **Escalation is a structured park, not an inline question that blocks the loop.** File it with
  full context and move on to other actionable work; don't stall waiting for an answer.
- **A "no more actionable work" stop is a process failure to diagnose, not a valid state for an
  autonomous loop.** If the obvious queue looks empty, pull from the tracker's own
  validate/review/triage backlog before concluding there's nothing to do.
- **Fan-out tools need a hard, structural ceiling, not a prompt convention.** Any agent capability
  that can itself invoke a spawn/delegate tool needs an enforced max-in-flight cap independent of
  which entry point triggered the fan-out — a "single pass, don't spawn sub-agents" instruction is
  exactly the class of rule that plateaus at zero compliance improvement over a long run (learned:
  a research-exploration task recursively self-amplified from 3 agents to roughly 75 and burned
  about half a session's quota — specifically because the delegated agent type itself carried the
  ability to delegate further; a prompt saying "don't do that" was present and didn't prevent it).
  Prefer: exploration/research agents use an agent type that structurally *cannot* invoke a
  spawn/delegate tool at all; execution fan-out (parallel implementation against an already-locked
  design) is fine and worked reliably when worktree-isolated with a hard cap.
- **Reap fan-out infrastructure on completion and on crash** — worktrees, build directories,
  locks. This is not optional cleanup; parallel isolated work directories accumulate multi-GB
  build artifacts per instance and were found to reach double-digit-GB scale in the prior project
  before an explicit reap procedure was adopted.

## 10. What to accept as inherent cost — don't over-engineer against these

- **Some human-eye gate for genuinely subjective evidence** ("feels slow," aesthetic taste) will
  always remain. Minimize the fraction routed there; don't promise zero.
- **Diagnostic over-confidence / re-fix loops on genuinely hard timing bugs** were the one failure
  class that *no* mitigation reduced across the prior project's full run — verification/teeth
  discipline makes a wrong hypothesis cheap to falsify but does not reduce the *rate* of nominating
  a wrong first hypothesis. Budget for it (the `discriminating_check` field in §1 caps the cost,
  it doesn't eliminate the occurrence) rather than treating a re-fix loop as a process bug to be
  designed away entirely.
- **Validation/render-harness infrastructure is a permanent maintenance tax, not a one-time
  bring-up.** Every new type of validation surface (a new rendering tier, a new automation
  interface, a new capture mechanism) needed its own multi-commit unblock throughout the entire
  prior project's timeline. Budget ongoing engineering time for it rather than expecting it to be
  "done" after initial setup.
- **Legitimately large epics generate legitimately long ticket chains** (dozens of commits against
  one ticket id, as additive slices). Don't conflate a high commit count against one well-scoped
  ticket with over-decomposition — the pathology in §1 is the *opposite* shape: many tickets, each
  contributing almost nothing individually observable.
