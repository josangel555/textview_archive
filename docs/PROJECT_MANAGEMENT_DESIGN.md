# Project Management Design — solo dev + AI agents, full SDLC

> **Status: WHAT-first exploration.** This document decides *what to build* before
> *how*. Part 1 (the model) is the focus and is meant to be argued over and ratified.
> Part 2 (how it fits the app) is deliberately light — a sketch to be detailed only
> **once the WHAT is agreed**. Nothing here is committed to code yet.
>
> Synthesized from: a holistic problem-space analysis grounded in this repo's own
> working corpus (`BACKLOG.md`, `docs/research/next-priorities-2026-05-31/`), a survey
> of how real trackers model work (Jira/Linear/Azure/Shortcut/Asana/Taskwarrior/
> org-mode/todo.txt/Backlog.md/spec-kit), the agent-centric literature on durable state
> and autonomy boundaries, a pressure-test of the owner's type/lifecycle sketch, and a
> persistence/queue design validated against git's merge behaviour and event-sourcing
> patterns. Sources are listed at the end of each major section.

---

# PART 1 — THE PROBLEM + WHAT TO BUILD

## 1.0 Why this exists (read this first)

The "manage the work" problem **is already being solved by hand here, every wave, and
badly served by the medium.** The evidence is in this repo:

- `BACKLOG.md` (~36 KB) — strikethrough-`DONE`, prose status, `(commit abc123)`
  provenance, "decisions waiting" buried in item bodies, `OWNER DECISION:` markers
  inline. It already *lies* in places (e.g. `DocumentState.{loading,error}` shipped but
  still listed open) — a data-integrity drift bug.
- `docs/research/next-priorities-2026-05-31/PRIORITIZED_PLAN.md` — a hand-built
  dependency **DAG in ASCII**, tiers (T0 foundations → T1 quick-win → T2), a per-item
  size/files/dep table, a primed-vs-unprimed analyst split.
- `WAVE_2_QUEUE.md` — "decisions baked as **DEFAULTS**," a "launch trigger," and a
  **"Deferred OUT of the auto-queue — needs explicit go / supervision"** section.
- `.claude/worktrees/wf_*` + `scheduled_tasks.lock` — workflows already fan out to
  per-workflow git worktrees branched off the `main` tip.

So the entities below are **not invented** — they are named the way this project already
works, just made *durable and machine-readable* instead of re-derived from a 36 KB prose
blob every session. The whole point: a fresh or context-compacted agent should
reconstruct "where is everything and what's safe to do next" by **reading state**, not
by re-parsing prose.

The non-obvious load-bearing insight, straight out of the existing `WAVE_2_QUEUE.md`:
**the autonomy boundary is the hard part, and it is a first-class data field, not a
vibe.** That file already encodes it three ways — "baked defaults," "open questions to
confirm at launch," and "deferred OUT of the auto-queue (needs supervision)." That
tripartite distinction *is* the spec for how far an agent may drive alone.

## 1.1 The problem space: solo dev + AI vs team PM

"Managing the work" here is **four jobs** that today live in one prose blob and get
re-derived each session:

1. **Decomposition** — a large thing → nested sub-things small enough for one agent run.
2. **Lifecycle tracking** — where each thing is in its dev journey, *durably*, so a fresh
   agent reconstructs state without re-reading everything.
3. **Prioritization + readiness** — what is the *next* thing that is both worth doing and
   *safe / unblocked* to do right now.
4. **Autonomy boundary** — how far an agent drives before it MUST stop for the human, and
   how that stop is recorded so the next agent doesn't blunder past it.

### How this differs from team PM (the core reframe)

Human PM tools model work for **coordination between people who already know how to do
the work and remember what they did.** An autonomous agent has *neither* property: it has
no persistent memory (every session is potentially a fresh hire that has read nothing)
and no intrinsic judgment about what it's allowed to do. Two things humans carry in their
heads must be **externalized into durable, machine-readable state outside the context
window**: *"what was I doing and why"* (resumption) and *"am I allowed to do this without
asking"* (the autonomy boundary).

| Dimension | Team PM (Jira/Linear/board) | This model (solo dev + AI) |
|---|---|---|
| Source of "where am I" | Person's memory + ticket as reminder | **Persisted state is canonical**; transcript is disposable |
| Ticket content | A pointer; human fills gaps from tribal knowledge | **Self-contained context bundle** — files, constraints, acceptance — agent has no tribal knowledge |
| "Done" | Human attests; trust-based | **Evidence-backed**, machine-checkable; self-report untrusted (agents hallucinate completion) |
| Task sizing | Sized to human attention / sprint | Sized to **token budget + verifiability** — fits one agent run or is checkpointed |
| Next-task selection | Human judgment; takes ambiguous high-value work | **Deterministic, explainable selector** that *prefers clarity*; ambiguous work routes back to human |
| Retries / loops | Implicit, self-limiting (humans get bored) | **First-class attempt accounting + hard caps** or the agent loops forever |
| Blocked | Soft state, human nudges | **Hard state with a reason code** routing to agent-retry vs human-resolve |
| Approval model | Org process, socially enforced | **Encoded as gated transitions** keyed on reversibility/blast-radius; mechanically un-skippable |
| Audit / "why" | In heads, Slack, review comments | **Decision log is a required artifact** — the only place "why" survives compaction |

The throughline: **team PM optimizes for coordination + reminding; agent PM optimizes for
durable externalized cognition + mechanical safety gating.** The board's *shape* barely
changes (tasks, states, deps, priorities all survive) — but every field shifts from
"hint for a human who'll fill in the rest" to "complete, machine-checkable contract for a
stateless worker who won't."

## 1.2 What real tools model — the essential core vs the overhead to AVOID

