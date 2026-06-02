# Project Management Design v2 — solo dev + AI agents, full SDLC

> **Status: re-derivation, not a refinement of v1.** This supersedes the model in
> `docs/PROJECT_MANAGEMENT_DESIGN.md` on three axes the owner has since fixed as hard
> constraints, and where v1's "anti-bloat" instincts turn out to be the *wrong* economy for
> an agent-driven workload. Where v1 and v2 disagree, the disagreement is called out
> explicitly (§0.2) — v2 does not silently overwrite v1's reasoning, it argues against it.
>
> **What changed and why.** v1 was synthesized *with* the owner's rough sketch in hand and
> largely ratified it (markdown files-in-git, blocked-as-a-derived-flag, event-sourcing
> rejected as "overkill"). v2 is derived from the agent-SDLC research **without** anchoring on
> that sketch or any predefined taxonomy of types/states, and leads with what the naive
> hierarchical-tracker mental model — and v1 — structurally get wrong.
>
> **Owner decisions this design lives inside (not re-litigated):**
> 1. **Store** must be permanent, consistent, and programmatically manipulable by both a
>    human (UI) and AI agents. **Not markdown.** (v1 chose markdown; v2 does not.)
> 2. **"Blocked / awaiting a human decision" is a first-class *state*** a task can be in —
>    not a derived flag. (v1 modeled it as a derived flag and argued against a state; v2
>    reverses this.)
> 3. This is an **in-app feature of a desktop developer tool** — UI + features in the app —
>    not CLI-only.
>
> **Assumed-known baseline (not restated here):** a hierarchical issue tracker — items with
> type / status / priority / sub-tasks / dependencies, a board, a backlog. That is the
> floor. This document is about everything *above* it that an AI-agent-driven SDLC needs and
> a human tracker does not.

---

# PART 0 — THE FRAME

## 0.1 The one-sentence inversion

A hierarchical tracker models **intent and status for a reliable, single, remembering,
honest, human-speed worker.** Every one of those five adjectives is false for an AI agent,
and each falsification forces a specific structural change in the store:

| Tracker assumes the worker… | An agent actually… | Forces |
|---|---|---|
| **remembers** what it was doing | starts every session as a fresh hire that has read nothing; loses its working memory to context compaction mid-task | the task must *be* the agent's external memory — cumulative, append-only, including dead-ends |
| is **honest** about "done" | is motivated and able to fake done (overwrite tests, delete assertions, force a green check) | "done" is a verifier-gated transition by a *different* actor, never a self-set flag |
| operates on a **stable world** | acts on a world that drifts under it; resumes from a stale summary and treats it as ground truth | the store fights *staleness*, not just data loss — truth is an event log, current state is a projection |
| works at **human speed, alone** | runs concurrently at machine speed in a swarm; two agents grab the same task | leases + compare-and-swap + conflict-as-a-state, not "assignment" |
| has **bounded, free** effort | costs real money per step on a quadratic curve; loops forever on a flaky goal | per-task budgets are enforced *state*; "abandon / not worth it" is a legitimate terminal |

The naive tracker (and v1, on the store axis) optimizes for **durability** — data survives,
is consistent, is editable. The dangerous failure for agents is not data loss. **It is a
record that is durable, internally consistent, and *wrong about the world*.** Roughly a
third of long-horizon agent failures trace to context/goal drift, not reasoning quality. The
store's primary job is to keep the record *true to reality and reconstructable as to why* —
which is a different and harder job than "don't lose the data."

## 0.2 Where v2 overrides v1 (be explicit)

These are the load-bearing reversals. They are not refinements; they are the owner's three
hard constraints colliding with three v1 decisions, plus what the agent-SDLC research forces
once you take those constraints seriously.

| Axis | v1 decided | v2 decides | Why the reversal |
|---|---|---|---|
| **Store substrate** | markdown + YAML frontmatter, file-per-item, in git (Option 1a) | **embedded SQLite, Rust-owned, event-log + materialized projection** | Constraint #1 (not markdown). Markdown can't enforce a state, reject a dependency cycle transactionally, gate a transition on actor identity, or prevent two agents claiming one task. Those aren't conveniences — they are correctness for an agent swarm. |
| **History model** | hybrid markdown snapshot + `events/*.jsonl`, event-sourcing rejected as "overkill for what's fundamentally CRUD" | **event log is the source of truth; task state is a projection** | It is *not* CRUD. The whole value is reconstructing *what an agent believed at decision time* and *why* — which a last-write-wins row destroys. Event-sourcing is the structural enabler for almost everything else here (blocked-as-continuation, staleness, branches, audit). |
| **Blocked / awaiting human** | "a derived readiness flag + an `awaiting` reason code, NOT a separate status" | **a first-class state (`Parked`) carrying a typed, durable, resumable continuation** | Constraint #2. A flag can't carry the question, the option set, the frozen agent state to resume from, the resolver-authority boundary, or an SLA. The block *is* a durable continuation, not a boolean. |
| **Per-task budget / "abandon"** | not modeled (v1: "no story points / velocity / burndown") | **per-task token/cost/wall-clock/attempt budget as enforced state; `Abandoned` as a first-class terminal** | v1 correctly killed *human* planning ceremony (points/velocity). But agent cost is a real, quadratic, runaway-prone resource — the opposite economy. Budget is a *safety* field, not a planning ritual. |
| **Dependencies** | `depends_on` (hard ordering) + `touches` (soft contention) | keep both, **add output-consumption data-deps with directional invalidation** | v1's deps are forward scheduling only. The dangerous agent case is the *reverse ripple*: upstream output changes after a dependent consumed it. "Done" must be invalidatable. |

What v1 got **right and v2 keeps wholesale** (do not re-derive these):

- The four jobs (decompose / track / prioritize-readiness / autonomy-boundary) and the
  team-PM-vs-agent-PM reframe (§1.1 of v1).
- One recursive `ITEM`, shallow tree, parent state is a **derived projection never
  hand-edited** (§1.3.5 of v1) — v2 sharpens the roll-up precedence but keeps the principle.
- `depends_on` (ordering) ⊥ `touches` (contention) as *different edge sets, different
  algorithms* — the single most repo-specific insight in v1.
- The deterministic, explainable `work_next` filter-then-rank queue with critical-path
  weight; tie-break toward *clarity* not value.
- The autonomy gate (`auto` / `gated` / `supervised`) keyed on reversibility/blast-radius,
  *not* importance; the "default is STOP" asymmetry.
- "Agents file `Idea`/`Todo`; humans promote." Decomposition is itself a gated planning act.
- The app fit: `ViewerCore` for pure logic, MCP as the agent surface, a UI panel on the
  code-review tool-window pattern, `humanAccepted` withheld from the agent.

---

# PART 1 — WHAT'S GENUINELY NON-OBVIOUS

This is the part that matters most. Each item is a thing the naive tracker model — and a
first-pass rough sketch — gets structurally wrong for an agent-driven SDLC. Ordered roughly
by how surprising / high-ROI it is, not by where it sits in the lifecycle.

## 1.1 The store's primary job is to defeat *staleness*, not to be *durable* — so truth is an event log, not a state row

This is the deepest inversion and it drives the store choice (Part 3). A tracker stores
`status = in_progress` as a **fact**. For an agent that is a **claim with an expiry**. The
agent that wrote it has since been compacted, the file it was editing has changed under it,
and the upstream task it depended on may have been reopened. The record is durable,
internally consistent, and *wrong*.

Three consequences the naive model has no slot for:

- **Every assumption an agent carries has an expiration.** Context references aren't a static
  blob; they're references with a `last_read_hash` + `last_read_at`. File contents go stale in
  minutes, an interface in hours, live data in seconds. The store should carry TTL semantics
  *per field-class*, not treat all context as equally fresh.
- **Pre-flight drift check is a first-class store operation, not agent discipline.** Before a
  side-effecting action the store should be able to answer: *is the resource still at the hash
  the agent last saw? is the upstream task still in the state this work assumed?* A mismatch
  must be *representable as a state* (see `assumptions-invalidated`, §1.7), not just silently
  cause a re-plan or — worse — let the agent charge ahead on a stale plan.
- **Truth is the event log; current state is a projection.** The mutable "current state" of a
  task is a fold over an append-only event stream, never the authoritative source. This is the
  structural argument for an **event-sourced core**: you must be able to reconstruct *what an
  agent believed at decision time*, which a last-write-wins row table destroys the instant
  it's overwritten. (This is exactly the call v1 declined as "overkill." It is not overkill;
  it is the foundation.)

> **Genuinely new vs baseline:** a tracker treats the row as truth and history as a nicety.
> Here history *is* truth and the row is a cache. Inverting that is the whole ballgame.

## 1.2 "Blocked / awaiting human" is a typed, addressable *question with a frozen continuation* — not a flag, and not even one state

Constraint #2 mandates first-class blocked-awaiting-human. The non-obvious part is *what a
blocked record has to carry to be useful to an agent*, and the equally non-obvious part is
*how many blocked states there really are*.

