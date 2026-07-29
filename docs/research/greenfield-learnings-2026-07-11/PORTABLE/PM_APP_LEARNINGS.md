# Coupled PM App — Requirements & Design Learnings

Source: post-mortem of a 57-day, 3,733-commit, 1,474-board-ticket (board-verified 2026-07-11 by
a live query against the tracker's database, not an ID-range estimate — the commit-trailer grep
undercounted at ~1,168 and a prior ~1,500 figure was itself only an ID-range estimate; evidence
lives in the markdown_viewer analysis dir docs/research/greenfield-learnings-2026-07-11/aspects/board-ground-truth.md;
pointer does not resolve after copy)
agent-driven build of a prior project, run through a v1 task tracker. This document is the
extracted, ranked set of
requirements for the **new** project's coupled project-management app — read it before writing
the PM app's schema or verb surface. Every claim below is evidence-backed (kept as parentheticals);
strip them if they're noise for your purposes, but don't discard the requirement itself.

The prior project also validated a v4 tracker redesign on paper against this same evidence
(never built). Section 2 is that redesign's mechanisms — adopt them as the starting design, not
as inspiration to reinvent.

---

## 1. Ranked pathologies the PM app must fix

Ranked by measured cost in the prior project. If you only have budget for the top three, those
three alone structurally kill the majority of the measured pain.

### P1 — No durable execution substrate (the root cause behind #2 and #3 below)
The work session *was* the state. Nothing survived a context compaction except what got manually
written to markdown files.
- **Cost:** the single largest error class was compaction amnesia — flat at ~33% of all tool
  errors, never improved across 150 compactions in one project. The compensating workaround (append
  progress to a durable file so it could be re-read) became ~36.5% of all commits being doc-only,
  with one log file alone receiving 1,031 touches over the project's life.
- **Fix:** the PM app itself must be the durable substrate — work state, decisions, and evidence
  live in the tracker's database, not in files an agent has to remember to re-read. Design point:
  no agent session is ever load-bearing. A worker should be able to die mid-task and a fresh worker
  should be able to pick the exact same ticket back up with zero loss, by reading the ticket
  contract + evidence chain, not a transcript.

### P2 — Illegal state transitions enforced only by prose
Agents attempted illegal lifecycle transitions (skip states, omit required fields) constantly.
- **Cost:** this was the #2 error class and — critically — it **never improved** over the full
  project despite constant rejection-feedback from the tool. This is the strongest single data
  point in the whole corpus: a rule enforced by "the tool says no, try again" does not train the
  agent to stop trying. It has to become structurally unavailable, not merely rejected.
- **Fix:** agents never call state-transition verbs at all. A runner/orchestrator process walks
  the state machine on the tracker's behalf; agent-facing tools are data-plane only (post
  evidence, claim work, ask a question, file a finding). If the illegal transition can't be
  expressed as an available tool call, the error class is deleted, not merely reduced.

### P3 — The human as a mandatory serializer on every completed item
Every unit of finished work still required one human's manual "done"/"review" touch before it
could close, regardless of how much automated verification had already passed.
- **Cost:** at one point the majority of the entire open backlog was sitting in exactly two
  human-gated end states (roughly half the open board waiting on human review, and a separate,
  larger pile waiting on a human "accept" after already passing self-validation) — with **zero**
  items actually mid-flight. A convergent, independent measurement from the raw session logs found
  ~40% of all task-state *time* was spent stalled in that "validated, waiting for a human" state,
  with a multi-hundred-hour median stall.
- **Fix:** for anything with an automatable evidence class, the runner re-runs the checks itself
  and closes the item — a merge-queue-style close, not a human click. The human becomes a
  30-second "accept" on an already-verified item, or a genuine decider on one-way-door choices —
  never the mandatory serializer on the common path. Reserve human review specifically for
  evidence classes that are irreducibly subjective (aesthetic/feel judgments), not as the default
  closing mechanism for everything.

