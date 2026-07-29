# PM Holistic — markdown_viewer as an engineering-management case study

2026-07-11 · Fable holistic agent (W2, PM lens). Inputs: all 15 aspect reports in `aspects/`,
`summaries/commits/INDEX.md` (19 eras, 3,733 commits), the 1.3 GB session-transcript struggle study
(`TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md`), the repo+board archaeology
(`project-meta-analysis-2026-07-04/SYNTHESIS.md`), `BACKLOG.md` §pre-launch-audit themes, and the
v4 tracker design (`DESIGN_v4_CONSOLIDATED.md`, `design_v4/HLD.md`). Companion:
`holistic/CROSS_CORPUS_PATTERNS.md` (pattern altitude); this report is the management altitude.

---

## The project as a PM saw it — phases, velocity, where effort actually went vs where value came from

**Topline:** 57 days (2026-05-14 → 07-10) · 3,733 commits (~65/day sustained) · 1,474 board
tickets (board-verified 2026-07-11 via `mcp__tasked__project_list`; commit-trailer grep
undercounted at ~1,168 since it only catches tickets that shipped a tagged commit — see
`aspects/board-ground-truth.md` for the query and the lane breakdown) · 405,956 LOC (170K Swift
product, 177.8K Swift test — test LOC > product LOC, 53K Rust) · 150 context compactions · one
human owner as the sole reviewer/decider.

### Phase narrative (from the 19 commit-era reports)

| Phase | Span | Eras | What management would have seen |
|---|---|---|---|
| **P1 Bootstrap land-rush** | 05-14 → 06-03 | c-01–c-03 | Skeleton→features in a day; the compositor bug already reworked twice in the first 36 h; first 47-agent/172-finding audit fanout establishes the severity-triage ritual; Rust-core FFI debuts. Velocity looks spectacular; the false-green problem is already present and undiagnosed as a *class*. |
| **P2 Hardening + logging plateau** | 06-03 → 06-14 | c-04–c-10 | 80-finding deep audit, VM lane unblocked piecewise (TCC/ulimit/launchctl), staged Rust-engine soaks. Docs-to-code ratio climbs to its 1.5–1.7:1 peak — the "log every item" autonomous mandate turns ⅓ of all motion into process artifacts. |
| **P3 Platform wave** | 06-14 → 06-22 | c-11–c-13 | Peak feature velocity (multi-window sessions, LSP rename, image editor, exporters); zero reverts for 6 straight days; 69% doc overhead per feature in the shipping blitz. Breadth: ~30 feature families now open in parallel. |
| **P4 Production-readiness + Canvas** | 06-22 → 07-02 | c-14–c-17 | The two great re-fix crises root-caused (scroll-restore ×24 commits, UAT env-delivery ×11); the one scheduled refactor sprint (DocumentModel, 40 slices, zero regression); formula port completed with differential fuzzing; Canvas research fans out to ~75 agents and burns ~half a session quota before M0–M6 slicing rescues the build. |
| **P5 Reckoning** | 07-02 → 07-10 | c-18–c-19 | The owner's Built/Logic/Usable audit lands the verdict: *"almost all of them are unusable"* except the editor core. Board-vs-code reconciliation finds the board **understating** completion; 25-batch + 37-tick drain surfaces 3 crash classes, 22 built-but-unshipped subsystems, ~40 dead render tails; the pre-launch audit (itself killed twice by session limits) finds the ~8-P1 data-loss cluster, the unauthenticated MCP socket, zero attribution shipped, notarization never once run. |

### Where the effort actually went

From the commit ledger and transcript study, the honest cost accounting:

- **Process/tracking apparatus: ~⅓ of all motion.** 36.5% of commits doc-only; `docs:` commits
  (1,397) outnumber `feat:` (988) and dwarf `fix:` (374); one file (`AUTONOMOUS_PROGRESS.md`,
  1,031 touches) is 17% of the entire commit history. This is compaction-survival insurance, not
  documentation.