A survey across the spectrum (todo.txt → Taskwarrior → org-mode → Backlog.md → spec-kit →
Linear → Shortcut → Asana → Azure DevOps → Jira) converges hard on two findings:

1. **Almost all the "hierarchy" in heavyweight trackers exists to coordinate humans
   across teams** — roll-up reporting, capacity planning, sprint ceremonies, RBAC. Strip
   the humans-coordinating-humans layer and the essential core collapses to ~8 fields
   shared by every tool, big and small.
2. **The single most transferable idea for an AI workflow is not the hierarchy — it's the
   automatic "what's next" computation.** Taskwarrior nails it with an *urgency
   polynomial* (weighted scoring); spec-kit nails it with a *dependency-ordered task list
   with `[P]` parallel markers* (a topological DAG). Everything else is bookkeeping.

### The genuinely-universal core (~8 fields)

| Field | Universal form | Note |
|---|---|---|
| **id** | stable handle | for cross-refs / commit links |
| **title** | one line | the only other thing Linear *requires* besides status |
| **status** | small enum | converges on Todo / In-Progress / Done (+ optionally Blocked, Cancelled) |
| **priority** | 3–5 levels | Linear's Urgent/High/Med/Low/None is the sweet spot |
| **body / description** | freeform | + acceptance criteria as a checklist |
| **dependencies** | `blocked-by` edges | the *one* relation that actually changes what you can do next |
| **parent** | single link | enough to express hierarchy as a tree; you rarely need named "epic/story" *levels* |
| **labels/tags** | many | the universal escape hatch — replaces most custom fields |

### What to DELIBERATELY NOT build (anti-bloat)

This is team-process overhead that **vanishes without a team**. Building it at n=1-human
is pure ceremony:

- **No named multi-level hierarchies (Epic/Feature/Story/Sub-task ladders).** They exist
  for roll-up reporting to management and cross-team RBAC. We need at most **parent-child
  nesting** (and shallow at that). Shortcut's flat *Story + a type field* is the better
  lightweight pattern than a tall fixed tree.
- **No story points / velocity / burndown / sprints / iterations / cycles.** Time-boxing
  is a commitment ritual for teams; the AI doesn't get tired on Fridays. There is no
  velocity to forecast. Coarse `size: S/M/L` beats Fibonacci theater — and it exists only
  as a "fits one agent run?" proxy, never for planning math.