### P4 — Status asserted, not derived from evidence ("false-teeth" risk)
A ticket could be marked done/fixed on evidence that didn't actually cover the claimed behavior —
most damagingly, a cheap/fast test tier (e.g., in-process / headless) being accepted as proof of a
claim that only a more expensive tier (e.g., real rendered pixels) can actually verify.
- **Cost:** the same underlying bug class recurred **four times** before the fix (naming the
  required evidence class per ticket, mechanically gated) actually stuck. The generalized
  mechanism: coverage accretes along whichever evidence tier is *cheapest to produce*, not
  whichever tier the risk actually requires — every verification tier below the strongest one can
  be, and eventually will be, mistaken for the tier above it.
- **Fix:** every ticket names its `required_evidence_classes[]` at grooming time (creation), not
  at review time. The merge/close gate mechanically refuses a done/fixed transition whose posted
  evidence doesn't cover every named class. This must be schema, not a prose checklist — a ticket
  contract field the gate reads programmatically.

### P5 — Board state drifts from code truth, in both directions
The tracker both **overstated** completion (tickets marked fixed for work that wasn't actually
done, or for a different underlying issue than the one investigated) and **understated** it
(code that was fully wired and shipped, but the board still listed it as missing/unaddressed).
- **Cost:** both directions were only ever caught by a dedicated, deliberate reconciliation
  audit — never self-corrected. One late-project code-first audit specifically found the board had
  become a stale liability, tracking already-shipped features as still missing.
- **Fix:** treat the board as a cache invalidated against code, never as the ledger of record —
  code is the ledger of record. Schedule a recurring, cheap, automatable reconciliation job
  (sample tree claims against an actual codebase index) rather than waiting for a "the board feels
  wrong" trigger to force a manual audit.

### P6 — Ticket over-decomposition inflates process overhead per unit of real work
A correct instinct ("file generously so nothing gets lost") drifted into filing a separate
ticket per implementation *step* of one coherent change, rather than one ticket per shippable
unit.
- **Cost:** required an explicit reversal directive roughly 8 weeks into the project, after a
  dedicated dedup pass had already cut the actionable board by ~20% once. The cost mechanism is
  multiplicative, not additive: every extra ticket re-pays full grooming + gate + commit ceremony
  independent of how much real work it represents.
- **Fix:** state the granularity floor on day 1, not after the drift is discovered: *a ticket is
  the smallest unit that closes in one PR/commit and leaves something a user or an automated test
  can observe.* "Step N of implementing X" is a checklist line inside the parent ticket, not a new
  ticket. Pair this with a default batch-work-loop (pull 5–15 related tickets → implement → one
  gate pass → one commit, with per-ticket evidence still individually recorded) rather than
  per-ticket ceremony as the default cadence.

### P7 — Ungated intake pollutes the board with noise
Raw braindumped ideas were filed directly to the board with no audit step between "raw idea" and
"ticket."
- **Cost:** one measured braindump audit found roughly 10% of a large batch of freshly-filed items
  were pure noise (contradicted existing design decisions, were already shipped, were
  architecturally impossible, or were too vague to action) — diluting every downstream
  prioritization pass by that same fraction.
- **Fix:** run every new item through a cheap automated check before it becomes a ticket:
  contradicts-existing-code / already-shipped / duplicate / too-vague-to-action. This is cheap and
  should be a standing intake step, not a recovery action performed after the noise accumulates.

### P8 — "Done" never required a wired consumer
A green test suite, a closed ticket, and even a changelog line could all be true of a feature with
literally zero callers reaching it from the UI — an engine fully ported and tested but never wired
into any view; a generated file never actually copied into the shipped bundle.
- **Cost:** this was the class the project's own late-stage completeness audit flagged as its
  highest-severity findings — multiple shipped-looking features with zero UI callers, discovered
  only by a dedicated "is this actually reachable" sweep months after being marked done.
- **Fix:** make "consumption" a required, gated lifecycle stage, not a comment on a closed ticket.
  Engine/model-layer ticket contracts must *name the consuming surface* at grooming time, and the
  consumption stage should be a blocking child node the merge gate checks mechanically (e.g., a
  zero-caller/dead-code check as a standing gate class), not something that depends on the agent
  self-reporting the gap.