- **Substrate friction: 56% of all tool errors.** 260 post-compaction amnesia + 180 tracker
  lifecycle violations out of 791 — none of it product work, none of it ever improving.
- **Test volume: more test code than product code** (9,988 test functions) — yet distributed
  81% headless / 1.4% real-pixel, the inverse of where the costliest bug class lived, and blind by
  construction to the data-loss/lifecycle/security cluster the week-8 audit found.
- **Harness/infra: a permanent tax** (est. 15–20% of velocity): VM lane bring-up recurs in nearly
  every era; 24 commits (12% of one slice) went to harness introspection debugging in one crisis
  alone; worktree bloat peaked at ~124 GB.
- **Duplicate engineering:** 5 find runtimes, 3 scroll-persistence channels, 2 highlight engines,
  2 fold engines, 2 WebView caches — the dual-UI split, never decided, paid for repeatedly (it
  directly manufactured the 5-ticket scroll-restore bug family).

### Where the value actually came from

The owner's own inventory (`FEATURE_INVENTORY.md`) grades exactly one family fully usable: the
**editor core** (CM6, vim, 22-language tree-sitter, file nav). The durable *assets*, though, are
mostly architectural and process artifacts, and they are unambiguous:

- The **3-package module boundary** (~80% of behavior headlessly testable by construction).
- The **Rust-core sans-IO engines + staged migration playbook** (8/9 ports, zero reverts,
  differential fuzzing caught 5 silent parity bugs pre-ship).
- The **tier-as-type test harness + TierGateObserver + evidence-class vocabulary** — the single
  most-cited port-verbatim asset.
- The **`scripts/` tooling layer** (62 files, near-unanimous KEEP — each script a fossilized
  incident).
- The **Canvas DSL result**: 80%+ agent-executability vs 2–11% for a WYSIWYG baseline — the
  empirical validation of the owner's whole product thesis.

**The PM-level irony:** effort correlated *inversely* with realized user value. The two most
architecturally admired subsystems (image/audio immutable-ops "crown jewel", review state machine)
are the least usable; the owner's stated #1 differentiator (agent-transparent review/walkthrough/git)
ended as the *least* usable tier; and the highest-leverage artifact of the whole run was not a
feature at all but a 3-column audit spreadsheet (Built/Logic/Usable) that took 7 weeks to exist.

---

## Systemic patterns — the handful of forces that explain most of the friction

Six named forces. Nearly every incident in the corpus is one of these wearing a costume.

**1. Substrate starvation.** There was no durable execution substrate, so the session transcript
became the state, and everything downstream is the price: 260 amnesia errors (33% of all, flat
across 150 compactions), 50 stale-edit errors, the 36.5%-doc-commit apparatus, `HANDOFF.md` byte
caps, re-orientation costs after every compaction. One root, paid three ways (errors, commits,
owner attention).

**2. The lying-evidence ladder.** Every verification tier below WindowServer pixels can be
mistaken for the tier above it (model-green → in-tree → ImageRenderer → in-process WebView →
T4 dump → T5 pixels), and every rung *was* mistaken, each costing a multi-round arc (compositor
occlusion ×4). Corollary: coverage accretes along the **feedback-cost gradient**, not the risk
gradient — agents wrote tests where feedback took seconds, producing the inverted pyramid. Mandates
didn't change the shape; making pixel-proof cheap (~30 s by c-19) did.

**3. Consumption ≠ completion.** "Done" never required a wired consumer, so a green suite, a
closed ticket, and a CHANGELOG line could all be true of a feature no user can reach — formula
engine (100% ported, A/B-tested, zero view callers, shipped as "done"), the conflict-resolution
3-pane, the notices file generated but never copied into the bundle. Render tails deferred as
*comments* on fixed tickets vanish from every board sweep. The board simultaneously **overstated**
(dead tails) and **understated** (c-18: code more wired than tickets claimed) because status was
asserted, never derived from evidence.