- **No automatic priority scoring (WSJF/ICE/RICE).** Prioritization here is *editorial
  judgement the owner already exercises* (the tiers are hand-reasoned: "foundations are
  one-way doors, do first"). A scoring formula would launder that judgement into false
  objectivity. Keep `tier`+`rank` human-set; the agent *respects* it, doesn't *compute* it.
- **No SaaS / DB / daemon / web UI / real-time multi-user sync / RBAC / assignment-as-a-
  system / notifications-as-a-system / time-tracking-for-compliance.** All multi-actor
  coordination apparatus. One human + stateless agents. "Assignment" degenerates to a
  claim field (`owner`/`worktree`); the `log[] + commits[]` trail is enough provenance.
- **No configurable workflow state machines (Jira-style per-type transition graphs).**
  One fixed lifecycle. Configurability *is* Jira's most-cited failure mode ("config
  creep"); for a solo tool it's a procrastination vector, not a feature.

> Sources: Jira issue types/status categories; Linear conceptual model/priority/estimates/
> triage; GitHub Projects v2 fields; Azure DevOps work items + state transitions; Shortcut
> story details; Asana object hierarchy; Taskwarrior urgency/UDAs; org-mode Edna/depend;
> todo.txt format; Backlog.md; spec-kit tasks template; TASKS.md.

## 1.3 RECOMMENDED model for THIS use case

### 1.3.1 Entities

```
PROJECT (the repo — implicit, == AGENTS.md / CLAUDE.md context)
  └── ITEM (the one unit; recursive — an item may have child items)
        ├── identity:    id, title, parent
        ├── type:        Feature | Bug | Chore                  (kind-of-work, §1.3.3)
        ├── lifecycle:   status (state machine, §1.3.4)
        ├── priority:    tier (0/1/2…) + intra-tier rank        (human-set, §1.3.6)
        ├── readiness:   depends_on[]   (HARD: ordering — can't START until these are done)
        │                touches[]      (SOFT: contention — don't RUN concurrently)
        ├── autonomy:    gate (auto | gated | supervised)        ← load-bearing (§1.3.7)
        │                decisions[]    (open questions w/ a recommended default)
        ├── sizing:      size (S/M/L)   — "fits one agent run?" proxy, NOT planning math
        ├── grounding:   files[], design_doc, acceptance (verifiable "done", incl. WHICH lane verifies)
        ├── claim:       owner, lease_until   (CAS claim for human/agent concurrency)
        └── provenance:  commits[], worktree, log[] (append-only event trail)
```

**One recursive `ITEM` type, not separate epic/story/task tiers.** The real tree here is
shallow and irregular (a "wave" contains items; an item like *session independence* fans
into R1–R3 sub-items). A fixed 3-level taxonomy would fight that. Depth is whatever the
work is — but keep it **shallow in practice (2 levels typical, parent + leaf)**.

Agent-specific entities worth their keep beyond the human-PM core, because the worker is a
stateless LLM:

| Entity / field | Agent-specific reason |
|---|---|
| **attempts[]** (n, outcome, failure-class, cost) | Agents retry; retries are where runaway happens. Enables the attempt-cap circuit breaker. Humans never track "my 4th attempt at this subtask." |
| **acceptance** (machine-checkable, names its lane) | The correctness contract. Without a checkable success condition the agent can't know when to stop. Must encode *which* lane verifies it (host headless gate vs VM-only vs `/verify`). |
| **decisions[]** + **log[]** | The decision log is the only place "why / alternatives rejected" survives compaction. |
| **context bundle** (files, constraints, prior findings) | A fresh agent has no tribal knowledge; the item must be self-contained. |
| **owner / lease_until** | Multi-agent: prevents two agents grabbing the same item; a crashed agent's lease expires and the item is reclaimable. |

### 1.3.2 Relationships — and why each is mandatory

| Relationship | Why it's mandatory *here* |
|---|---|
| `parent` (nesting, strict **tree**) | Decomposition + roll-up status + "drive the next leaf under this epic." |
| `depends_on` (**hard** DAG edge) | The plan *is* a DAG. An agent must not pull a blocked item. The one issue-tracker primitive you cannot omit. |
| `touches` (**soft** contention edge) | The most specific thing about *this* setup. Plans split waves by "hot files" (`DocumentModel`, `SidebarView`, `TabBar`); Stage 2a is "new-file-heavy, disjoint" *precisely* so worktrees don't collide on merge. The scheduler must not run two agents that both own `DocumentModel.swift`. **No generic tracker models this.** |
| `gate` + `decisions` | The autonomy boundary (§1.3.7). |

The crux: **`depends_on` vs `touches` are different axes, on separate edge sets.**

```
  depends_on : ORDERING      — A must finish before B starts        (a DAG; tree-cross OK; acyclic)
  touches    : CONCURRENCY    — A and B must not RUN at once, either order (contention set)
  parent     : CONTAINMENT    — B is part of A                       (a strict tree)
```

Conflating ordering with concurrency either over-serializes (slow) or merge-explodes (the
124 GB-worktree lesson territory). Conflating containment with dependency is the classic
modeling error — different edges, different algorithms (tree walk for roll-up, topological
sort for readiness).

### 1.3.3 Work-item TYPES — verdict on the `Feature / Bug / Backlog / Wishlist` sketch

**Verdict: keep the idea of explicit types, but the sketch is mis-cut.** Those four are
not the same *kind* of thing:

- `Feature` and `Bug` answer **"what kind of work is this?"** → a real *type* axis.
- `Backlog` and `Wishlist` answer **"how committed am I / how far out is it?"** → that's a
  *horizon/state* axis, not a type. Folding them in means a not-yet-scheduled bug has no
  clean representation (is it `Bug` or `Backlog`? — can't say both).

Every mature tool keeps **type**, **state**, and **horizon** as separate axes; Linear
deliberately collapses *type* almost to nothing (one issue type + labels) and invests in
states + priority instead — the strongest precedent for a solo context.

| Change | Decision |
|---|---|
| ✅ Keep | Having explicit types; `Feature` and `Bug` |
| ❌ Drop as types | `Backlog`, `Wishlist` — they're **horizon/state**. Move to lifecycle states `Todo` / `Idea`. |
| ❌ Add | **`Chore`** — the missing one. This repo's backlog is *full* of refactor/build-hygiene/dep/test-infra/docs items (Bundle-size guard, Third-party attribution, JSONFileStore refactor, EditorCoordinator extraction). They're neither Feature nor Bug; lumping them under Feature pollutes any "what did I ship for users" view. |

**Recommended: 3 fixed types — `Feature` / `Bug` / `Chore`** (the proven Pivotal Tracker
minimal cut, which maps almost exactly onto how this project already works). Three is the
floor (below it you lose the user-facing-vs-not signal); don't go above it (Epic/Story is
hierarchy, handled by `parent`, not by types). **Types are fixed in code, not
configurable** — a solo dev has no team-coordination problem that justifies custom types.

### 1.3.4 The lifecycle STATE MACHINE — verdict on `Idea → Groomed → Impl → Tested → Validated`

**Verdict: directionally right, but one state too many on the front and one too few in the
middle.** `Groomed` and the split `Tested`/`Validated` try to encode an agile *team
ceremony* that doesn't exist when the "team" is one human + an agent. State-by-state:

- **`Idea` → keep**, but recognize it *is* the wishlist horizon (entry state, no commitment).
- **`Groomed` → cut it as a state; make it a transition GATE.** In Scrum "Groomed/Ready"
  exists because work is handed from a product owner to a *separate dev team* — it marks
  "enough info for a stranger to pick up cold." Solo dev + AI has no such handoff: either
  you're about to brief the agent (grooming = writing the spec, which is the *first action*
  of "in progress," not a parking state) or the agent groomed it (you need an *approval
  gate* before it codes — a transition guard, not a resting state). So model what grooming
  *produces* (an `acceptance` spec field) plus a **human-approval guard on the
  start transition** — not a durable `Groomed` box that's just dead air. This matters
  *more* with an AI agent than it ever did for human teams (a vague item gets implemented
  into the wrong thing), but the cure is a required `acceptance` field on the transition,
  not a state.
- **`Implementing` → keep, rename `In Progress`** ("implementing" is too coding-specific;
  a chore or spec-write is also in progress). The one state the agent legitimately *owns
  and drives*.