### P9 — Diagnostic re-fix loops on genuinely hard timing/race bugs
A small number of bugs consumed disproportionate commit volume because a wrong hypothesis was
re-attempted repeatedly instead of falsified once and abandoned.
- **Cost:** individual bugs consumed well over a dozen commits each without landing, in one case
  over 20 — and this class was explicitly found to be the one residual **not** fixable by any
  architectural change; it's a property of agent cognition (hypothesis selection), not tooling.
- **Fix:** don't try to architect this away — budget it. Require a `discriminating_check` field
  on bug ticket contracts (a test that would distinguish between competing hypotheses) before a
  fix is accepted as landed, and codify a "two failed patches on the same bug → stop, collapse to
  a single-source-of-truth redesign instead of patching another stage of the chain" escalation
  rule. Expect a fat-tailed distribution of attempts-per-bug, not a clean defect count.

---

## 2. v4 mechanisms to adopt (the validated redesign — start here, don't reinvent)

These are the concrete mechanisms a prior redesign effort specified (on paper, cross-checked
against the same evidence above) to fix P1–P5. Treat them as the starting schema/architecture for
the new PM app, not as one option among several — the cross-check found they structurally kill
most of the costliest measured classes.

### Stateless cells (kills P1)
No long-lived orchestrator session. Every unit of work — worker, orchestrator pass, audit stage —
**hydrates fresh from the tracker's stored contract** and produces evidence rows; there is no
session whose loss costs anything. "No session is load-bearing" is the design invariant, not an
aspiration. This is the single most data-backed decision to protect: any later design compromise
that makes a session load-bearing again silently reinstates the worst-measured error class.

### Runner-walked states, agents emit data-plane verbs only (kills P2)
Agents never call a state-transition verb. The runner (control plane) is the only actor that
writes lifecycle transitions; it does so by re-running checks itself and applying the result.
Agent-facing MCP surface is deliberately small (~10 verbs): read the subtree/plan/index, post
evidence, file a finding, ask/answer a question. No delete verb exists anywhere. No agent ever
scans a flat board — it reads a scoped, bounded view.

### Evidence rows + required-evidence-classes-at-grooming (kills P4)
Every ticket, at creation, carries a `required_evidence_classes[]` field pulled from a fixed
surface→evidence-class matrix (e.g., unit-test / integration / real-render-pixel /
interaction-driven / subjective-human-judgment). The merge gate mechanically refuses a
done/accepted transition unless evidence rows exist covering every named class, and — a
load-bearing detail a first-pass design missed — **the evidence must postdate the ticket's last
requeue/bounce**, not just exist somewhere in its history (otherwise a stale pass from an earlier
attempt can silently license a transition after the code changed again).

### Frontier views (replaces flat board scans and manual `next task` lookups)
Priority descends and readiness ascends through the intent tree (wish → feature → epic → ticket →
...); the "what should work next" answer is a deterministic SQL join over that tree — a
**frontier view** — not a ranked list an agent or human has to scan. A claim transaction handles
scope locks, skip-counts, reservations, WIP caps, and completion bias mechanically. No agent ever
"scans the board" looking for work.

### Scope locks / named serial resources (prevents collision + oversubscription)
File-level scope locks prevent two workers from claiming overlapping work. Generalize this to
**named serial resources** beyond files — a singleton GUI/render lane, a shared external service,
any resource that can only be held by one claim at a time. A ticket contract can declare
`requires_resource: <name>`; the claim transaction enforces exclusivity.

### Quota-aware dispatch (prevents fleet death mid-run)
The dispatcher must be aware of token/rate-limit budget windows and must not start large
fan-out work near a quota-reset boundary. Pair with a hard max-in-flight ceiling on any
fan-out capability (not just one tool — cap the *capability* to spawn further agents, wherever
it's exposed) and per-stage checkpointing so a multi-stage pipeline (e.g., an audit: gather →
synthesize) can resume a later stage without re-running an already-completed earlier one — a
first-pass implementation lost an entire synthesis stage twice by only checkpointing the
embarrassingly-parallel gather stage.

### Merge queue as sole writer to main (fixes provenance + kills P3/P5 jointly)
A single merge queue process is the only actor that ever touches the main branch. It writes
ticket provenance (which ticket, which evidence, which commit) at squash time — after the fact,
by the actor that actually knows the final SHA — rather than trying to reconstruct provenance
later by matching patch-ids. Feature-level "usable" is a runner-executed integrated-scenario
check, not a human judgment call; a human `accepted` is the 30-second final touch, and burn-up
reporting should count **accepted**, not merged/closed (closed counts alone can be fiction in
either direction — see P5).