**4. The human as serializer.** Every closure routed through one person: review=284 (48% of open)
+ validated-awaiting-done=735, `progress`=0, 39.8% of task-state time spent stalled at validated
(304 h median). The queue re-forms in front of the human no matter how much automation runs
upstream. 65 commits/day vs one reviewer is not a discipline problem; it's an arithmetic one.

**5. Prose doesn't police — only mechanisms do.** Every prose rule decayed: lifecycle discipline
(180 violations, 0% improvement over 7.5 weeks of rejection feedback), the CRLF lesson (documented,
then recurred in LSP), `killall` (fixed, documented, recurred at a second call site), the domPatch
fallback contract (a comment, silently divergent). Every mechanized rule held: TierGateObserver,
surface-coverage matrix, ABI skew detector, size/byte budget tests, negative-control teeth
switches. LESSONS.md (333 KB) prevented no recurrence by itself; its real function was intake
queue for gates.

**6. Generative habits without limiting habits.** Build broadly / test heavily / document lessons /
file generously — each correct instinct ran unbounded until a retrofit cap: scope (12 families, no
re-scope until week 7), tickets (over-decomposition corrected 07-10, after a 134→107 dedup on
06-19), docs (fold-in directive week 6), fan-out (75-agent runaway before a cap), caches/stores
(caps applied to acute paths, not cumulative ones). Same shape everywhere: the counterweight
arrived only after the unlimited version had already cost real time. Special case: **breadth
defers integration truth** — the drain phase and the audits are where reality surfaced, and both
were discoveries rather than scheduled phases.

---

## What management moves worked — directives/rituals that measurably changed outcomes

Owner directives demonstrably steered agent behavior with a ~1–2 week lag *and held* — the levers
work; the failure was only that most arrived weeks after the bill. Ranked by evidence quality:

1. **"Fold docs into the code commit" (2026-06-22).** Cleanest natural experiment in the corpus:
   docs-to-code ratio 1.5–1.7:1 (c-06–c-12 peak) → 0.30:1 (c-16) / 0.48:1 (c-19, "zero standalone
   process-noise commits"). One sentence halved a measured ~⅓-of-motion tax.
2. **The Built/Logic/Usable audit (2026-07-02).** Before: ~30 "built" families, board trusted,
   thousands of green tests. After: the owner's ground-truth verdict, 43 self-contained gap tickets
   (TSK-1411), a usable-bar acceptance criterion on subsequent work, and the discovery that ticket
   state was wrong in both directions (3-for-3 stale on spot-check). Highest-leverage single
   artifact of the project.
3. **The four testing MANDATES (2026-07-04)** — per-surface real-render matrix, AX-interaction,
   agent-driven UAT, **required evidence classes named per ticket at grooming**. Converted the
   false-green fight from exhortation to mechanics; by c-19 pixel-proof-with-artifact ("VERIFIED ON
   THE REAL VM UI (tmp/uat-videocard.png)") was the default commit norm.
4. **Batch work-loop mandate (2026-07-07).** Replaced per-ticket ceremony (gate+commit+docs per
   ticket) with 5–15-ticket chunks, one gate, one commit: 25 batches + 37 drain ticks cleared the
   usability backlog at sustainable overhead. Paired with the granularity-floor correction
   (2026-07-10: "a ticket = one PR/commit; a sub-item nothing can observe is a checklist line").
5. **Severity-triaged fanout audits as a reusable ritual.** The c-03 pattern (fan out → dedup into
   themes → severity-batch fixes) was reused at least 4× (80-finding deep audit, 17-pass sweep,
   crash-class audit, pre-launch audit) — the most durable process pattern in the run. Each pass
   found real, distinct issue classes; the mistake was treating "pre-launch audit" as one late gate
   rather than a standing cadence.
6. **"The VM is UP — render is the agent's lane" (2026-06-29) + the T5-blocked ≠ render-blocked
   split.** Dissolved a manufactured "host-only backlog"; ~3 features/tick unblocked; render/UI
   validation moved from owner's lane to agent's lane end-to-end. Late, but decisive.
7. **Agent self-validation with a `checks` artifact (2026-06-07) + the teeth discipline.**
   68 deliberate revert-to-prove-red demonstrations, 12 held-for-gate admissions, 11 self-caught
   false claims — the honesty guard *worked*, at real cycle cost. It reduced the serializer pile
   but couldn't eliminate it (policy still capped closure at the human).
8. **Rust migration policy: superseded Swift twins are bugfix-only.** Stopped double-investment
   structurally; enabled twin deletions with zero reverts. The counter-example proves the rule:
   where no such decision existed (native vs web UI), five parallel find runtimes accreted.
9. **Root-cause SOP codified from incidents** ("read the ticket's understanding first"; "after 2
   failed patches, collapse the chain"; "question the test vehicle after 3 harness-patching
   rounds"). Post-incident codification kept the *identical* failure from recurring — with the
   honest caveat that codification lagged discovery by about one incident each time.

---

## What was structurally unfixable in-flight — and how the rebuild's setup avoids inheriting it

These are the classes where in-flight mitigation demonstrably plateaued — the empirical argument
that the fix is architectural, not behavioral.

| In-flight ceiling (measured) | Why it couldn't be fixed in-flight | How the rebuild avoids inheriting it |
|---|---|---|
| **Compaction amnesia — 260 errors, 0% improvement over 150 compactions** | The working session *was* the state; no prompt rule can restore a zeroed read-set the agent can't know was zeroed | Stateless, short-lived worker cells that rehydrate from ticket contracts (v4 invariant 10, "no session is load-bearing"). Do not dilute this — it is the single most data-backed decision in the corpus |
| **Lifecycle violations — 180 errors, flat despite constant rejection feedback** | The tool *afforded* the illegal call; rejection is a dead-end retry, not a learning signal | Agents never transition state; the runner walks the machine; agents emit data-plane verbs only (v4 invariant 6). The class is deleted, not trained away |
| **Human-as-serializer — 735+284 pile, 304 h median stall** | Policy capped agent closure below `done` because self-attestation couldn't be trusted; trust required a human touch per item | Runner re-runs every check itself; merge queue closes; `usable` is runner-posted; human touch = 30 s `accepted`; default-with-veto on two-way doors. Human becomes a decider, not a stage |
| **Doc-churn apparatus — 36.5% of commits** | It was load-bearing compaction insurance; you can't delete the workaround while the root need exists | Tracker-as-substrate (evidence rows, contracts, KB) removes the *reason* the apparatus existed; fold-docs is the day-1 default, not a week-6 correction |
| **Board ≠ code, both directions** | Status was asserted by whoever moved the ticket; nothing forced reverse reconciliation | Status derived from attached evidence classes; provenance written by the merger at squash time; scheduled code-first reconciliation |
| **Dual-stack duplication (5 find runtimes…)** | N locally-convenient per-surface choices; no single consolidation decision point ever forced | Day-1 written rendering policy (web for content surfaces, native for chrome — where this project's own TSK-1524 landed after paying the tax); capability-ownership boundaries, twins only as migration states with deletion dates |
| **Diagnostic over-confidence / re-fix loops (TSK-1046 ×13, TSK-1243 ×21)** | **Not fixed by any architecture** — hypothesis selection is agent cognition; every mitigation only made wrong guesses cheaper to falsify | Budget it: ≥2-hypotheses + discriminating-check field on bug contracts; "2 failed patches → collapse the chain" as SOP; fast-red gates cap the cost. Expect 2–3 wrong attempts on genuinely novel timing bugs |
| **VM/render harness fragility** | Every new validation surface needed its own multi-commit unblock across the entire timeline; each break silently zeroed a tier's coverage | Accept as permanent tax (~15–20% velocity), with a week-2 bring-up deadline, a standing health check line item, and in-process test-mount seams that shrink how much lives on the fragile tier |

---

## Operating model for the rebuild — a concrete recommended operating model

The unprimed explorer's synthesis is the organizing principle: **pair every generative habit with
its limiting habit from day 1.** Concretely:

### Roadmap shape

- **Week 0 (before feature #1):** written scope boundary + rendering-stack policy + sandbox
  posture + FFI one-way-door review (position units, content model, reserved envelope fields) —
  the four unretrofittable decisions this project either got lucky on or paid for.
- **Week 1: rehearse the ship path** — real signing identity everywhere (never ad-hoc), one
  sign→notarize→attribute→clean-machine-install cycle, bundle-content assertions. The one lane
  this project never exercised was the one it needed to launch.
- **Sequencing: differentiator-first, depth-first.** Editor core + ONE MicroApp + the agent-review
  loop end-to-end usable before family #3 opens. "New top-level feature family" is a scoped event
  that displaces something, not a free action. Keep a standing finish-or-cut queue, resolved on a
  cadence.
- **Scheduled convergence:** a drain/hardening phase per milestone (this project's drain surfaced
  3 crash classes and ~40 dead tails *after* "all batches done") — integration truth is deferred by
  breadth-first agent work, so schedule its collection; don't discover it.

### Gate lattice (day 1, in order of cheapness)

1. Compiler-enforced module boundaries (Kit/Core/UI, import-grep CI).
2. Headless merge gate + tier-as-type + TierGateObserver from the first UI test.
3. Grep/lint gates: zero-caller views on merge (dead-tail killer), compositingGroup/zIndex on
   representable-siblings, no-discarded-Result persistence writes, unflushed-debounce review block,
   gitignored-lockfile lint.
4. Budget tests with teeth: coordinator LOC/@Published caps (~500/15), bundle dual-cap, doc byte
   caps, per-interaction perf budgets (p95: 16.7 ms keystroke/scroll · 33.3 ms tab/render ·
   50 ms open — port the converged table verbatim) — set *before* the thing exists, not at 3× target.
5. Per-surface real-render coverage matrix (shrink-only exemptions) + negative-control teeth
   switches; cheap pixel-proof path (≤30 s scene+windowed-capture) operational by week 2. Don't
   flip to a pixel-heavy pyramid — keep the headless mass, enforce a per-surface real-render
   *minimum* (the project's own resolution of its internal disagreement).
6. Evidence classes named per ticket at grooming; the gate refuses done without them.

### Cadence

- **Work loop:** batch 5–15 related tickets → one gate → one commit; vertical slices
  (input-to-output) as the default epic shape; docs folded into code commits from commit #1.
- **Audit rhythm:** severity-triaged fanout audit every ~2 weeks or per milestone (not once,
  pre-launch); code-vs-board reconciliation weekly, both drift directions; a "what can an agent
  cause to happen" surface enumeration whenever the tool/verb catalog grows; supply-chain/advisory
  scripts on an actual clock (a scanner nobody schedules is not monitoring).
- **Refactor:** scheduled sprints triggered by budget tests, not opportunistic cleanup (the
  40-slice split proves scheduled works; the 10.7 KLOC residue proves prevention is 10× cheaper).

### Autonomy levels and fan-out policy

- **Auto (no human):** anything with an automatable evidence class — host tests, WV-DOM, T4, most
  T5, perf budgets, merge-queue closure.
- **Default-with-veto (SLA auto-proceed, logged):** two-way-door decisions.
- **Human-only:** one-way doors, dep approvals, "feels slow"/aesthetic judgment, AX-interaction
  tier, product finish-or-cut calls.
- **Fan-out:** exploration = single-pass, read-only agents that structurally cannot spawn
  (the 3→75 runaway happened via the Agent tool, not Workflow — cap the *capability*, not one
  tool); execution fan-out only against a locked design (Canvas M0–M6 shipped cleanly in 4 days
  after the runaway); hard max-in-flight ceiling + quota-window awareness + per-stage
  checkpointing (write-as-you-go saved the corpus stage twice but never the synthesis stage);
  worktree reap on completion *and* crash; build dirs outside worktrees.

### Human-attention budget

Design the owner's day, don't let it emerge: the transcript shows 4,036 typed owner messages and
58 interventions over 7.5 weeks — interactive supervision at ~77 messages/day. Target state:
**inbox-only, ~15–30 min/day** — 30-second accepts, decision briefs with proposals attached,
aged-item batching (one daily batch card per class), interrupts reserved for one-way doors.
Progress reporting = burn-up of *accepted* (never merged/closed counts — this project's closed
counts were fiction in both directions).

---

## Requirements for the coupled PM app — ranked by measured cost of the pathology each fixes

Stance on v4: **adopt; the design is validated by this corpus** — the meta-analysis already
cross-checked it against the struggle ledger (structurally kills ~9 of the top 13 classes,
including all four costliest). The list below therefore *ranks by measured cost* and marks each
item **[v4: core]** (already the design — protect it), **[v4: accepted gap]** (in the G1–G6/carry-
forward register — make sure it survives to DLD), or **[NEW/extend]** (this report's delta).

**R1 — Tracker as execution substrate: stateless cells + runner-walked state machine.**
Cost fixed: 440/791 tool errors (260 amnesia + 180 lifecycle — 56% of all, both flat for 7.5
weeks) *plus* the 36.5%-doc-commit apparatus, which is the same root paid in commits. **[v4: core
— invariants 6/10.]** PM note: this is the item every other requirement depends on; any DLD
compromise that makes a session load-bearing again silently reinstates the top two error classes.

**R2 — Human as decider, not serializer: runner re-runs checks, merge queue closes, runner-posted
`usable`, 30 s `accepted`, default-with-veto with aging.**
Cost fixed: 735 validated-stalled + 284 review (majority of the open board), 304 h median stall,
39.8% of task-state time. **[v4: core.]** Extend with the carry-forwards that keep it honest:
inbox-aging batching (#7) and free-text-always on inbox cards (§8 gap 4).

**R3 — Status derived from evidence, never asserted: `required_evidence[]` pinned in the groomed
contract; gate refuses transitions whose posted evidence doesn't cover the named classes; evidence
must postdate the last requeue (the confirmed DDL BUG 2).**
Cost fixed: the project's #1 owner-facing fight (false render-"fixed"), the 4× compositor
recurrence, headless tests satisfying "tests pass" for pixel behavior, and board-drift in both
directions. **[v4: accepted gap G1 + consolidated §1 fixes.]** The evidence-class vocabulary
(host-unit / WV-DOM / AX-press / T4 / T5-pixel / owner-eye) should ship as schema, not prose —
it's the connective tissue between the editor's harness (producer) and the tracker (enforcer).

**R4 — Consumption is a gated lifecycle stage — [NEW/extend].**
Cost fixed: the dead-render-tail class (the audit's only P0s: 3 shipped features with zero UI
callers; formula engine "done" in CHANGELOG with no consumer; notices file generated, never
shipped). v4's feature-level `usable` (integrated scenario green) covers feature altitude, and
carry-forward #2 forces child tickets for self-reported partial delivery — but nothing catches a
ticket whose diff lands a public view/accessor with **zero callers** when the agent doesn't
self-report the gap. Add: (a) a zero-caller/wiring check as a standing gate class the merge queue
runs (the `regressions.md` grep methodology, mechanized), and (b) ticket contracts for
engine/model work must *name the consuming surface* at grooming, with the consumption stage a
blocking child node by construction — never a prose comment.

**R5 — Fan-out, budget, and pipeline governance: hard agent ceilings, quota-window-aware dispatch,
named serial resources, per-stage checkpointing.**
Cost fixed: the ~75-agent runaway (~half a session quota), two workflow deaths at session limits
(the second losing the entire synthesis phase twice-built), VM-lane oversubscription, 124 GB
worktree bloat. **[v4: accepted gaps G2/G3/G4 + HLD sweep/budget-breaker.]** Extend: multi-stage
*analysis/audit workflows* (not just ticket execution) need stage-level checkpoints — per-agent
write-to-disk protects only the embarrassingly-parallel stage; an aggregation stage with all
inputs ready must be resumable without re-running upstream.

**R6 — Intake audit + granularity floor + dedup as standing mechanics.**
Cost fixed: 10.2% pure noise in a 373-item braindump filed unaudited; over-decomposition needing
an owner reversal 8 weeks in; a 134→107 dedup pass; foreign-project bleed (~24 tickets) on the
shared board. **[partially v4: wish-capture restates + orchestrator triage; C6 gives one-DB-per-
project.]** [NEW/extend]: an explicit intake-audit step (contradicts-code / already-shipped /
duplicate / too-vague classifier before a wish becomes nodes), the ticket-granularity floor
("closes in one PR and leaves something observable") encoded in the groomer SOP, and agent-side
dup search (§8 gap 6) promoted from SOP to verb.

**R7 — Knowledge subsystem with a graduation pipeline: lessons become gates/SOP diffs, or they
don't count.**
Cost fixed: the prose-doesn't-police class — CRLF recurred despite a LESSONS entry; killall
recurred at a second call site; 333 KB of LESSONS prevented no recurrence by itself; 40 KB
CLAUDE.md re-read every session. **[v4: E_KNOWLEDGE_SUBSYSTEM, accepted.]** PM emphasis: the
*graduate* step (lesson → policy row / check / lint via the policy_diff gate) is the load-bearing
half; capture-and-retrieve alone reproduces LESSONS.md with better indexing. Track
"lessons graduated : lessons filed" as a health metric.

**R8 — Bug-contract discipline for the one unfixable residual: `discriminating_check` field +
≥2-hypotheses SOP + "2 failed patches → collapse the chain" escalation.**
Cost fixed (bounded, not eliminated): re-fix loops of 13–24 commits each (TSK-1046/1243), the
densest owner-interrupt clusters (12 in 58 min). **[v4: accepted gap G6.]** Set expectations
accordingly in metrics: attempts-per-bug is a distribution with a fat tail, not a defect count.

**R9 — Scheduled code-first reconciliation, both drift directions — [NEW/extend].**
Cost fixed: c-18's "board became a stale liability" (understating completion), the 3-for-3 stale
spot-check, mislabeled-as-fixed closures. v4's reconciler heals commit-trailer provenance at boot
and the P4 weekly drift review checks ADR conformance — neither asks "is the *code* more complete
than the tree claims?" Add a periodic job (or synthesizer duty) that samples tree claims against
the codebase index (which v4 already regenerates per merge — the data is there) and files
corrections as findings.

**R10 — The tracker's own trust model, day 1 — [NEW/extend, informed by the editor's audit].**
Cost fixed (prospectively): the editor's own always-on unauthenticated MCP socket with exec/write
tools is exactly what the tracker server will be — an always-on socket serving exec-capable
agents. v4 §11 already has per-spawn scoped JWTs (good, and ahead of the editor); add the two
lessons v4 doesn't state: a persisted, human-viewable audit log of every tool call from commit #1
(the editor's "no audit" was a deliberate wrong call), and socket/server identity verification so
a same-uid squatter can't MITM the runner or workers. Enforce capabilities on the *effect*, not
per call-site (the editor's `run_verb` jail bypass is the cautionary instance).

### Deliberately NOT carried into the PM app

- Cross-project board-of-boards (v4 C6 cut is right; revisit only as a thin aggregated inbox).
- Validation-as-agent-labor (validator role retired — runner-judged is strictly stronger).
- Any append-only narrative progress log as a product feature — that is the disease this system
  exists to cure; evidence rows and the KB are its replacement.

---

*Bottom line for the owner:* this project's data says the rebuild's success is ~decided by three
day-1 commitments — the substrate (R1–R3: stateless cells, runner-walked truth, evidence-derived
status), the gate lattice (mechanize every rule that matters; prose is intake, not enforcement),
and sequencing depth-first behind the differentiator with the ship path rehearsed in week 1.
Everything else in this report is compounding interest on those three.