- **`Tested` + `Validated` → collapse into one `In Review` state with TWO independent
  acceptance flags.** This is the most important fix. The two aren't sequential — they're
  *independent acceptance dimensions* that both gate `Done`:
  - `testsPass` — **automated checks green** (agent-owned, objective, must cite the lane:
    `bash scripts/test-headless-gate.sh`, the VM lane, or `/verify`).
  - `humanAccepted` — **a human confirmed it does the intended thing** (human-owned,
    subjective; the agent must **never** self-certify this — that's the rubber-stamp trap).

  Modeling them as two serial states implies a linear march and blurs exactly the
  agent-vs-human ownership boundary that is the whole game. One `In Review` state holding
  two checkboxes is truer and makes the boundary explicit. (Mirrors the broader agent
  pattern: *probabilistic work, deterministic routing* — agent does the work + objective
  checks; the "is it actually accepted" routing stays on a human-owned gate.)

This also matches what the repo *already does informally* and *what it needs but lacks*:
`BACKLOG.md`'s real lifecycle is brutally simple (pending bullet → `~~struck~~` + SHA when
done, or annotated `Cut`/`Deferred`). The 5-state sketch is heavier than what works today
— a red flag. But the agent-readiness literature flags the two things flat markdown
*can't* gate on and that an autonomous loop genuinely needs: **machine-checkable
acceptance + evidence links**, and **attempt/loop accounting + the gated-transition
table**. If you formalize anything, formalize those.

#### Recommended lifecycle

```
                 ┌──────────────── (cut / won't do) ────────────────┐
                 │                                                    ▼
  ┌──────┐   ┌────────┐   [start gate:        ┌─────────────┐     ┌──────┐
  │ Idea │──▶│  Todo  │───▶ acceptance filled  ─▶ In Progress │────▶│ Done │
  └──────┘   └────────┘    + (gate≠supervised) └─────────────┘     └──────┘
   (= wishlist) (= backlog;                       │      ▲             ▲
    no commit)   committed,                        │      │   both flags pass:
                 prioritized)                      ▼      │   testsPass ✓ (agent)
                                              ┌──────────┐│   humanAccepted ✓ (you)
                                              │ In Review ├┘
                                              └──────────┘
                                              fail either → back to In Progress

  Blocked-on-human is a derived flag on Todo/In-Progress (open decision OR gated/supervised
  approval pending), NOT a separate status — see note below. Cut is terminal-but-kept.
```

States: **`Idea → Todo → In Progress → In Review → Done`**, plus terminal **`Cut`**
(reachable from any pre-Done state; kept for audit, not deleted).

- **`Idea`** — captured, no commitment (the old `Wishlist`).
- **`Todo`** — committed and prioritized; the backlog you actually pull from (the old
  `Backlog`). `Idea → Todo` *is* the "I've decided to do this" act.
- **`In Progress`** — actively worked. **Entering it requires the `acceptance` field
  filled** (this is the grooming artifact; the gate replaces the `Groomed` state).
- **`In Review`** — work claims complete; holds `testsPass` (agent) + `humanAccepted` (human).
- **`Done`** — terminal; both flags true; record the commit SHA(s).
- **`Cut`** — terminal "won't do." Make it real so cut items leave active views but stay
  auditable — and so `lint` can flag items whose `acceptance` already holds in code (the
  `DocumentState.{loading,error}` drift bug) as should-be-`Done`/`Cut`.

> **One subtlety the model must respect: "blocked-on-human" ≠ "deps unmet."** Deps-unmet
> is just `Todo` that isn't *ready* yet (computed, §1.3.5). "Blocked-on-human" (an open
> `decision`, or a `gated`/`supervised` approval pending) is the **exit condition that
> should ping you**. Collapsing the two is the classic failure: the agent can't tell "wait
> for code" from "wait for Jos," so it either spins or interrupts for nothing. Represent it
> as a **derived readiness flag + an `awaiting` reason code**, not as an extra status box.

#### Who/what may transition (the axis the sketch was missing entirely)

The original sketch is silent on **ownership of transitions** — and that, not the state
count, is what makes a lifecycle safe to hand an autonomous agent. Make it first-class data:

| Transition | Owner | Why |
|---|---|---|
| `Idea → Todo` (commit) | **Human** | Prioritization/commitment is judgment; an agent committing its own ideas = scope creep. |
| fill `acceptance` (the grooming) | **Agent may draft, human approves** | The real grooming; approval is the guard. |
| `Todo → In Progress` | **Either** | Human starts it, *or* an autonomous agent pulls the top ready `Todo` — but **only if `acceptance` is filled** and `gate≠supervised`. |
| `In Progress → In Review` | **Agent** | Agent signals "I think it's done." |
| set `testsPass` | **Agent** (must cite the lane that proved it) | Objective, reproducible, auditable. |
| set `humanAccepted` | **Human ONLY** | The agent must never self-certify. Hard, structural rule. |
| `In Review → Done` | **System** (auto when both flags ✓) | Deterministic AND gate; no judgment. |
| `In Review → In Progress` (kickback) | **Either** (agent on test fail, human on rejection) | Failure path. |
| `* → Cut` | **Human** | Abandoning work is a commitment decision. |

Principle (from the deterministic-agentic-workflow literature): **agents own the *doing*
and the *objective checks*; humans own *commitment*, *acceptance*, and *abandonment*.**
Encode it as data so an autonomous loop *cannot* skip a human gate even when instructed to
— the gate is structural, not a politeness.

#### Fixed or configurable?

**Fixed states, fixed types — for v1 and probably forever for a solo tool.** This is the
clearest finding in the survey and it cuts against the instinct to be flexible. Linear's
whole thesis (and why it's the consensus solo/small-eng pick) is that **opinionated fixed
workflows beat configurability**. The one safe concession both Linear and Azure DevOps
make: **states are fixed but each maps to a fixed *category*** (Backlog / Unstarted /
Started / Completed / Cancelled). Code, roll-ups, and agent gates key off the *category*;
the visible name is cosmetic. So *if* customization is ever wanted, allow **renaming
states within a fixed category set — never adding a new category.** That keeps every
automation working regardless of cosmetic names. Don't build configurability now.

### 1.3.5 Hierarchy + progress roll-up

**Leaf vs parent asymmetry is the whole game.** A leaf's `status` is *authored* (a human
or agent declares it). A parent's `status` and `progress` are **derived** from children
and must never be hand-edited — two writers for one value = unresolvable conflict. The
parent is a *projection, not a record* (mirrors Azure DevOps exactly: any child "Doing"
→ parent "Doing"; all children "Closed" → parent "Closed").