### Default-with-veto + reversibility classing (the async-autonomy lever)
Classify decisions as two-way doors (reversible) vs one-way doors (not). Two-way-door decisions
auto-proceed on an SLA with the proposal logged for later review; only one-way-door decisions
actually block waiting for a human. This is the single biggest lever for keeping an autonomous
loop moving without needing a human in the loop constantly — apply it broadly, not just to code
review.

### Codebase index regenerated per merge
A structural index (module map, dependency graph, code exemplars) rebuilt automatically on every
merge, feeding both ticket decomposition and impact-selected test runs. Answers "where is this
already wired" without an agent having to grep-explore cold every time — directly targets P8/P5.

### Knowledge subsystem with a graduation pipeline
Lessons captured during work don't count until they **graduate** into an actual gate, lint rule,
or SOP diff — not just an entry in a markdown lessons file. The prior project's evidence: a
333 KB lessons file prevented essentially zero recurrences by itself (the same class of bug, e.g.
line-ending handling, recurred in a different code path despite being documented); every
mechanized rule (a budget test, a structural check, a gate) held. Track "lessons graduated :
lessons filed" as an explicit health metric, not just corpus size.

---

## 3. Agent-facing API needs

Design the MCP/tool surface for the PM app itself around these constraints, derived directly
from the pathologies above:

- **Small, role-scoped verb surface (~10 verbs, not 35+).** Every additional verb is additional
  surface for illegal-transition attempts, ambiguity, and argument-shape drift. Split by actor
  class (human / runner / check / agent) and give each class only the verbs it needs.
- **No delete verb, anywhere.** Deletion is a policy problem (archival, supersession), not a data
  operation an agent should be able to trigger.