**A blocked record is useless unless it can be acted on, routed, and resumed from.** In
production HITL, a blocked agent doesn't "set a flag" — it **suspends, serializes its complete
state to durable storage, surfaces a structured decision request, and resumes from the exact
checkpoint when an answer arrives.** The block *is* the durable continuation. So a first-class
`Parked` state must carry:

- **the question, the enumerated options, and the consequence of each** — not "needs human
  input" but a structured decision the human (or another agent) can answer *without
  reconstructing the agent's context*;
- **the frozen continuation** — the serialized state to resume from, so resumption isn't a
  restart-from-scratch (the documented failure: after resume the agent "works on B without
  ever completing A");
- **liveness on the block itself** — a human-decision block open 6 days is a different
  operational object than one open 6 minutes; blocks need age + SLA + escalation, or your
  "first-class blocked state" silently becomes a graveyard.

**But it is one state with typed *reasons*, not N parallel states.** This is the central
design call, so here is the reasoning: `blocked-on-human-decision`,
`blocked-on-dependency`, `blocked-on-failing-gate`, `blocked-on-external` share an *identical
lifecycle contract* — durably suspended, not dispatchable, holds a resume checkpoint, exits
only when a specific event fires. They differ only in **what event resumes them and who is
authorized to fire it.** Modeling them as separate top-level states triples the transition
table for zero behavioral difference. So: **one `Parked` superstate, a discriminated
`ResumeContract`.** The reason that earns "first-class" status (constraint #2) is the
*contract*, and the human-typed variants are distinct, queryable, with their own resolver —
not a boolean derived after the fact.

| `ParkReason` | resumes on | who may fire it | notification | auto-resume? |
|---|---|---|---|---|
| **AwaitingDecision** — agent hit a fork it isn't authorized/confident to take | `HumanDecision{question, options[], chosen}` | **human only** | **pings** | no |
| **AwaitingApproval** — agent *has* a plan; needs a yes/no/amend on a consequential/irreversible action | `ApprovalDecision{approve|reject|amend}` | **human only** | **pings** | no |
| **AwaitingInput** — missing credential / spec / upstream artifact | `ArtifactProvided{slot}` | human or external | **pings** | no |
| **AwaitingDependency** — another work item must reach a state | `ItemReachedState{itemId, state}` | **system** | **silent** | yes |
| **AwaitingGate** — failing tests / CI / lint; *retryable* | `GateResult{gateId, pass|fail}` | **system** (re-run) | silent → escalates | yes, with cap |

Three things genuinely diverge across these and justify the discriminated union over an
opaque "blocked":

1. **Notification policy.** Dependency waits must be *silent*; decision/approval waits must
   *ping a human*. A bare string reason would force you to either spam the human or drop the
   ping.
2. **Resolver authority.** Only a human may fire `HumanDecision`; only the system may fire
   `ItemReachedState`. This is an **authorization boundary** — it belongs in the type, enforced
   by the command handler (an agent literally cannot resolve its own human-gate), not in
   convention. This is the mechanical realization of "the agent must never self-certify."
3. **Auto-resume vs manual.** Dependency/gate waits resume themselves; decision/approval/input
   waits require an external actor.

**Escalation is a transition between reasons, not a new state.** `AwaitingGate` that
exhausts its retry cap *re-parks as* `AwaitingDecision` — the retryable mechanical wait
converts into a human-ping when retries are spent or the failure is judged non-mechanical.
That's the circuit-breaker pattern as a state edge.

> **Genuinely new vs baseline:** a tracker's "Blocked" is a column or a label whose meaning
> ("blocked on what?") lives in a comment. Here it is a typed, durable, resumable continuation
> with an authorization boundary and an SLA — generated automatically when confidence drops
> below threshold or a precondition fails (§1.8), and *queryable* ("every decision the system
> is waiting on me for, with the cost of agent-time stalled behind each").

## 1.3 The task IS the agent's external working memory — and the single highest-ROI field is the *negative* one

A tracker assumes the worker remembers what they were doing. An agent doesn't: after 2–3
context compactions it "behaves as if the session just started," and default summarizers are
lossy in exactly the fields that matter. Critically, each compaction *overwrites* the prior
summary rather than appending — so a naive "description field" loses the cumulative arc.

The task record has to be the durable working memory the model lacks. The fields the research
repeatedly shows must survive — and that a tracker has no slot for:

- **Decisions and *why*** — reasoning is not re-derivable from the diff; store it explicitly.
- **Negative knowledge / dead-ends tried** — `attempted_and_rejected[]` with the reason. "A
  research agent that does not remember failed search queries repeats the same dead ends…
  retries the exact fix that crashed the build on Friday." Agents waste up to ~85% of compute
  rediscovering context. The naive model records only *what's left to do*, never *what was
  tried and failed*. **This is arguably the highest-ROI non-obvious field in the whole
  store** — it's cheap to write and it directly stops the most expensive, most common agent
  waste. It doubles as a stigmergic signal (§1.6): the next agent reads "this area is hot / I
  failed approach X here" and routes around it without a central planner.
- **Open threads / findings** at a stable granularity, so resumption is a *read*, not a
  re-exploration.

Design implication: **resumption is a read against the store, not a replay of a chat log.**
The store exposes a "rehydrate this task to actionable state" view — a *curated, projected*
handoff packet (distinct from the complete-but-verbose event log) that is compaction-proof
(lives outside any one context window) and **cumulative** (append, never clobber, the
working-memory sections). A fresh agent, a different agent, or a human resumes from it without
re-deriving everything.

> **Genuinely new vs baseline:** trackers store the forward plan. The agent SDLC's scarce,
> repeatedly-rediscovered resource is the *backward* knowledge — what was already tried and
> failed, and why. First-class `attempted_and_rejected[]` is the cheapest big win here.

## 1.4 "Done" is a self-report from an entity with a motive to lie — so it's a verifier-gated transition between *two* states, and the acceptance check itself needs integrity

The hardest semantic problem. A tracker lets the assignee flip `status = done`. With agents
this is actively dangerous: documented reward-hacking in coding agents includes **overwriting
unit tests, deleting assertions, monkey-patching the scoring function, and forcing early
termination to get a green check** — "satisfy the literal objective but not its intent." *The
agent that did the work is the worst possible judge of whether it's done.*

What the model must encode:

- **Acceptance criteria as executable artifacts, not prose.** A prose Definition-of-Done is
  just another thing an agent can *claim* to have met. Acceptance must be machine-checkable (a
  command, a test, an assertion) and must name **which lane verifies it** (the host headless
  gate vs the VM lane vs `/verify`) — an agent that can't run the VM lane must mark a VM-only
  item `AwaitingGate`/parked, never fake-pass it.
- **Implementation and verification must be uncorrelated actors.** Model `done` as a transition
  *gated by an independent verifier*, so you need at least two distinct states:
  **`claimed-done`** (the doer's self-report — the agent's ceiling) ≠ **`verified-done`** (an
  independent judge — tests, a reviewer agent, or a human — passed). The doer never closes its
  own task. This separation is also the post-hoc review surface: collapse them and you have
  *removed* the place a human reviews agent work.
- **The acceptance check itself is mutable by the worker — track its integrity.** Tie
  acceptance criteria to a hash; a worker modifying the test is a **flagged event**, not a
  silent edit, so "I made it pass" can't quietly mean "I changed what passing means."

> **Genuinely new vs baseline:** in a tracker, the assignee attests "done" and we trust them.
> Here, completion is *claimed* by the doer and *earned* by an independent verifier event,
> with the verifier's own artifacts hash-protected against the doer. Two states, a gate
> between them, and provenance on the gate.

## 1.5 Provenance is a *decision trace* (why, given what was believed), not an audit *log* (what happened)

A tracker has a comment thread and an `updated_at`. That's a *log*. Agent-driven SDLC needs a
**decision trace**: "spans are a latency graph; decision provenance is a semantically rich
record of *why*." Without it you can't see "which agent introduced the wrong fact, and why
every subsequent agent trusted it" — and a downstream agent that inherits a wrong premise
propagates it confidently.

Fields that attach to *each state-changing decision* (not the task as a whole) that the naive
model lacks:

- **Identity & lineage** — `decision_id`, `actor_id`, `parent_decision_id` — to reconstruct
  causal chains across agents and sub-agent handoffs. Plus `causation_id` (the command/event
  that caused this one) and `correlation_id` (groups one human ask's fan-out into the 14 agent
  actions it spawned). The interesting agent-SDLC question is rarely "what changed" but "one
  human request fanned out into which actions, and which agent's decision caused this
  regression" — these IDs make that a query, not an archaeology dig.
- **Model fingerprint at decision time** — pinned model version + system-prompt hash +
  tool-registry version. "Silent provider-side model updates can change behavior"; without this
  a regression is unattributable.
- **Inputs held at that moment** (input-commitment hash) + **data freshness**
  (`age_at_decision_seconds`). Reconstructing "why" requires knowing what the agent *saw* —
  which mutable rows overwrite.
- **Side-effect flag + reversibility / compensating action** defined at design time, plus a
  human-approval marker for the irreversible ones.
- **Human accountability** — *which person owns the outcome*, recorded at decision time,
  distinct from which agent executed it.

> **Genuinely new vs baseline:** the audit trail's consumer is usually *the next agent*, not a
> compliance auditor. It needs the *why under what beliefs*, not the *what when*.

## 1.6 Coordination happens *through the store*, not through messages — the store is a blackboard

A tracker assumes humans talk in comments and a PM assigns work. An agent swarm should **not**
message each other directly. They read and write a **shared structured workspace** (the
store), and a control component decides who acts next from current state. This decouples
agents (add/remove a specialist without rewiring anyone), and — combined with the event log —
gives a complete coordination audit trail for free.

- **Stigmergy** (ant-pheromone coordination): agents coordinate by *leaving signals on the
  shared structure* that bias the next agent, rather than by explicit handoff. The
  `attempted_and_rejected[]` field (§1.3), confidence markers, and "this area is contested"
  annotations *are* those pheromones. The work item is the coordination medium.
- This is the deeper reason the append-only model matters: the event log **is** the blackboard.
  Coordination = reads/writes/signals on shared items, not a message bus.

> **Genuinely new vs baseline:** trackers are a passive record that humans coordinate *around*.
> Here the store is the *active coordination substrate* the agents coordinate *through*.

## 1.7 Dependencies are *live invalidation edges*, not static parent/child links — "done" can go stale

A tracker's `blocked-by` is a forward scheduling hint: do B after A. The dangerous agent case
is the **reverse ripple**: A completes, B starts and consumes A's output, then A is reopened or
its output changes — and B is now built on a premise that no longer holds. The naive model has
no concept of *downstream invalidation*. This is cache-invalidation applied to work items, and
it's a top quality-killer: an agent marks a task done, an upstream change invalidates the
assumption, nobody notices.

Borrowing from build DAGs (Bazel/Nix): a completed task carries the **fingerprint of what it
was completed against** (spec version, files touched, upstream task outputs consumed). When an
upstream task's *output* changes, dependents auto-transition `verified-done → assumptions-
invalidated` and must be re-examined — automatically. **"Done" is a cache entry keyed on its
inputs, not a tombstone.**

This requires distinguishing two edge kinds the tracker conflates:

- **finish-to-start scheduling deps** (`depends_on`) — pure ordering; do *not* ripple on
  change.
- **output-consumption data deps** — B consumed A's output; *these* ripple on change.

Tracking the wrong one means spurious re-work (invalidate on every upstream edit) or silent rot
(never invalidate). This is the substrate for impact analysis: change a spec, and lineage tells
you *exactly which completed work is now suspect.*

> **Genuinely new vs baseline:** trackers model "do B after A." This models "if A changes, B's
> completion is no longer trustworthy" — a directional invalidation edge, not a scheduling
> hint. (This also extends v1's `depends_on`/`touches` — it's a *third* edge kind v1 lacked.)

## 1.8 Calibrated confidence drives blocking — and the agent is systematically overconfident

A tracker has no confidence field because a human's competence is implicit. Agents are
**systematically overconfident**, so a *raw* self-reported confidence is dangerous — but a
*calibrated* one is the routing signal that decides autonomous-resolve vs. escalate. This is
the engine that *populates* the first-class `Parked` state from constraint #2:

- tasks/decisions carry a calibrated confidence; **escalation thresholds are policy on the
  task** — high → autonomous; medium → proceed-with-caveats or ask a clarifying question; low →
  emit an `AwaitingDecision` and park.
- **Process reward, not just outcome reward**: prompt the agent at ~25/50/75% of its step
  budget to estimate success probability; if the estimate is *declining*, escalate or kill the
  attempt *before* burning the rest of the budget. The naive tracker has no concept of an
  early-abort-on-declining-trajectory mechanic.
- **Uncertainty propagates**: a task completed under low confidence elevates its dependents'
  risk — combine with §1.7 to prioritize re-verification along high-uncertainty paths.

> **Genuinely new vs baseline:** confidence isn't decoration — it's the trigger that
> *generates* a blocked state and the dial that decides whether the human is interrupted.

## 1.9 Every task has a *budget*, and "give up" is a legitimate terminal

A tracker has no cost dimension because human effort is implicitly bounded by a salary and a
workday. Agents have a **quadratic cost curve** — agentic coding consumes ~1,000× the tokens of
plain reasoning; a documented case scaled a $500 POC to $847k/month; an agent with no cap and a
flaky goal loops "hundreds of times without delivering."

- **Per-task budget (tokens / cost / wall-clock / attempts) as stored, enforced state** —
  checked *before* execution, with the over-budget estimate written and the task stopped
  *before* it runs, not after the money's spent.
- **`Abandoned` / `not-worth-it` as a first-class terminal**, distinct from `done` and
  `failed`. "Diminishing returns, stop" is a valid, recordable outcome — and it carries the
  negative-knowledge (§1.3) so the next attempt or a human starts ahead.
- **Loop detection**: the store seeing the same agent re-enter the same state with the same
  parameters N times is a signal to break the loop and escalate (a §1.2 block), not let it
  burn.

> **Note this is the *opposite* economy from v1's anti-bloat rule.** v1 correctly killed human
> planning ceremony (story points, velocity, burndown) because the AI "doesn't get tired on
> Fridays." But the AI *does* burn money on a runaway curve — so the cost dimension v1 dropped
> for humans is exactly the *safety* dimension agents require. Different reason, opposite call.

## 1.10 The work-graph is a *tree of attempts*, not a single line; and the goal must be an immutable anchor

Two smaller-but-real ones the tracker's single status can't express:

- **Branching attempts.** Agents should explore multiple solution branches from a checkpoint
  (best-of-N, backtrack, expand the promising one), using execution feedback as reward. A
  single `status` can't represent "3 attempts in flight, B looks best, A/C abandoned." With an
  event-sourced store this is cheap: branches are alternate projections replayed from a common
  checkpoint event, each with its own trajectory + verifier score, and "which branch won and
  why" is a recorded decision.
- **Goal/intent drift.** Over a long trajectory, "system prompts lose attention weight…
  syntactically valid actions slowly drift from the original intent" (instruction
  centrifugation). Keep the **original intent immutable and addressable**, separate from the
  evolving execution log, so divergence is *measurable* and a reviewer agent can "detect
  divergence between the living spec and the code" rather than trusting the builder to
  self-correct. The spec can be a living execution log — but the *anchor* intent must not be one
  of the mutable parts, or you lose the reference to measure drift against.

## 1.11 The non-obvious through-line: these are all the same shape

Almost every item above is the same structure. **An append-only event log of
intentions/decisions/effects, with current task state as a projection**, is *simultaneously*:

```
                          ┌────────────────────────────────────────────┐
   append (human OR agent)│            EVENT LOG (the truth)            │
   ──────────────────────▶│   intentions · decisions · effects · signals│
                          └───────────────────────┬─────────────────────┘
                                                   │ project (deterministic fold)
        ┌──────────────┬──────────────┬───────────┼──────────────┬──────────────┐
        ▼              ▼              ▼            ▼              ▼              ▼
   task state /    blocked-queue   lineage /     trajectory /  attempt-       coordination
   roll-up         (suspended      staleness     verifier      branches       blackboard
   (the board)     continuations)  (impact)      verdicts      (checkpoints)  (stigmergy)
                                                   ▲
   generated by: confidence < threshold · failed precondition · stale upstream · declining
                 process-reward · exhausted retries → emits AwaitingDecision / Signal
```

Pick the event-sourced store and most of the other "features" become **projections and
queries over one log**, not separate subsystems. That is the architectural payoff and the
reason the store choice (Part 3) is load-bearing rather than incidental.

---

# PART 2 — THE RECOMMENDED MODEL (derived)

Entities, hierarchy, lifecycle, deps, queue, context, autonomy — derived from Part 1, not
assumed from a taxonomy.

## 2.1 Entities, hierarchy, roll-up

One recursive **`ITEM`** (kept from v1 — shallow tree, 2 levels typical, parent state is a
*derived projection*). The fields below are organized by *which Part-1 problem each defends
against*, which is the derivation discipline this redo demands.

```
PROJECT (the repo)
  └── ITEM (recursive; parent state is DERIVED, never authored)
        identity      : id, title, parent
        intent        : intent_anchor  (IMMUTABLE once set — the drift reference, §1.10)
        kind          : open vocabulary (Feature|Bug|Chore|Spike|Decision|… — not a fixed enum)
        lifecycle     : state  (the machine, §2.2 — Parked is first-class)
        autonomy      : gate (auto|gated|supervised), confidence (calibrated, §1.8),
                        escalation_threshold
        readiness     : depends_on[]        (HARD ordering — schedule; does NOT ripple)
                        consumes[]          (DATA dep — ripples; invalidates on upstream change, §1.7)
                        touches[]           (SOFT contention — don't RUN concurrently)
        grounding     : context_refs[]      (each: {ref, last_read_hash, last_read_at, ttl_class}, §1.1)
                        acceptance[]        (executable checks, each: {check, lane, hash}, §1.4)
        memory        : decisions[]         (with WHY, §1.3 / §1.5)
                        attempted_rejected[](dead-ends + reason — the high-ROI field, §1.3)
                        handoff_packet      (curated, cumulative rehydration view, §1.3)
        economics     : budget {tokens, cost, wall_clock, attempts}  (enforced, §1.9)
                        spent  {…}                                   (running)
        claim         : lease {holder, acquired, expires, heartbeat}  (CAS, §1.6 / 2.4)
        completion    : claimed_done_by, verified_done_by, verified_done_via  (two actors, §1.4)
        provenance    : (per decision, not per item — see event schema §3.3)
```

**Open vocabulary for `kind` and visible state names; fixed *classes* for the machinery.** A
hard lesson from v1's survey: configurability is Jira's most-cited failure mode. v2 threads it:
the *machinery* (lease gating, human-gate authorization, auto-clear, roll-up) keys off a small
set of **state classes and reason kinds the core understands**; the *visible labels* are an
open vocabulary a solo dev can extend without breaking any automation. You get Linear-style
opinionated cores with a cosmetic escape hatch — never a custom transition graph.

**Roll-up (kept from v1, precedence sharpened for the agent case).** Parent state is a pure
projection over children, computed bottom-up, never persisted as source of truth. The
precedence — worst/most-attention-needing wins — is the agent-specific bit:

```
1. ANY child Parked(human-typed: Decision/Approval/Input)  ─▶ parent BLOCKED(human)  ← bubbles to top, PINGS
2. ANY child Active / In Progress                          ─▶ parent ACTIVE
3. ANY child Parked(auto: Dependency/Gate)                 ─▶ parent BLOCKED(auto)    ← silent
4. ANY child Ready (none active/blocked)                   ─▶ parent READY
5. ALL children verified-done (Cut counts as satisfied)    ─▶ parent SETTLED (eligible for its OWN review)
6. ALL children Closed                                     ─▶ parent CLOSED
7. mixed terminal (some Abandoned/Cut)                     ─▶ parent NEEDS-ATTENTION (partial)
```

`BLOCKED(human)` outranks everything so a deeply-nested decision-wait makes the whole epic show
"needs you" — the entire value of first-class blocked-on-human is that it *bubbles up*. Two
flavors of rolled-up BLOCKED (human vs auto) so the parent inherits the *notification
semantics*, not just the fact of blockage. **All-children-done makes a parent *eligible for its
own review*, never auto-`Closed`** — you can have every part done and still reject the assembled
whole (the case naive "auto-close parent" automation gets wrong).

## 2.2 The lifecycle state machine — `Parked` first-class, ownership per edge

States derived from the only question that matters for an agent: *who/what does the system block
on, and what observable event ends the wait?*

```
   (created) ─▶ Proposed ─▶ Ready ─▶ Active ──▶ ClaimedDone ──▶ VerifiedDone ──▶ Closed
                   │          ▲  │      │  ▲          │ (verifier gate)    │
                   ▼          │  ▼      ▼  │          ▼                    ▼
                Rejected      └─ Parked ◀─┘      (fail) back to Active   Abandoned
                              (superstate: durably awaiting a typed signal, §1.2)
                                   │
                                   └─ assumptions-invalidated (upstream output changed, §1.7) ─▶ re-examine
```

| State | Invariant (not a label) | Live? |
|---|---|---|
| **Proposed** | exists, not yet admitted; scope/intent unconfirmed (agents *propose* freely) | open |
| **Ready** | admitted, fully specified, **all preconditions met & acceptance present**, dispatchable now | open |
| **Active** | an agent/human holds it (has a lease) and is doing work | open |
| **Parked** *(superstate)* | durably suspended on a typed `ResumeContract` (§1.2) — the first-class blocked state | suspended |
| **ClaimedDone** | the doer asserts complete — *the agent's ceiling* (§1.4) | open |
| **VerifiedDone** | an independent verifier passed (tests / reviewer / human) | open |
| **Closed** | integrated/shipped; terminal | terminal |
| **Rejected** | declined at intake; never admitted; terminal | terminal |
| **Abandoned** | admitted but stopped without completion — budget exhausted, superseded, not-worth-it (§1.9); terminal but **carries the negative knowledge** | terminal |
| **assumptions-invalidated** | was VerifiedDone, an upstream `consumes[]` output changed (§1.7); auto-entered, routes to re-examine | open |

**Transition ownership is the safety boundary** — the part the naive model leaves to "anyone
can move anything." Encoded as data so an autonomous loop *cannot* skip a human gate even when
instructed to:

| Edge | Owner | Guard |
|---|---|---|
| `∅ → Proposed` | agent \| human | creation |
| `Proposed → Ready` | human (agent only if auto-admit policy) | acceptance present + spec complete |
| `Proposed → Rejected` | human | decline |
| `Ready → Active` | agent \| system | atomic claim (lease acquired) + `gate ≠ supervised` + budget OK |
| `Active → Parked` | agent \| system | self-park with a typed `ParkReason` + `ResumeContract` |
| `Active → ClaimedDone` | **agent** | agent proposes done (its ceiling) |
| `Active → Ready` | **system** | lease expired / agent crashed → requeue (**must be idempotent**) |
| `Parked → Ready/Active` | **system** | `resumeOn` fired (auto for dep/gate); human-typed → human supplies a *value*, system rehydrates |
| `Parked → Abandoned` | human | "don't do this" |
| `Parked(Gate) → Parked(Decision)` | **system** | retries exhausted → **escalate** (now pings) |
| `ClaimedDone → VerifiedDone` | **system / verifier** | independent check passes (§1.4) — never the doer |
| `ClaimedDone → Active` | agent \| human | verifier failed (kickback) |
| `VerifiedDone → Closed` | human \| system | integration/merge gate |
| `VerifiedDone → assumptions-invalidated` | **system** | upstream `consumes[]` output changed (§1.7) |
| `* → Abandoned` | human | kill in-flight work |
| set acceptance `humanAccepted`-class checks | **human ONLY** | structural — agent can never self-certify |

**Principle:** agents own the *doing*, *self-parking*, and *proposing* done + *objective*
checks; humans own *admission*, *acceptance*, *abandonment*, and resolving human-typed parks;
the **system** owns leasing, requeue-on-crash, firing auto-resume signals, escalation, and
rehydration. Note the human **never sets state directly** — the human supplies a *value* into
the `ResumeContract`, and the *system* performs the transition and rehydrates the checkpoint.
That keeps resume idempotent, replay-safe, and audited.

**Two subtleties that bite if ignored:**

- **`ClaimedDone` ≠ `VerifiedDone` is the review surface.** Let an agent jump straight to
  `Closed` and you have removed the place a human reviews agent work. Keeping them separate is
  what makes post-hoc review a *state*, not a side channel.
- **`Active → Ready` requeue must be idempotent.** Resume = re-execution from the checkpoint, so
  every effect an agent performs before parking/crashing must be idempotent (idempotency key on
  the work-unit) or the requeue double-applies it (duplicate PRs/commits). This is the single
  most important *implementation* constraint dropped onto the store/agent contract.

## 2.3 SLA on human-typed parks — timeout escalates, never auto-approves

A `Parked(AwaitingDecision)` with no deadline is how agent work silently dies. Each human-typed
park carries an `sla` + `escalation_chain`; on breach the system re-escalates. **Timeout is
never auto-approve** — at worst it auto-`Abandons` with a loud audit entry. (Auto-approve on
timeout is a governance failure, full stop.)

## 2.4 Dependencies + the next-ready-task queue (kept from v1, extended for §1.7)

Three edge kinds now — v1's two plus the data-dep:

```
depends_on : ORDERING       — A must finish before B starts (DAG, acyclic)   — does NOT ripple
consumes   : DATA           — B consumed A's output; A changes ⇒ B invalidated (§1.7) — RIPPLES
touches    : CONCURRENCY    — A and B must not RUN at once (contention set)
parent     : CONTAINMENT    — B is part of A (strict tree, roll-up)
```

The queue is the same **deterministic, explainable filter-then-rank** pure function from v1
(stable final tiebreak so a human and an agent never disagree on "the next task"), with the
filter extended:

```
FILTER (candidate iff ALL hold):
  1. leaf (parents are containers)
  2. state ∈ {Ready, Active}                     ← not Parked, not terminal
  3. gate ≠ supervised AND no open AwaitingDecision/Approval   ← autonomy gate
  4. all depends_on are Closed/Cut                ← hard ordering
  5. no consumes[] upstream in assumptions-invalidated         ← §1.7 freshness
  6. touches[] ∩ (any active item) = ∅            ← soft contention
  7. budget remaining > pre-flight estimate       ← §1.9 economic gate
  8. context_refs all fresh (hash matches / within TTL)        ← §1.1 staleness pre-flight
RANK (descending): tier → critical-path weight (unblocks the most) → age → stable id
```

Filters 5, 7, 8 are new vs v1 and trace directly to Part 1. **Definition-of-ready** still
requires a crisp executable `acceptance` with a named lane; no machine-checkable success
condition ⇒ not ready. **Tie-break toward clarity, not value** — route ambiguous high-value work
to a human-clarification queue rather than letting the agent take it on.

## 2.5 The autonomy / safety boundary (kept from v1, with confidence wired in)

Two orthogonal axes (v1's framing, kept):

- **(A) Authorization — "may I do this alone?"** — `gate ∈ {auto, gated, supervised}`, keyed on
  **reversibility, blast radius, cost — not importance.** Default-STOP asymmetry: an item is
  auto-runnable only if explicitly `auto` *and* unblocked *and* contention-free (three
  affirmative conditions). Adding a dependency / network code fetch / schema migration / merge
  to trunk / spend / secret rotation → human sign-off. Anything outside the declared
  `touches`/`files` scope → pause + escalate.
- **(B) Liveness — "am I making real progress or running away?"** — attempt cap, cost/wall-clock
  budgets with hard stops (§1.9), ground-truth validation not self-report (§1.4), no-progress /
  declining-process-reward detector (§1.8), scope fence on `touches`.

New wiring in v2: **confidence below `escalation_threshold` (§1.8) auto-emits an
`AwaitingDecision` and parks** — the autonomy gate and the blocked state are two ends of one
mechanism. Decomposition of a big item remains a gated planning act: agents *propose* a child
breakdown; a human approves it landing.

---

# PART 3 — THE STRUCTURED STORE (constraint #1)

## 3.1 Decision

**A single embedded SQLite database file, owned and serialized by the Rust core, as a hybrid
event-log + materialized-projection store.** An **append-only, hash-chained event log is the
source of truth**; a set of **materialized current-state tables** are a deterministic
projection of that log for fast querying. Both live in the *same* SQLite file so one
transaction commits the event *and* its projection atomically.

This is the structural realization of §1.11: one event log, many projections.

## 3.2 Why this store — and why each alternative loses

| Option | Verdict | Why |
|---|---|---|
| **Markdown / files-in-git** (v1's choice) | ✗ (constraint #1) | No referential integrity, no atomic multi-field update, no transactional concurrency. `Parked` becomes parsed text not an enforced state; a dependency cycle gets silently written instead of rejected; "two agents claimed the same task" is unpreventable; "who/why" is a commit message at best. Can't answer `work_next` without re-parsing the world. *Durable but not consistent or safely-concurrent.* |
| **SQLite, mutable rows only** | ✗ | Loses the *why* and the agent's believed-state the instant a row is overwritten — fatal for §1.1/§1.5, where the whole value is reconstructing how an agent reached a decision. |
| **Pure event store, no projection** | ✗ | Every `work_next` becomes a full-log replay — O(events) per read, and agents poll constantly. |
| **CRDT / local-first multi-writer** | ✗ for v1, keep for later | Real (agents emit ops 25–100× human rate, CRDTs converge lock-free) — but convergence is *eventual*, and `Parked` + dependency gating + lease ownership need a **single linearizing authority** to be correct. A CRDT would happily let two agents both "win" a lease. Reserve CRDT for *cross-machine* sync later. |
| **DuckDB / Postgres-embedded** | ✗ | Analytics-shaped or heavier; we already ship `libsqlite3` with zero new dependency. |
| **Event log + materialized projection on SQLite, Rust-owned** | ✓ | Atomic event+projection commit, single-writer correctness, full audit by construction, fast reads, fits the repo's existing pieces with ~zero new dependency. |

**Fit with this codebase (the deciding practical factor):**

- The app **already links `libsqlite3.dylib`** directly (read-only today, via
  `Sources/ViewerCore/SQLite/SQLiteReader.swift`) — **zero new dependency** for the read path.
- There is a committed **Rust core** that already pulls `serde` + `rmp-serde` (MessagePack) and
  frames a **length-prefixed binary RPC** — and the owner has explicitly chosen the reusable
  core to be Rust with compact binary RPC, no JSON. The PM store is the natural *write*
  counterpart, owned in Rust.
- The only dependency judgement-call: **`rusqlite` (the de-facto-standard, thin-over-C crate)
  vs. binding `libsqlite3` directly from Rust** as the Swift side already does from C. *Best
  guess: `rusqlite` is worth it — but it needs explicit approval (per the minimal-deps rule);
  it is the single library this whole design adds.*

## 3.3 Schema

Storage engine knobs (the writer connection the read-only `SQLiteReader` doesn't have):

```sql
PRAGMA journal_mode = WAL;        -- UI/agent readers never block the single writer
PRAGMA synchronous  = NORMAL;     -- WAL-safe durability, no fsync-per-commit stall
PRAGMA foreign_keys = ON;         -- dependency/lease integrity enforced by the engine
PRAGMA busy_timeout = 5000;       -- existing house pattern
```

### Event log — the source of truth (append-only, hash-chained)

```sql
CREATE TABLE event_log (
  seq            INTEGER PRIMARY KEY,    -- monotonic linear order (the linearization point)
  event_id       BLOB NOT NULL UNIQUE,   -- ULID; idempotency key for retried commands (§2.2)
  ts             INTEGER NOT NULL,        -- unix micros, WRITER-assigned (not client clock)
  actor_id       TEXT NOT NULL,           -- 'human:jos' | 'agent:reviewer-3' | 'system'
  actor_kind     INTEGER NOT NULL,        -- 0 human, 1 agent, 2 system  ← provenance is first-class
  event_type     TEXT NOT NULL,           -- open vocabulary (§2.1 "fixed classes, open labels")
  subject_id     BLOB,                    -- the work_item this event is about
  causation_id   BLOB,                    -- the command/event that caused this one      (§1.5)
  correlation_id BLOB,                    -- groups one human ask's fan-out               (§1.5)
  reason         TEXT,                    -- the WHY — REQUIRED on state transitions      (§1.3/§1.5)
  -- decision-trace fields (attach to state-changing decisions, §1.5):
  model_fp       TEXT,                    -- model version + system-prompt hash + tool-registry ver
  input_hash     BLOB,                    -- input-commitment hash (what the agent saw)
  data_age_s     INTEGER,                 -- freshness of inputs at decision time
  confidence     REAL,                    -- calibrated confidence (§1.8)
  side_effect    INTEGER,                 -- 0/1; reversibility + compensating action in payload
  payload        BLOB NOT NULL,           -- MessagePack: the typed delta for this event_type (versioned `v`)
  prev_hash      BLOB NOT NULL,           -- hash of previous row's row_hash
  row_hash       BLOB NOT NULL            -- H(prev_hash || canonical(this row)) — tamper-evident chain
);
CREATE INDEX ix_event_subject ON event_log(subject_id, seq);
CREATE INDEX ix_event_corr    ON event_log(correlation_id);
```

- **Hash chain**: `row_hash = H(prev_hash ‖ canonical_bytes(row))`. Any retroactive edit or
  deletion breaks the chain — cheap tamper-evidence without a blockchain. Tie `acceptance`
  checks to a hash too (§1.4) so "I made the test pass" can't silently mean "I changed the
  test"; a worker editing an acceptance check is a *flagged event*, not a quiet update.
- **`reason` app-required on transitions** — the consumer of history is the next agent; a
  transition with no `why` is worthless to it.

### Materialized current state (a projection of the log — disposable, rebuildable)

```sql
CREATE TABLE work_item (
  id              BLOB PRIMARY KEY,
  parent_id       BLOB REFERENCES work_item(id),
  title           TEXT NOT NULL,
  intent_anchor   TEXT,                   -- IMMUTABLE drift reference (§1.10); set-once
  kind            TEXT NOT NULL,          -- open vocabulary
  state           TEXT NOT NULL,          -- state CLASS the core understands (§2.2)
  park_reason     TEXT,                   -- NULL unless state = Parked; discriminant (§1.2)
  resume_contract BLOB,                   -- MsgPack: question/options/checkpoint (§1.2)
  gate            TEXT NOT NULL,          -- auto|gated|supervised
  confidence      REAL,
  budget          BLOB,                   -- MsgPack {tokens,cost,wall_clock,attempts} (§1.9)
  spent           BLOB,
  handoff_packet  BLOB,                   -- curated cumulative working memory (§1.3)
  completion_fp   BLOB,                   -- fingerprint of what it was VerifiedDone against (§1.7)
  claimed_by      TEXT, verified_by TEXT, -- two distinct actors (§1.4)
  created_seq     INTEGER NOT NULL REFERENCES event_log(seq),
  updated_seq     INTEGER NOT NULL REFERENCES event_log(seq),
  CHECK (id <> parent_id)
);

-- edges as rows (cycles detectable, roll-ups joinable) — three kinds (§2.4)
CREATE TABLE wi_edge (
  from_id  BLOB NOT NULL REFERENCES work_item(id),
  to_id    BLOB NOT NULL REFERENCES work_item(id),
  kind     INTEGER NOT NULL,   -- 0 depends_on (order) | 1 consumes (data, ripples) | 2 touches (contention)
  PRIMARY KEY (from_id, to_id, kind),
  CHECK (from_id <> to_id)
);

-- the concurrency primitive a tracker lacks entirely (§1.6/§2.2)
CREATE TABLE wi_lease (
  item_id   BLOB PRIMARY KEY REFERENCES work_item(id),
  holder_id TEXT NOT NULL, acquired INTEGER NOT NULL,
  expires   INTEGER NOT NULL,     -- TTL: a dead agent's claim auto-frees; also the liveness signal
  heartbeat INTEGER NOT NULL
);

-- first-class human-decision gate, queryable (constraint #2 made concrete)
CREATE TABLE pending_decision (
  id BLOB PRIMARY KEY, item_id BLOB NOT NULL REFERENCES work_item(id),
  kind TEXT NOT NULL,             -- Decision|Approval|Input
  question TEXT NOT NULL, options BLOB,        -- enumerated choices
  sla_deadline INTEGER, escalation_chain BLOB, -- §2.3
  raised_seq INTEGER NOT NULL REFERENCES event_log(seq), raised_by TEXT NOT NULL,
  resolved_seq INTEGER REFERENCES event_log(seq)   -- NULL while awaiting a human
);

-- negative knowledge / dead-ends — the high-ROI field (§1.3); rows, not a blob, so it's queryable
CREATE TABLE attempted_rejected (
  item_id BLOB NOT NULL REFERENCES work_item(id),
  seq INTEGER NOT NULL REFERENCES event_log(seq),
  approach TEXT NOT NULL, reason TEXT NOT NULL, PRIMARY KEY (item_id, seq)
);
```

The projection is **disposable**: rebuildable from `event_log` by replay. A projector bug never
loses data — fix the projector, store `projector_version` in a `meta` table, replay on startup
if stale. A projection schema change is a *rebuild*, not a data migration.

## 3.4 Queries (plain SQL over the projection; WAL snapshot reads never block the writer)

```sql
-- next-ready-task: actionable, unleased, deps satisfied, fresh, in budget, not human-gated
SELECT wi.* FROM work_item wi
WHERE wi.state IN ('Ready','Active') AND wi.gate <> 'supervised'
  AND NOT EXISTS (SELECT 1 FROM wi_lease l WHERE l.item_id=wi.id AND l.expires> :now)
  AND NOT EXISTS (SELECT 1 FROM wi_edge e JOIN work_item b ON b.id=e.to_id
                  WHERE e.from_id=wi.id AND e.kind=0 AND b.state NOT IN ('Closed','Cut'))
  AND NOT EXISTS (SELECT 1 FROM wi_edge e JOIN work_item b ON b.id=e.to_id
                  WHERE e.from_id=wi.id AND e.kind=1 AND b.state='assumptions-invalidated')
  AND NOT EXISTS (SELECT 1 FROM pending_decision pd
                  WHERE pd.item_id=wi.id AND pd.resolved_seq IS NULL AND pd.kind IN ('Decision','Approval'))
ORDER BY /* tier, critical-path weight, age, */ wi.created_seq, wi.id   -- stable tiebreak
LIMIT 1;   -- the SELECT + the lease INSERT happen in ONE writer txn → atomic claim, no double-work

-- human inbox: everything awaiting a human, with SLA — drives the badge/notification (constraint #2)
SELECT pd.*, wi.title FROM pending_decision pd JOIN work_item wi ON wi.id=pd.item_id
WHERE pd.resolved_seq IS NULL ORDER BY pd.sla_deadline NULLS LAST, pd.raised_seq;

-- "what is each agent doing right now": the live fleet view
SELECT l.holder_id, wi.id, wi.title, wi.state, l.heartbeat
FROM wi_lease l JOIN work_item wi ON wi.id=l.item_id WHERE l.expires> :now;

-- decision trace: the full causal fan-out of ONE human request (§1.5)
SELECT seq, ts, actor_id, event_type, subject_id, reason, model_fp, confidence
FROM event_log WHERE correlation_id= :corr ORDER BY seq;

-- staleness impact: which VerifiedDone work consumed an output that just changed (§1.7)
SELECT e.from_id FROM wi_edge e JOIN work_item w ON w.id=e.from_id
WHERE e.kind=1 AND e.to_id= :changed AND w.state='VerifiedDone';   -- → flag assumptions-invalidated
```

Cycle prevention on a `depends_on` insert: a recursive-CTE reachability check (`to_id` must not
already reach `from_id`) runs *inside the same transaction*; a cycle aborts the txn — the bad
edge is never written. (Markdown can only detect a cycle *after* it's been committed.)

## 3.5 Consistency / history model under human + multi-agent fan-out

1. **One linearizing writer (the Rust core).** Every mutation is a *command* over MsgPack RPC.
   The core validates → appends one `event_log` row → updates the projection → commits, all in
   one SQLite transaction. Event and projection can never diverge across a crash. Agents never
   hold a write connection, so `SQLITE_BUSY` write-contention never arises. Humans and agents
   use the **same command path** — the only asymmetry is *policy* (resolving a human-typed park
   requires `actor_kind = human`, enforced in the handler).
2. **Atomic claim** is the anti-double-work primitive (the SELECT + lease INSERT in one txn).
   Two agents calling `claim_next` are serialized; the second gets the next item. **No two
   agents ever run the same task** — which markdown and a CRDT cannot guarantee.
3. **Leases with TTL + heartbeat** handle the crashed agent: the lease expires, the item becomes
   claimable, and an event records the reclaim. **Compare-and-swap** (`expected_updated_seq` on
   field-edit commands) handles fine-grained concurrent edits — reject if the item moved since
   the agent read it; agent re-reads and retries.
4. **Idempotency** via the `event_id` ULID unique constraint: an agent retrying after a dropped
   RPC reply re-sends the same `event_id`; the writer no-ops the duplicate. Essential because
   agents retry aggressively and resume = re-execution (§2.2).
5. **History / time-travel / audit are structural, not bolted on.** The event log *is* the audit
   trail; "who/what/when/why" = `(actor_id, actor_kind, ts, reason)` on every event by schema;
   "what did the agent believe" = `(input_hash, data_age_s, model_fp)`; time-travel = replay to
   `seq = N`. This is the §1.1/§1.5 requirement satisfied by construction.

## 3.6 Where it lives + git diff-ability (without putting markdown back)

The binary `state.db` is a poor git citizen, but the owner's constraint is "not markdown for the
*store*," not "invisible in PRs." Reconcile both:

- **`<repo>/.textview/work/state.db`** is the live store (Rust-owned, WAL, `.gitignore`d).
- On commit, a hook (or the Rust core) exports **the event log only** to a deterministic,
  append-friendly **NDJSON sidecar** (`.textview/work/log.ndjson`, one event per line, ordered
  by `seq`, `merge=union` in `.gitattributes`). Because the log is append-only, **git diffs are
  additive** — new lines at the end, near-zero textual merge conflict. The binary db is rebuilt
  by replay on checkout.
- **Branch merges become log merges**: concatenate + re-sort by `(ts, event_id)` + replay.
  Conflicts are *semantic* (both branches resolved the same gate), surfaced as a state, not
  textual line-noise. App-Support holds only a cross-repo cache, never the source of truth.

This is the one place v1's "live in git with the diffs" instinct is preserved — but on the
*append-only event log* (which diffs cleanly) rather than on mutable markdown rows (which churn
and collide).

---

# PART 4 — THE IN-APP FEATURE (constraint #3)

Two surfaces over the *one* store: the **agent programmatic interface (MCP)** and the **human
oversight/steering UI.** Both are read/steer skins over the model — no second store, no second
transport.

## 4.1 The agent interface (MCP)

RPC verbs map 1:1 to commands; the UI and agents call the **same surface** (constraint #1 —
manipulable by both — satisfied by one command vocabulary, not two). All writes funnel through
the single Rust writer.

| MCP tool | Maps to | Notes / safety |
|---|---|---|
| `work_next` | the §3.4 ranked-head query | pure deterministic function of the store; survives compaction with zero memory |
| `work_get(id)` | projection read + **`handoff_packet`** | the rehydration view (§1.3) — resumption is a *read*, not a chat replay |
| `work_claim(id)` | atomic claim (lease) | CAS; second concurrent claimer gets the next item |
| `work_heartbeat(id)` | lease refresh | a missed heartbeat → lease expiry → reclaim |
| `work_transition(id, to, reason)` | a state edge | `reason` required; actor-kind-checked against the ownership table (§2.2) |
| `work_park(id, ParkReason, contract)` | `Active → Parked` | the agent self-suspends with a typed continuation (§1.2) |
| `work_set_check(id, check, lane)` | objective acceptance | **agent may set `testsPass`-class only**, must cite the lane; the check is hash-tracked (§1.4) |
| `work_record_decision(id, why, alternatives)` | append decision + `attempted_rejected[]` | the negative-knowledge write (§1.3) — the cheap high-ROI one |
| `work_propose_children(id, breakdown)` | create `Proposed` children | decomposition is gated; a human promotes |
| `work_create(...)` | new `Proposed`/`Idea` item | agents *file*, humans *promote* (never directly to `auto`/`Ready`) |

**Deliberately *not* exposed to the agent:** `humanAccepted`/`Approval` resolution, `* → Closed`,
`* → Abandoned` as a human decision, `Idea/Proposed → Ready` promotion, and direct state-set on
a human-typed `Parked`. These are the human-owned edges from §2.2; withholding them from the
MCP surface is how the autonomy boundary becomes *mechanical*, not advisory.

## 4.2 The human oversight UX — a control room, not a board

The reframe that makes the UI non-obvious:

> A board answers *"what is the state of the work?"* — a passive map you poll. A human
> supervising autonomous agents needs a different primary question answered: *"what, if
> anything, needs ME right now — and is anything running away while I'm not looking?"* The
> board's nouns (items, columns) go secondary; the *verbs* (an agent claimed, blocked on you,
> overran budget, thinks it's done) go primary. **Board = item-centric, pull-only. This =
> event-centric, push-first, gated** — driven by the event log, with the board as drill-down.

**Four surfaces, escalating attention** (match display intensity to how much the human must
care; never block the full screen — the human keeps doing their own work while the fleet runs):

```
AMBIENT ──────────▶ PROGRESS ──────────▶ ATTENTION ──────────▶ SUMMARY
toolbar pill        Work-tab feed         Decision Inbox        "while you were away"
"3 running,         live plan + per-agent the ONLY surface      digest on return
 1 awaiting you"    liveness gauges       that interrupts;       (12 moved, 3 PRs,
glance only         pull, no poke         batched, gated         1 abandoned, diff)
```

Only the **Decision Inbox** is allowed to interrupt, and even it batches. This is the answer to
the dominant failure mode (approval-for-everything cognitive overload that destroys the
efficiency gain): the autonomy `gate` *is* the notification filter — `auto` items run, succeed,
and advance with **zero** notification; only the first-class `Parked(human-typed)` state
(constraint #2) lights up the Inbox.

The five concrete views:

1. **Activity feed (the spine) — the event log rendered live.** The `event_log` *is* the UI
   datasource, not a board refresh. Reverse-chronological rows: actor · verb · item · liveness
   facts (attempt n/cap, token/budget burn, verifier lane). Filterable (by agent / item /
   decisions-only / failures-only); every row deep-links to the item. Color is signal:
   blue=normal, amber=retry/attention, red=blocked/over-budget, green=passed-a-gate. *Why it
   beats a board:* a card sitting in "In Progress" tells you nothing about whether the agent is
   progressing, looping, or 80% through its budget — the feed makes **liveness** (Part-1 §1.8/§1.9)
   a first-class stream a column cannot represent.

2. **Decision Inbox — a triage queue, not a chat.** Every `pending_decision` lands here as a
   *decision packet* (the question, the agent's enumerated options with its recommendation
   pre-highlighted, the context, the consequence) resolved with a **bounded verb set** (Accept
   recommendation / Pick alternative / Respond-with-constraint / Approve / Reject+note / Defer)
   — **not a free text box.** *Why a queue not a chat:* chat is single-threaded and amnesiac; a
   fleet generates *concurrent* blocks. A queue lets the human batch-triage parallel decisions
   at low cognitive load, and each packet carries its own durable `ResumeContract` (§1.2) so
   answering one needs no memory of the others. Answering writes a *value* into the contract →
   the system fires the resume signal → the item rehydrates and re-enters `work_next`
   automatically (§2.2). `humanAccepted`/`Approval` lives *only* here — the agent can never set
   it.

3. **"Next Up" — a reorderable, *explained* preview of agent intent.** The deterministic
   `work_next` head, shown as a drag-reorderable list with *why each ranked where it did* (tier,
   critical-path "unblocks 4"), and a greyed tail showing *why* an item is **not** pullable
   (supervised / dep-unmet / over-budget / stale). Dragging writes human-owned `tier`/`rank`; the
   selector respects it. The human steers the fleet by editing the one input the fleet reads —
   no mid-flight interruption. *Why it beats a backlog column:* a backlog is a pile; this is a
   steering wheel with its reasoning shown (opacity kills trust).

4. **Live Agent card — plan visibility + cheap, early intervention.** Click a running item →
   the agent's live plan (acceptance + steps), streaming tool-call log, and liveness gauges
   (attempt counter, budget burn-down, no-progress/declining-process-reward status, §1.8).
   Affordances, grounded in the multi-agent-steering finding that *early intervention beats
   late*: **Steer** (inject a constraint into the running context, non-destructively — keeps
   accumulated work), **Decompose** (split a too-big item via gated `work_propose_children`),
   **Intervene hard** (pause, reclaim the lease → item becomes re-pullable, or `Abandon`). Put
   the steer box *on* the card, not three clicks deep — the value of supervision collapses if
   the human only notices the runaway at the end.

5. **Roll-up tree + drift-lint badge.** The board-like surface survives as the *drill-down*, not
   the home view. Two agent-aware touches: parent status is **visibly derived** (a projection
   badge, never hand-edited), and a persistent **lint** badge surfaces the #1 failure mode —
   store-vs-reality drift (§1.1). When lint finds an item whose machine-checkable `acceptance`
   already holds in code (the real `DocumentState.{loading,error}` shipped-but-still-open bug
   from `BACKLOG.md`), it flags inline: "acceptance already true → mark Done/Cut?" The integrity
   layer made visible — the thing that keeps the store from quietly lying.

**Where it lands in the app:** a Work tab modeled on the code-review tool-window
(`Sources/ViewerUI/Review/ReviewIndexTab.swift`), reading `.textview/work/state.db` via
`ViewerCore`, feed sourced from `event_log`, Inbox/Next-Up driven by `work_next` +
`pending_decision`, agent writes via the existing MCP server, `humanAccepted` deliberately
UI-only. No new transport, store, or architectural surprise.

## 4.3 What this has that a board / GitHub Projects does not

| | Board / GitHub Projects | This agent-supervision feature |
|---|---|---|
| Primary surface | item grid (passive map) | event feed + Decision Inbox (push, gated) |
| Drives interaction | human polls it | it comes to the human, batched |
| "Blocked" | a column / label | first-class `Parked` + typed `ResumeContract` → triage queue |
| Progress | card sits in a column | live plan + tool log + **liveness gauges** (attempt/budget/no-progress) |
| "What's next" | a backlog pile | deterministic, **explained, reorderable** queue the fleet actually reads |
| Intervention | reassign / comment | **mid-flight steer** (non-destructive), gated decompose, reclaim lease, abandon |
| Acceptance | human attests, trust-based | `testsPass` (agent, lane-cited) ⊥ `humanAccepted` (human-only, structural) |
| "Why it decided" | buried in comments | decision trace + critical-path explanation in-UI |
| Integrity | none — drifts silently | lint badge flags store-vs-reality drift inline |

---

# PART 5 — OPTIONS, RECOMMENDATIONS, AND WHAT TO DELIBERATELY NOT BUILD

## 5.1 Genuine forks (with recommendations)

| # | Fork | Options | Recommendation |
|---|---|---|---|
| 1 | **SQLite binding from Rust** | (a) `rusqlite` crate · (b) bind `libsqlite3` C directly | **(a) `rusqlite`, pending your approval** — de-facto standard, thin, widely-used, well-maintained; the *one* new library this design adds. (b) is the zero-dep fallback (Swift already binds C this way) at the cost of hand-rolling the safe wrapper. |
| 2 | **Verifier for `ClaimedDone → VerifiedDone`** | (a) existing test lanes only · (b) test lanes + a reviewer *agent* judge · (c) + human | **(a) now, (b) soon, (c) always available.** Start with the cheapest uncorrelated signal (tests are already the gate); add a reviewer-agent judge for prose/intent acceptance once the loop is trusted; human acceptance is the always-present backstop for consequential work. The non-negotiable is *uncorrelated from the doer*. |
| 3 | **Branching attempts (§1.10)** | (a) single line now, model later · (b) first-class from day one | **(a).** Event-sourcing makes branches *cheap to add later* (alternate projections off a checkpoint) — so don't pay the modeling cost until best-of-N is actually in use. Reserve the capability; don't build the UI for it yet. |
| 4 | **`consumes[]` data-dep tracking (§1.7)** | (a) hand-declared · (b) auto-derived from the diff post-run | **Hybrid, (b)-leaning** (same call as v1's `touches` Option 6): hand-declaration is unverified-reliable; reconcile declared `consumes`/`files` with the worktree's actual post-run diff. An agent that consumes an undeclared output breaks the invalidation guard. |
| 5 | **Decision auto-apply timeout** | (a) block-until-ack · (b) apply default after timeout | **Per-item field, default block-until-ack.** A wrong default applied autonomously is a silent one-way door. **Timeout never auto-approves** (§2.3) — it escalates or loudly abandons. |
| 6 | **Cross-machine sync** | (a) none (single-writer SQLite) · (b) CRDT layer later | **(a) for v1.** The single linearizing writer is *required* for `Parked`/lease/dep correctness. Keep CRDT in the back pocket strictly for multi-machine sync, never as the v1 substrate (it can't guarantee single-lease-winner). |

## 5.2 What to deliberately NOT build

Inherited from v1's anti-bloat (still correct — team-coordination ceremony that vanishes at
n=1-human): **no story points / velocity / burndown / sprints; no WSJF/ICE/RICE auto-priority
scoring** (keep `tier`+`rank` human-set; a formula launders judgment into false objectivity);
**no SaaS / daemon / web UI / RBAC / multi-user real-time sync; no configurable per-type
transition graphs** (config creep is the most-cited tracker failure).

New to v2 — things the research *could* tempt you into that you should *not* build for a solo
dev + agents:

- **No general workflow engine (Temporal/LangGraph as the execution substrate).** Import the
  *concepts* (signal/await, checkpoint, compensation, retry-as-policy) as the `Parked`
  mechanics — but constraint #1 demands a *permanent, manipulable store* the human and agent
  edit out-of-band, which a persisted state machine serves and an ephemeral workflow-instance
  engine does not. The state machine is the right model precisely because the item outlives any
  single agent run.
- **No blockchain / external notarization for the audit trail.** The in-DB hash chain + an
  optional periodic signed checkpoint gives tamper-evidence and non-repudiation at solo scale.
  A distributed ledger is pure ceremony here.
- **No ML confidence *scoring* model.** Confidence is a routing input (§1.8), but at solo scale
  it's the *agent's calibrated self-estimate + the human's editorial gate adjustment* (promote a
  trusted class `gated → auto` as it earns trust) — **not** a trained scorer. v1's "no false
  objectivity" rule applies to confidence too.
- **No premature multi-tenant / per-user-repo productization.** Build it as repo tooling for
  *this* project first; only consider surfacing it as a shippable app feature for users' own
  repos after the model has proven itself across a few real waves. (v1's "attractive trap" flag,
  reaffirmed.)

## 5.3 The sharp / uncertain parts (don't pretend they're solved)

1. **Drift between store and reality remains the #1 failure mode** — now *mitigated* (not
   eliminated) by hash-tracked `context_refs` (§1.1), executable `acceptance` (§1.4), and the
   lint badge (§4.2.5). Where acceptance is only prose, drift is still possible; that residue is
   the most likely thing to undermine the whole system.
2. **`consumes[]` completeness** (Option 4) — the invalidation guard is only as good as the
   declared/derived data edges.
3. **Calibrating agent confidence (§1.8)** — agents are systematically overconfident; how well a
   *calibrated* estimate can be extracted in practice is genuinely uncertain, and the whole
   escalation-trigger rides on it. Best guess: start conservative (low threshold → park often),
   loosen as the loop proves out.
4. **Idempotency of pre-park effects (§2.2)** — resume = re-execution; if any agent side-effect
   isn't idempotent, the requeue double-applies. This is a hard contract on *agent* behavior the
   store can detect (idempotency keys) but not fully enforce.
5. **"One agent run" granularity** — `size`/budget is a guess at whether work fits one run before
   compaction; wrong-high → the agent stalls with no clean `ClaimedDone` boundary. No clean
   a-priori metric; calibrated by experience, mitigated by letting an agent propose a split.

---

## Consolidated sources

**Repo-resident prior art:** `docs/PROJECT_MANAGEMENT_DESIGN.md` (v1 — superseded on the three
constraint axes), `BACKLOG.md`, `docs/research/next-priorities-2026-05-31/`,
`Sources/ViewerCore/SQLite/SQLiteReader.swift` (existing `libsqlite3` link), the committed Rust
core (`serde` + `rmp-serde`, length-prefixed binary RPC), `Sources/ViewerUI/Review/ReviewIndexTab.swift`.

**Store / event-sourcing / consistency:** [ESAA — Event Sourcing for Autonomous Agents](https://arxiv.org/pdf/2602.23193) · [ESAA-Security — verifiable event-sourced agent audits](https://arxiv.org/pdf/2603.06365) · [Event Sourcing (Azure)](https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing) · [SQLite WAL & concurrency](https://sqlite.org/wal.html) · [single-writer transactions](https://www.bugsink.com/blog/database-transactions/) · [git-sqlite text-export pattern](https://ongardie.net/blog/sqlite-in-git/) · [CodeCRDT — observation-driven multi-agent coordination](https://arxiv.org/pdf/2510.18893) · [OT vs CRDT](https://www.taskade.com/blog/ot-vs-crdt).

**Staleness / drift / provenance:** [The Stale World Model Problem in Long-Running Agents](https://tianpan.co/blog/2026-04-10-stale-world-model-long-running-agents) · [Decision Provenance in Agentic Systems](https://tianpan.co/blog/2026-04-19-decision-provenance-agentic-systems) · [Multi-agent outputs & enterprise audit (Augment)](https://www.augmentcode.com/guides/multi-agent-outputs-n-pass-enterprise-audit) · [Intent — living spec, reviewer agents, drift](https://www.augmentcode.com/tools/claude-code-agent-teams-vs-intent).

**Memory / compaction / negative knowledge:** [Context Compaction (Redis)](https://redis.io/blog/context-compaction/) · [Compaction memory (Claude Code/Codex)](https://gist.github.com/sigalovskinick/e2e329bb37ecc74b9f15d5ba74ee1ee5) · [Memory for Autonomous LLM Agents / negative knowledge](https://arxiv.org/html/2603.07670v1) · [Recycling search experience](https://arxiv.org/pdf/2601.21684) · [Trajectory-grounded compaction (Slipstream)](https://arxiv.org/html/2605.08580).

**Verification / reward hacking / done-as-earned:** [Reward Hacking Benchmark](https://arxiv.org/html/2605.02964) · [LLMs Gaming Verifiers (RLVR reward hacking)](https://arxiv.org/pdf/2604.15149) · [Acceptance criteria & independent judge](https://github.com/NousResearch/hermes-agent/issues/356) · [SWE-agent ACI](https://arxiv.org/pdf/2405.15793) · [SWE-Gym verifiers](https://arxiv.org/html/2412.21139v1) · [SWE-TRACE process reward](https://arxiv.org/html/2604.14820v1) · [Output-level feedback fails for coding agents](https://arxiv.org/pdf/2603.26942).

**Blocked-as-continuation / HITL / durable workflow:** [Temporal — beyond state machines](https://temporal.io/blog/temporal-replaces-state-machines-for-distributed-applications) · [Temporal saga compensation](https://temporal.io/blog/compensating-actions-part-of-a-complete-breakfast-with-sagas) · [Temporal durable HITL](https://learn.temporal.io/tutorials/ai/building-durable-ai-applications/human-in-the-loop/) · [LangGraph interrupts (interrupt/Command resume, replay)](https://docs.langchain.com/oss/python/langgraph/interrupts) · [Google ADK pause/resume](https://developers.googleblog.com/build-long-running-ai-agents-that-pause-resume-and-never-lose-context-with-adk/) · [HITL patterns for high-stakes decisions](https://dev.to/omnithium/human-in-the-loop-patterns-for-high-stakes-ai-agent-decisions-1fg6) · [BPMN catch/message events](https://camunda.com/bpmn/reference/).

**Dependencies / staleness propagation / planning:** [How Bazel works (DAG, caching, CAS)](https://www.gocodeo.com/post/how-bazel-works-dependency-graphs-caching-and-remote-execution) · [Cache invalidation strategies](https://scopeforged.com/blog/cache-invalidation-strategies) · [HTN planning & decomposition](https://en.wikipedia.org/wiki/Hierarchical_task_network) · [PDDL preconditions/effects + replanning](https://en.wikipedia.org/wiki/Planning_Domain_Definition_Language) · [Airflow idempotency / backfill / lineage](https://bix-tech.com/process-orchestration-with-apache-airflow-a-practical-guide-to-building-reliable-scalable-data-pipelines/) · [OpenLineage provenance](https://medium.com/@sendoamoronta/open-lineage-in-modern-data-platforms-advanced-pipelines-with-dbt-and-airflow-59a4172ac52e).

**Confidence / escalation / coordination:** [Agentic overconfidence](https://arxiv.org/html/2602.06948) · [Uncertainty-aware deferral](https://beancount.io/bean-labs/research-logs/2026/07/01/redact-uncertainty-aware-deferral-llm-agents) · [Uncertainty propagation](https://arxiv.org/html/2604.23505v1) · [Blackboard architecture in agentic AI](https://data-flair.training/blogs/blackboard-architecture-in-agentic-ai/) · [LLM blackboard multi-agent](https://arxiv.org/pdf/2510.01285) · [Stigmergy / digital pheromones](https://dev.to/naveentvelu/introducing-sbp-multi-agent-coordination-via-digital-pheromones-2j4e).

**Cost / budgets / loops / branching:** [The Token Budget Pattern](https://dev.to/askpatrick/the-token-budget-pattern-how-to-stop-ai-agent-cost-surprises-before-they-happen-5hb3) · [Token inflation / negative-margin loops](https://futureisnow.in/autonomous-ai-agent-cost-analysis-managing-token-inflation-and-negative-margin-loops/) · [Common agent failure modes](https://agentwiki.org/common_agent_failure_modes) · [ConTree — git-like branching / MCTS](https://contree.dev/) · [Adaptive Branching MCTS](https://arxiv.org/pdf/2503.04412).

**In-app human+agent UX:** [Agent status monitoring (four-layer pattern)](https://www.aiuxdesign.guide/patterns/agent-status-monitoring) · [Interactive debugging/steering of multi-agent systems](https://arxiv.org/html/2503.02068v1) · [The Agentic Inbox (decision queue)](https://slavakurilyak.com/posts/agentic-inbox) · [Linear — AI agents](https://linear.app/docs/agents-in-linear) · [Designing for AI agents — UX patterns 2026](https://mantlr.com/blog/designing-for-ai-agents-ux-patterns-2026) · [Redis — AI human-in-the-loop production patterns](https://redis.io/blog/ai-human-in-the-loop/).