**Roll-up rule A — `status` (deterministic lattice, evaluated in order):**

```
parent.status =
  Done         if ALL children Done (or Done/Cut)
  blocked*     if ANY child blocked-on-human AND none In-Progress   (*surfaces stuck subtrees; derived flag)
  In Progress  if ANY child In Progress
                  OR (SOME Done AND SOME not-done)                  (mixed ⇒ started)
  Todo         otherwise (all children Todo/Idea)
  Cut          only if explicitly set on the parent itself          (sticky, parent-authored)
```

- **Mixed children ⇒ In Progress.** Partial completion means work has begun.
- **`Done` requires unanimity** (treating `Cut` as satisfied). One open child keeps the
  parent open — the invariant people actually want.
- **A parent's *human acceptance* is separate from its children's.** All children `Done`
  gets a parent *eligible* for review — it does **not** auto-`Done` it. You can have every
  part done and still reject the assembled whole. So the parent still passes through its
  own `In Review`. This is the case naive "auto-close parent when children done"
  automation gets wrong.

**Roll-up rule B — `progress` (weighted metric, optional):**

```
leaf.progress   = 1.0 if Done/Cut else (authored estimate or 0.0)
parent.progress = Σ(child.progress × child.weight) / Σ(child.weight)   (equal weight if no size)
```

`status` and `progress` are **independent projections** — a parent can be `In Progress` at
`progress = 0.95`. Don't derive one from the other.

**Where roll-up lives: derived, never persisted as source of truth.** Store only leaf
authored state + edges; compute parent values on load (single bottom-up DFS, O(n)).
*Optionally* cache the computed value in the parent file for human readability, but mark
it clearly derived and recompute-on-write. Persisting a derived field as authoritative
reintroduces the two-writer conflict and lets the cache drift — the cardinal sin here.

**Keep hierarchy shallow — 2 levels typical.** Jira's 3 fixed levels already confuse real
teams; a solo dev wants the minimum. Don't build arbitrary-depth trees as a feature even
though the `ITEM` type is recursive.

### 1.3.6 Priority + dependencies + the "next ready task" queue