- **No state-transition verb exposed to agents.** Agents post evidence and ask questions; the
  runner is the only caller of transition logic. (Restates P2's fix as an API design constraint.)
- **Bounded, scoped reads — never a full-board scan.** `read_subtree`/`read_index`-style verbs
  with byte/row budgets and cursor discipline. A prior version of this class of tool suffered a
  measured overflow class from unbounded reads on large trees — build the budget in from the
  start, don't retrofit it after the first overflow.
- **Schema-version handshake on connect.** The MCP server should advertise its verb/argument
  schema version and a registry hash at session start, with a deterministic staleness warning if
  a caller's cached schema is stale. A prior project lost real work to argument-shape mismatches
  across five separate call sites because there was no way for a caller to know its understanding
  of the API was out of date.
- **Free-text-always on any card/prompt presented to the human.** Never force the human into an
  options-only response; offered options are a shortcut, never a wall — the human must always be
  able to type a different answer.
- **Agent-side duplicate search as a first-class verb**, not just an orchestrator convention —
  promote "search for existing related work before filing new work" from a prose instruction to
  an actual FTS-backed `search`/`read_index` call agents are expected to make.
- **Persisted, human-viewable audit log of every tool call, from the very first commit.** The
  editor project this PM app is coupled to explicitly shipped an always-on, unauthenticated
  exec-capable socket with no audit trail — a deliberate wrong call discovered by its own
  security audit. The PM app's own server is exactly the same shape of always-on,
  exec-adjacent socket serving agents; don't repeat the omission. Pair with per-spawn scoped
  credentials (not a shared static token) and identity verification on the socket so a
  same-machine process can't impersonate the runner or a worker.
- **Resource sandboxing on check execution.** A check/test run must have enforced memory/CPU
  ceilings and report peak resource usage — an unbounded check process taking down the host
  machine is a real, previously-hit failure mode, not a hypothetical.
- **Enforce capabilities on the effect, not the call site.** A tool that can be reached two
  different ways (e.g., a "run this verb" passthrough vs. a direct call) must have the same
  capability check applied regardless of path — a documented bypass in the coupled editor project
  came from checking authorization at one call site and not the other route to the same effect.

---

## 4. What "coupled to the editor" should mean, concretely

The PM app is not a standalone tracker bolted on afterward — it is meant to be genuinely coupled
to the app the agent is building. Concretely, that coupling should mean:

- **Surfaces live in-app, not in a separate browser tab the agent has to context-switch to.**
  The inbox/tree/frontier/node views the human uses to steer work, and the review/walkthrough
  surfaces the agent uses to present changes, should render inside the same application shell as
  the product being built — not as an external website. This matters doubly here because the
  product itself is an editor/IDE-shaped app with its own webview/rendering surfaces already
  built — reuse that shell rather than building a second one.

- **An in-app "probe" — humble-object seam for headless verification of rendered UI.** The
  single most reusable structural fix identified for the false-green pathology (P4) is an
  in-app instrumentation seam (AX dump / screenshot / command execution over a local socket) that
  lets a check run against real rendered UI in seconds rather than requiring a slow, VM-hosted,
  full pixel-capture pipeline for every UI change. This is explicitly the mechanism that unblocks
  making real-render evidence *cheap enough* to be the default rather than the exception — a
  prior project found that mandates alone never changed the shape of test coverage, but making
  the fast/cheap check path also the *correct* evidence class did.

- **Review and walkthrough integration is a first-class ticket lifecycle stage, not a bolt-on.**
  Code review, reverse-review/walkthroughs, and the PM app's own evidence/decision timeline should
  read from and write to the same ticket/evidence rows — a review comment on a diff and an
  evidence row proving a test passed are both facts about the same ticket, not separate systems
  that need reconciling. Concretely: the "in_review" and "changes_requested" states in the ticket
  machine should be the same states the editor's review UI surfaces to a human, driven by the same
  underlying data — not a duplicate review concept living only in the editor with its own
  disconnected state.

- **Git integration is server-owned and single-writer.** Only the merge-queue process touches the
  shared branch/main; the editor-side git integration (status, diffs, review context) reads that
  same state rather than maintaining a parallel notion of "what's merged." This is the same
  single-writer principle as the merge queue mechanism above, applied specifically to the git
  surface the editor already exposes to agents.

- **The codebase index (module map, dep graph, exemplars) is shared infrastructure**, generated
  once per merge and consumed both by the PM app (for decomposition, impact-selected test
  selection) and by the editor's own in-app navigation/search features — not duplicated as two
  separately-maintained indexes.

- **One project = one PM-app deployment, with a thin cross-project inbox only if genuinely
  needed.** A prior design explicitly cut a "board of boards" spanning multiple projects as scope
  bloat at typical scale — default to one tracker instance per project (one embedded database,
  one repo) and only add a thin aggregated attention-only inbox across deployments if multiple
  active projects genuinely need it later. Don't build the cross-project abstraction speculatively.

---

## 5. Operating-model notes (apply regardless of PM-app internals)

These aren't PM-app *design* requirements but they shape how the PM app should be used from day 1
of the new project, and the PM app's UX should actively support them:

- **Pair every generative habit with a limiting habit, from day 1** — not as a retrofit weeks in.
  "File tickets generously" needs the granularity floor stated alongside it (P6). "Fan out
  research agents" needs the max-in-flight ceiling stated alongside it. "Write tests" needs the
  required-evidence-class matrix stated alongside it (P4). Every costly drift in the prior project
  had this exact shape: a correct instinct, run unbounded, corrected only after real cost was
  already paid.
- **Design the human's day as an inbox, not a supervisory queue.** Target: 30-second accepts,
  decision briefs with a recommendation already attached (not open-ended "what should I do"
  questions), aged/similar items batched into one card rather than N, interrupts reserved for
  genuine one-way-door decisions. Progress reporting should track a burn-up of items the human
  actually accepted, never a raw closed/merged count (closed counts were unreliable in both
  directions in the prior project — see P5).
- **Schedule integration/reconciliation as calendar events, not discoveries.** Both a
  code-vs-board reconciliation pass and a severity-triaged completeness audit should run on a
  fixed cadence (e.g., every N tickets, or every milestone) from the start — in the prior project,
  every instance of "the board doesn't match reality" was found by someone deliberately going
  looking, never automatically, and always months later than it should have been.