**Priority is an orthogonal attribute, never a state** (the states-vs-attributes rule).
Keep it human-set: `tier` + intra-tier `rank` (this repo's hand-reasoned tiers). The agent
*respects* it, doesn't compute it (see anti-bloat: no auto-scoring).

The queue is a **filter-then-rank** pipeline — and because *both a human UI and an agent*
(possibly in CI/headless) consume it, it must be a **pure, deterministic, explainable
function**: same item set ⇒ same ordering on any machine. Pin a stable final tiebreak or
you get an agent and a human disagreeing about "the next task."

```
                 ALL ITEMS
                    │
        ┌───────────┴─────────────────────────────────┐
        │ FILTER (candidate iff ALL hold):             │
        │   1. leaf (parents are containers)           │
        │   2. status ∈ {Todo, In Progress}            │
        │   3. gate ≠ supervised  AND no open decision │   ← autonomy gate
        │   4. all depends_on are Done/Cut             │   ← hard ordering
        │   5. touches[] ∩ (any running item) = ∅      │   ← soft contention
        └───────────┬─────────────────────────────────┘
                    │  READY SET
        ┌───────────┴─────────────────────────────────┐
        │ RANK (descending):                           │
        │   1. tier / explicit priority                │
        │   2. critical-path weight (unblocks the most)│   ← the smart term
        │   3. nearest due / age                       │
        │   4. stable id  (deterministic final tiebreak)│
        └───────────┬─────────────────────────────────┘
                    │
        human UI ◀──┴──▶ agent     (same ranked head; both pull it)
```

- **`task next`** returns the ranked head. It is a *pure function of the files*, so it
  survives compaction and session boundaries with **zero memory**.
- **Critical-path weight** (longest dependency chain downstream — one reverse-topological
  pass) is the non-obvious high-value term: prefer the ready task that unblocks the most
  downstream work. It's what makes the queue feel smart, not FIFO.
- **Cycle safety:** run cycle detection on `depends_on` before ranking; a cycle = all
  members permanently blocked → surface as a diagnostic, don't silently deadlock.
- **Definition-of-ready gate:** a task is selectable only with a crisp `acceptance`, a
  context bundle, and a named verification lane. No machine-checkable success condition ⇒
  not ready, full stop.
- **Tie-break toward clarity, not value** (documented agent divergence from human PM):
  prefer a clear smaller task over an ambiguous high-value one; route the ambiguous one to
  a human-clarification queue rather than letting the agent take it on.

### 1.3.7 Human-vs-AI interaction + the safety / HITL boundary

Two **orthogonal** safety axes. Conflating them is the common mistake.

**(A) Authorization — "may I do this alone?"** — three `gate` values, 1:1 with this repo's
`WAVE_2_QUEUE.md` tripartition:

| `gate` | Meaning | Agent behaviour | Corpus equivalent |
|---|---|---|---|
| `auto` | Two-way door; wrong → cheap to revert | Pull, implement, open `In Review`, then go pull the next **without stopping** | "baked as DEFAULTS" |
| `gated` | Has open `decisions` with a recommended default | **Stop**, surface the decision + recommendation, wait; one answer unblocks | "open questions to confirm at launch" |
| `supervised` | One-way door / multi-day / security-gated / big refactor | **Never auto-pull**; requires explicit human launch even if deps are met | "Deferred OUT of the auto-queue — needs supervision" |

The deciding criteria are **reversibility, blast radius, and cost — NOT task importance.**
A workable default gate map by action class:

| Action class | Default |
|---|---|
| Read/inspect, run tests, write to scratch/worktree, draft a plan | **Autonomous** |
| Commit to a branch, open a draft PR | **Autonomous, logged** (reversible) |
| Merge to trunk / push to shared, delete data, spend money, rotate secrets, change CI/infra | **Human sign-off** (irreversible / blast radius) |
| **Adding a dependency**, network fetch of code, schema/migration | **Human sign-off** (supply-chain — matches the repo's minimal-deps rule) |
| Anything outside the item's declared `touches`/`files` scope | **Pause + escalate** |

**The stop rule (what makes it safe):** an agent in autonomous mode advances *only* across
`auto` items whose acceptance is verifiable. It **MUST stop and emit a structured
handoff** when it (a) reaches a `gated`/`supervised` item, (b) hits an open `decision`,
(c) fails `lint`, (d) can't meet acceptance (e.g. needs a dependency-approval, or a VM-only
verification it can't run on host), or (e) a `touches` conflict leaves no safe `auto` item.
Then it parks state in the item's `log[]` and notifies. **The default is STOP** — an item
is auto-runnable only if explicitly `auto` *and* unblocked *and* contention-free (three
affirmative conditions). Silence/ambiguity → `Todo`/blocked, never ready. That asymmetry is
what makes "mostly autonomous but safe" actually safe.

Two interlocks worth stating explicitly, both already lessons in this repo:
- **`touches` is a security/quality boundary, not just scheduling** — it prevents the
  merge-explosion *and* the REPUB-1-style "two agents both touched `DocumentModel`, both
  subscribed wrong" regression class.
- **`acceptance` must encode which lane verifies it.** An agent that can't run the VM lane
  must mark a VM-only item blocked/awaiting, **not** fake-pass it.

**(B) Liveness — "am I making real progress or running away?"** — independent of
authorization, this is the runaway-prevention layer (and what flat markdown can't do):
- **Attempt cap** (3–5 retries/step) → on exceed, go blocked/escalate, don't retry again.
- **Cost budgets** (tokens, wall-clock, tool-calls) per item/session, with hard stops.
- **Ground-truth validation, not self-report** — a step is "done" only on an external
  check (exit code, test result, diff actually present).
- **No-progress detector** — N consecutive steps with no change to validation state or
  artifacts → stop (looping in place).
- **Scope fence** — edits outside the declared `touches`/`files` set are a tripwire to pause.

**Decomposition of a big item is itself a planning act that needs a gate.** Let the AI
*propose* a child breakdown for an `L`/`supervised` item; the human approves it landing.
Agents can freely *create* `Idea`/`Todo` (and `gated`) items; only a human (or explicit
approval) moves things to ready/`auto`. This is the "who owns `rank` when the AI surfaces
new work mid-wave" question — the safe default is: agents file, humans promote.

## 1.4 OPTIONS where there's a genuine fork

| # | Fork | Options | Recommendation |
|---|---|---|---|
| 1 | **Storage substrate** | (a) files-in-git, markdown+frontmatter · (b) SQLite/embedded DB · (c) SaaS/service | **(a).** The model must live where the agent and the diffs already are: versions with the code, offline, zero new deps, every status change is a reviewable diff with the same provenance as commits. A DB is faster to query but invisible in PRs + a moving part; at solo scale, parse over a few hundred small files is free. (Matches Backlog.md's proven model and this repo's docs-in-git convention.) |
| 2 | **File granularity** | (a) one file per item · (b) one monolithic `tasks.md`/`.json` | **(a).** Git merges are line-oriented; the dominant op is concurrent edits to *different* items → file-per-item makes them disjoint paths → conflict-free by construction. A monolith collides on every concurrent edit. Cost (many small files) is irrelevant at task scale. Name files by `id` (not title) so retitles don't churn paths. |
| 3 | **History model** | (a) git log only · (b) pure event-sourcing · (c) hybrid snapshot + append-only event log | **(c).** `.md` snapshot = fast working copy humans/agents edit; `events/*.jsonl` (monthly-rolled, `merge=union`, event-id dedup) = authoritative semantic audit ("T-7 moved todo→in_progress *because the agent claimed it*"). Git-log-only loses the *why*; pure event-sourcing is overkill for what's fundamentally CRUD and forces every reader to fold the log. **Sharpest risk: snapshot drifting from log** — mitigate by routing *all* writes through one small lib/CLI that appends the event + rewrites the file + recomputes roll-ups in one op. |
| 4 | **Gated-default execution** | (a) `gated` always blocks until human ack (safe, slower) · (b) auto-run after a timeout + notify (optimistic, fast) | **Per-item field, not a global policy.** A wrong default executed autonomously is exactly a silent one-way-door mistake; but some defaults are genuinely safe to optimistically apply. Make the timeout an optional per-item field; default to **block-until-ack**. |
| 5 | **Concurrent claim** | (a) lease + CAS (`owner`/`lease_until`, TTL-expirable) · (b) none, trust one-at-a-time | **(a)** for the multi-agent fan-out (worktree-lock collisions are a known hazard class here). The one place real coordination is needed; everything else is conflict-free. Leases must expire so a crashed agent's item is reclaimable. |
| 6 | **`touches` accuracy** | (a) hand-declared · (b) auto-derived from `git diff --name-only` post-run, reconciled with planned `files[]` | **Hybrid (b-leaning).** Hand-declaration alone is unverified-reliable; an agent that edits an undeclared file breaks the concurrency guard. Reconcile declared `files[]` with the worktree's actual post-run diff. |

## 1.5 The sharp / uncertain parts (call these out, don't pretend they're solved)

1. **Drift between the task store and reality is the #1 failure mode.** Files-in-git makes
   the model *durable* but not *true* (the `BACKLOG.md` already-shipped-but-still-open bug).
   Mitigate: make `acceptance` machine-checkable where possible so `lint` flags "this
   item's acceptance already holds → should be Done/Cut." Where acceptance is only prose,
   drift is unavoidable and the model degrades to today's state. **Most likely thing to
   undermine the whole thing.**
2. **`touches[]` completeness** — only a useful guard if current and complete (see Option 6).
3. **Granularity of "one agent run"** — `size` is a guess at whether work fits one
   autonomous run before compaction; wrong-high → the agent stalls mid-item with no clean
   `In Review` boundary. No clean a-priori metric; calibrated by experience. May want to
   let an agent *split* an item it discovers is too big — which re-opens the gated-
   decomposition question.
4. **Who owns `rank` for AI-surfaced mid-wave work** — lean "agents file `Idea`/`Todo`
   freely; humans promote to ready/`auto`." Where exactly the line sits is genuinely
   uncertain.
5. **Decision-default trust** — see Option 4; a wrong auto-applied default is a silent
   one-way door.
6. **Snapshot↔log consistency** — see Option 3; enforce the single write path structurally.

---

# PART 2 — HOW IT COULD FIT (light sketch — to be detailed once the WHAT is agreed)

> Everything below is intentionally under-specified. Do **not** build to it yet. It exists
> only to show the WHAT lands cleanly on the existing app with no architectural surprises.

## 2.1 App context (the surfaces this would ride on)

- **macOS SwiftUI code-viewer/editor.** Module layering: **`ViewerKit`** (lowest) →
  **`ViewerCore`** (SwiftUI-free logic/models) → **`ViewerUI`** (SwiftUI). The work-item
  model + queue logic + roll-up are pure logic → they live in **`ViewerCore`** (and are
  unit-testable there, like the existing review store).
- **A project-resident `.textview/` store** already exists, with a *tested project-local
  persistence layer* for code review: `.textview/reviews/`, served by
  `Sources/ViewerCore/Review/ReviewStore+ProjectLocal.swift` + `ReviewSidecar.swift`. The
  work store is a **sibling**: `.textview/work/` — same persistence idioms, same tests
  shape. This is the single biggest reason the fit is low-risk: the substrate, the
  file-per-record pattern, and a tested store layer already exist.
- **An MCP automation server Claude already drives** (`docs/AUTOMATION.md`). This is the
  agent's read/update surface — no new transport, no new auth model.
- **An existing markdown `BACKLOG.md`** — the thing being replaced/migrated.

## 2.2 The sketch

```
  .textview/
    reviews/                 ← exists today (ReviewStore project-local layer)
    work/                    ← NEW, sibling — same idioms
      items/T-0007.md        ← YAML frontmatter (machine fields) + markdown body (grounding/notes)
      events/2026-06.jsonl   ← append-only audit log (merge=union)
      index.json             ← OPTIONAL derived cache (regenerable / gitignored)
    .gitattributes           ← work/events/*.jsonl merge=union ; work/index.json -diff
```

- **Persist in `.textview/work/`** — file-per-item (`items/<id>.md`) + hybrid snapshot +
  monthly-rolled event log (Part 1, Options 1–3). The store layer lives in `ViewerCore`
  alongside `ReviewStore`, with the **single write path** (append event + rewrite item +
  recompute roll-ups atomically) the model depends on.
- **MCP tools** for Claude/agents to read+update — a small vocabulary mirroring the model:
  `work_next` (the ranked-head queue), `work_get`, `work_update_status`,
  `work_set_flag` (testsPass — agent only), `work_claim` (lease/CAS), `work_lint`,
  `work_create` (Idea/Todo only, per the file-vs-promote rule). These map directly onto
  the existing MCP server; `humanAccepted` is **not** exposed to the agent.
- **A UI panel** modeled on the existing **code-review tool-window/tab** (`ViewerUI/Review/
  ReviewIndexTab.swift` is the template): a tree + status board (the *generated* roll-up
  replacing the hand-maintained top-of-`BACKLOG.md` stanzas), the ready queue, and the
  human-only controls (`humanAccepted`, `Idea→Todo` promote, `Cut`). Pleasing on-brand
  irony: a markdown-with-frontmatter store *renders in the app it ships in*.
- **The auto-pickup loop (high level):** agent calls `work_next` → gets the deterministic
  ranked head (filtered by deps/`touches`/`gate`) → `work_claim` (lease) → works in its
  worktree → sets `testsPass` citing the lane → moves to `In Review` → **stops** at any
  `gated`/`supervised`/open-decision/lint-fail/budget-cap, else loops to the next `auto`
  item. The human clears `gated` decisions and flips `humanAccepted` from the UI panel.
- **Relationship to `BACKLOG.md`:** `BACKLOG.md` becomes a *generated view* (or is migrated
  item-by-item and then retired as the hand-maintained source). One-time import: parse the
  existing bullets/`~~struck~~`+SHA/`Cut`/`Deferred`/`OWNER DECISION:` markers into
  `items/*.md`. `lint` then catches the drift (already-shipped-but-open) on import.

## 2.3 Rough staged build order (subject to the WHAT being agreed)

1. **Model + store in `ViewerCore`** — `ITEM` type, the state machine, roll-up, the
   file-per-item + event-log persistence, the single write path. Pure logic; fully unit-
   tested on the headless gate (no GUI). *This is where the value is; build it first, alone.*
2. **`task next` / `work lint`** — the deterministic queue + the integrity validator
   (cycles, done-with-open-decisions, ready-with-unmet-deps, two-running-with-overlapping-
   `touches`, acceptance-already-true). Run `lint` like `test-headless-gate.sh` — it's the
   merge-gate for the *work model itself*.
3. **One-time `BACKLOG.md` importer** — populate `items/*.md`; surface drift via `lint`.
4. **MCP tools** — expose read/update with the stop-rule + ownership rules baked in;
   `humanAccepted` withheld from the agent.
5. **UI panel** — the generated roll-up + ready queue + human-only gates, on the code-
   review tool-window pattern.
6. **(Deferred, flagged as an attractive trap)** Surfacing this *as an app feature* for
   users' own repos. Build it as **repo tooling first**; only consider productizing once
   the model has proven itself across a few real waves. Scope-creep risk — don't take the
   bait early.

---

### Consolidated sources

- **Repo-resident prior art:** `BACKLOG.md`, `STATE.md`,
  `docs/research/next-priorities-2026-05-31/PRIORITIZED_PLAN.md` + `WAVE_2_QUEUE.md`,
  `docs/AUTOMATION.md`, `Sources/ViewerCore/Review/ReviewStore+ProjectLocal.swift`,
  `LESSONS.md`/`HANDOFF_*.md` (already a hand-rolled decision-log + resumption-record + task-store trio).
- **Tools surveyed:** [Jira issue types](https://support.atlassian.com/jira-cloud-administration/docs/what-are-issue-types/) · [status categories](https://support.atlassian.com/jira-cloud-administration/docs/what-are-issue-statuses-priorities-and-resolutions/) · [Linear conceptual model](https://linear.app/docs/conceptual-model) / [priority](https://linear.app/docs/priority) / [estimates](https://linear.app/docs/estimates) / [triage](https://linear.app/docs/triage) / [workflows](https://linear.app/docs/configuring-workflows) · [GitHub Projects v2 fields](https://docs.github.com/en/issues/planning-and-tracking-with-projects/understanding-fields) · [Azure DevOps work items](https://learn.microsoft.com/en-us/azure/devops/boards/work-items/about-work-items?view=azure-devops) / [automate state transitions](https://learn.microsoft.com/en-us/azure/devops/boards/backlogs/automate-work-item-state-transitions?view=azure-devops) · [Shortcut story details](https://help.shortcut.com/hc/en-us/articles/360043978792-Details-of-a-Story) · [Asana object hierarchy](https://developers.asana.com/docs/object-hierarchy) · [Taskwarrior urgency](https://taskwarrior.org/docs/urgency/) / [UDAs](https://taskwarrior.org/docs/udas/) · [org Edna](https://www.nongnu.org/org-edna-el/) / [org-depend](https://orgmode.org/worg/org-contrib/org-depend.html) · [todo.txt](https://github.com/todotxt/todo.txt) · [Backlog.md](https://github.com/MrLesk/Backlog.md) · [spec-kit tasks template](https://github.com/github/spec-kit/blob/main/templates/tasks-template.md) · [TASKS.md](https://tasksmd.github.io/tasks.md/).
- **Definition of Ready/Done:** [DoR/DoD explained](https://www.meistertask.com/blog/definition-of-ready-and-definition-of-done-in-scrum) · [dangers of a DoR](https://www.mountaingoatsoftware.com/blog/the-dangers-of-a-definition-of-ready).
- **Roll-up / dependencies / scheduling:** [Azure parent state automation](https://learn.microsoft.com/en-us/azure/devops/boards/backlogs/automate-work-item-state-transitions?view=azure-devops) · [parent rollup (Smartsheet)](https://help.smartsheet.com/articles/765753-parent-rollup-functionality) · [status vs state (Jetpack)](https://support.jetpackworkflow.com/en/articles/9015266-task-statuses-and-states) · [DAG task scheduling](https://itnext.io/how-to-build-a-dag-based-task-scheduling-tool-for-multiprocessor-systems-using-python-d11a093a835b) · critical-path/priority-list scheduling.
- **Persistence / merge:** [Event Sourcing (Azure)](https://learn.microsoft.com/en-us/azure/architecture/patterns/event-sourcing) · [snapshots in event sourcing](https://www.kurrent.io/blog/snapshots-in-event-sourcing) · [avoid JSON merge conflicts](https://sophiabits.com/blog/avoid-json-file-merge-conflicts) · [CRDT implementations](https://crdt.tech/implementations).
- **Agent autonomy / durable state:** [Swarmia — five levels of agent autonomy](https://www.swarmia.com/blog/five-levels-ai-agent-autonomy/) · [Google ADK — pause/resume agents](https://developers.googleblog.com/build-long-running-ai-agents-that-pause-resume-and-never-lose-context-with-adk/) · [Cloudflare Agent Memory](https://blog.cloudflare.com/introducing-agent-memory/) · [Thoughtworks — human-on-the-loop](https://www.thoughtworks.com/en-us/insights/blog/generative-ai/cybernetics-and-human-on-the-loop-in-agentic-coding) · [arXiv 2508.13143 — why agents fail tasks](https://arxiv.org/html/2508.13143v1) · [deterministic agentic AI with state machines](https://blog.logrocket.com/deterministic-agentic-ai-with-state-machines/) · [AGENTS.md impact (arXiv)](https://arxiv.org/pdf/2601.20404) · [HITL approval gates](https://machinelearningmastery.com/building-a-human-in-the-loop-approval-gate-for-autonomous-agents/) · [Anthropic — measuring agent autonomy](https://www.anthropic.com/research/measuring-agent-autonomy).
