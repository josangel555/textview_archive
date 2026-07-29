# Aspect report — Automated-Operation Struggles

Scope: everything about running this project autonomously — compaction amnesia, cron/heartbeat
loops, subagent fan-out failures, workflow/session quota kills, the handoff-doc apparatus as a
compaction tax, stall-spirals + board-exhaustion over-claims, false "fixed" claims and the honesty
guard. Evidence-first; every claim below cites a report, commit, or file.

Sources consulted: `TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md` (1.3 GB session-jsonl study),
`docs/research/project-meta-analysis-2026-07-04/SYNTHESIS.md` (repo+board archaeology),
`docs/research/greenfield-learnings-2026-07-11/summaries/commits/INDEX.md` + era reports
c-15/c-16/c-17/c-18, `LESSONS.md`, `BACKLOG.md`, `CLAUDE.md` (project + user).

---

## Taxonomy — the distinct types in this dimension

| # | Type | Frequency / severity | Evidence |
|---|---|---|---|
| 1 | **Post-compaction context amnesia** | **260 errors — 33% of ALL 791 tool errors, the single largest error class in the dataset.** Recurring every ~1.6 h (150 compactions over 7.5 weeks); burst pattern (5 identical "File has not been read yet" errors in 12s after one compaction). **Never self-healed** across the whole run. | `TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md` §1.A row 1 |
| 2 | **Stale-edit target** (compaction-adjacent sibling of #1) | 50 errors — `old_string` gone because the file was read pre-compaction and edited post-, or already edited by a prior turn the current context lost track of | same doc §1.A row 3 |
| 3 | **Task-tracker lifecycle violations** | 180 errors (2nd-largest class) — illegal state jumps (`reported→fixed`, `progress→review`), missing required fields; **never improved across 7.5 weeks of constant rejection feedback** | same doc §1.A row 2 |
| 4 | **Handoff-doc apparatus as a permanent compaction tax** | 36.5% of ALL 3,489 commits are doc-only; 17% of the entire commit history is appends to ONE file (`docs/AUTONOMOUS_PROGRESS.md`, 14,987 lines / 1,031 touches — the #1-churn file repo-wide); 6 of the top-10 churn files are tracking docs, not code; docs-to-code commit ratio peaked 1.5–1.7:1 mid-project (c-06–c-12 era) | `project-meta-analysis-2026-07-04/SYNTHESIS.md` Finding 1; `commits/INDEX.md` docs-to-code trend table |
| 5 | **Subagent fan-out runaway** | One incident, ~half a session's token quota burned: 3 `general-purpose` agents with wide prompts recursively spawned to **~75 agents**, several running ~20 min, before being killed. Root mechanism: `general-purpose` agents carry the `Agent` tool itself, so a "cast a wide net" prompt is a self-amplifying loop, not merely a big fan-out. | `LESSONS.md` "Session 2026-07-01 — the subagent fan-out RUNAWAY"; `commits/c-17of19.md` lines 5, 101 |
| 6 | **Workflow/session quota kills** | The `prelaunch-audit.js` ultracode workflow (`wf_6a1bab45-3ab`) **died TWICE on the account session limit** — the second death lost the whole synthesis phase (no `MASTER_REPORT.md`/`NEEDS_OWNER.md`), leaving ~30 audit dimension reports "plausible, unconfirmed" with zero verification/fix phase ever run. | `BACKLOG.md` lines 10–21, 97–98 |
| 7 | **Board-exhaustion over-claiming** | ~12 "board exhausted, no more work" over-declarations across the run, each refuted by a fresh scan — a stall-spiral distinct from lifecycle errors | `TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md` §1.D |
| 8 | **False "fixed" claims / premature-fix-claim retractions** | 8 premature-fix-claim retractions + 3 false-perf-claim retractions, self-caught and self-disclosed; separately, **68 "teeth-demonstration reverts"** (deliberately reverting a fix to prove the new test goes red) + 12 held-for-gate admissions ("cannot self-validate") — this is the *honesty guard functioning*, at real cycle cost | same doc §1.C |
| 9 | **Diagnostic over-confidence / re-fix loops** | The agent named "the real bug" 2–4× per arc before finding it; densest cluster was 12 interrupts in 58 minutes (scroll-restore, June 23). Independently corroborated at the commit level: TSK-1046 re-fix chain ×13, TSK-1243 harness-iteration chain ×21 — vs. healthy additive epics (TSK-1110 ×63, TSK-1213 ×35) that never looped. | `TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md` §1.B, §3.3; `project-meta-analysis-2026-07-04/SYNTHESIS.md` Finding 3 |
| 10 | **Human-as-serializer bottleneck / stall queue** | `review` (284 = 48% of all open board items) + `validated`-awaiting-`done` (735) are the board's two dominant piles; `progress = 0` (everything sits parked waiting on a human gate); independently the jsonl study found a 39.8%-validated-stall rate | `project-meta-analysis-2026-07-04/SYNTHESIS.md` Finding 2 |
| 11 | **VM/host-boundary self-violations under autonomous pressure** | 10 self-corrections where the agent ran a host-opening UI test despite the standing "VM only" rule, apologized, but the instinct recurred all session — a fast-feedback-seeking failure mode that autonomy pressure amplifies | `TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md` §1.C last row |
| 12 | **Worker-loop worktree/disk bloat under parallel fan-out** | ~20 parallel ultracode worktrees hit 96 GB / 97% disk (each `.build` ≈ 4 GB, cold SwiftPM debug build); required an explicit reap SOP | `LESSONS.md` "Parallel ultracode worktrees exhaust disk (2026-06-19)" |

---

## What worked — practices that earned their keep

- **The honesty/teeth discipline actually held, at scale.** 68 deliberate revert-to-prove-red
  cycles + 12 "I cannot self-validate, holding for gate" admissions + 11 self-caught false claims
  show the agent *policing itself* against overclaiming rather than the human catching it after
  the fact. This is architecture-independent — it's a check-authoring/culture habit that produced
  a real, measured reduction in false "done" claims reaching the owner.
  (`TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md` §1.C, §3.2)
- **"Never stop with no more work" as an explicit written directive** converted board-exhaustion
  stalls (12 over-declarations) into a mechanical instruction ("pull from the board: validate
  fixed items, push review, triage reported") — a cheap, load-bearing rule once it existed in
  `CLAUDE.md`. (`CLAUDE.md` "TWO HARD RULES FOR EVERY CRON / AUTOMATED FIRING")
- **Fold-docs-into-code-commit directive (owner, 2026-06-22) demonstrably worked.** Docs-to-code
  ratio ran 0.25:1→1.7:1 climbing through the mid-project "log every item" era, then the fold-in
  directive nearly halved it in the back third (c-16 0.30:1, c-19 0.48:1, "zero standalone
  process-noise commits"). Proof that the compaction-survival tax is *reducible*, not fixed
  overhead — but it took a mid-course correction, not a day-1 default.
  (`commits/INDEX.md` docs-to-code trend + "Process evolution" §)
- **`select-drain` worktree-isolated fan-out pattern** (one SELECT agent curates/decomposes →
  IMPLEMENT agents run in worktree isolation, each self-verified + one commit, orchestrator merges
  and re-gates) worked reliably for bounded, well-scoped batches (bugs/wishlist/minor/security-fix
  pools) — the failure mode was specifically *unbounded, wide-prompt research* fan-out, not
  worktree-isolated implementation fan-out. (`LESSONS.md` "Ultracode workflow patterns that
  worked (2026-06-19)")
- **Resume-cached workflow runs survive quota death partially.** The prelaunch-audit workflow's
  design (each agent writes its own report to disk on completion) meant a second quota kill lost
  only the *unfinished* phases (verify/synthesis/fix never ran) while 39/104 agents were
  resume-cached and replay instant. Write-as-you-go output design limited the blast radius of a
  session-limit death. (`BACKLOG.md` line 98; `README.md` "Method" — "a mid-run quota kill loses
  only in-flight agents; resume re-runs only the dead")
- **Stateless-cell architecture is independently validated as the fix, not just a proposal.** The
  meta-analysis cross-checked the pinboard v4 tracker design against the measured struggle ledger
  and found it structurally deletes/fixes 9 of the top 13 measured pathologies, including all four
  highest-cost ones (amnesia, lifecycle violations, false-done, VM-boundary violations).
  (`TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md` §2)

## What hurt — costly failures, root-cause mechanism

- **Compaction amnesia is a structural session-state defect, not an agent-discipline problem.**
  Mechanism: every compaction zeros the "files I've read" set that gates Edit/Write tool calls;
  the agent has no way to know its own read-set was wiped, so it fires edits against files it no
  longer holds a read-token for, gets rejected, re-reads, and only then succeeds — a synchronous
  tax paid roughly every 1.6 hours for the whole 7.5-week run, **never trending down** (33% of all
  errors, flat across the run — this is not something that improves with better prompting).
  Root cause: the working session IS the state — there is no external substrate the agent
  rehydrates from cheaper than "re-read everything." (`TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md`
  §1.A row 1, §2 row 1)
- **The handoff-doc apparatus is amnesia's downstream cost, paid in commits instead of errors.**
  Because no durable execution substrate existed, the team built one out of markdown: `HANDOFF.md`
  (re-injected every session start), `AUTONOMOUS_PROGRESS.md` (the narrative log, 14,987 lines),
  `BACKLOG.md`, dated point-in-time design docs (~35, never merged back), 5 superseded root-level
  bug trackers, `LESSONS.md` at 3,800+ lines. This is not incidental churn — it is the *same root
  cause* (no durable substrate) manifesting as commit-ledger cost (36.5% doc-only commits) instead
  of tool-error cost (260 amnesia errors). Even with strict budget gates (`HANDOFF.md` capped at
  12 KB, `CLAUDE.md` at 40 KB, enforced by `ContextBudgetTests`), the total apparatus still
  consumed roughly a third of all project motion. (`project-meta-analysis-2026-07-04/SYNTHESIS.md`
  Finding 1; `CLAUDE.md` "Context budgets (2026-07-03)")
- **Unbounded `general-purpose` subagent fan-out is a compounding failure, not a linear one.**
  The mechanism is specific and non-obvious: `general-purpose` agents carry the `Agent` tool
  itself, so "research broadly" prompts recursively self-amplify — 3 agents became ~75 because
  each interpreted "cast a wide net" as license to spawn its own sub-agents. This happened WITHOUT
  the `Workflow` tool ever being called — the standing "no fan-out in cron loops" rule only
  covered the `Workflow` tool, leaving the ad-hoc `Agent` tool path completely unguarded.
  (`LESSONS.md` "Session 2026-07-01")
- **Workflow-level quota death has no graceful degradation for the synthesis stage.** The
  prelaunch-audit workflow lost its entire verify + completeness-critic + synthesis + fix phases
  on the second quota death — not because those phases were expensive, but because they depend on
  ALL upstream phases completing in the same run. The per-agent-writes-its-own-report design saved
  the corpus-gathering phase but did nothing for the pipeline's later, aggregation-dependent
  stages — a single point of failure the write-as-you-go pattern didn't cover.
  (`BACKLOG.md` lines 10–21)
- **The honesty guard's cost is real and unaccounted for.** 68 teeth-reverts + 12 held-for-gate
  admissions + 11 self-caught false claims represent real cycles spent *proving* a fix is real
  after already believing it was — a tax the "agent-driven UAT" mandate (owner 2026-07-04)
  explicitly tried to convert into mechanical checks rather than prompt-enforced discipline,
  because prompt-enforced discipline, however effective, doesn't scale for free.
  (`TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md` §1.C, §3.2)
- **Diagnostic over-confidence is the one class that survives every mitigation tried.** Re-fix
  loops (TSK-1046 ×13, TSK-1243 ×21) and dense interrupt clusters (12/58min) persisted across the
  whole run regardless of testing-tier improvements, mandates, or honesty-guard strength — because
  the failure is in *hypothesis selection*, not verification. Verification mandates make a wrong
  guess cheap to falsify (fast red) but do nothing to reduce the *rate* of wrong first guesses.
  (`TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md` §2 "Diagnostic over-confidence" row, §3.3)
- **The board itself became untrustworthy under autonomous-loop volume.** By c-18 (of 19 commit
  eras) a reconciliation audit found the board *understated* actual completion — code was more
  complete than tickets claimed — the inverse of the more commonly-guarded-against failure
  (false "fixed"). Autonomous loops that "log every item" and advance tickets can still silently
  desync from ground truth in the other direction. (`commits/INDEX.md` "Process evolution" §,
  "Ticket/board hygiene tightened late")
- **Cross-project board bleed under a shared tracker.** The board is shared across projects
  (agent `claude-mdv` vs. others); hygiene audit found ~24 foreign-project tickets (TSK-856..880)
  bled into this project's queries, plus 12 id gaps and 2 attribution gaps — a shared system-of-
  record without hard tenant isolation invites autonomous-loop cross-contamination.
  (`project-meta-analysis-2026-07-04/SYNTHESIS.md` "The numbers")

## Design implications for the rebuild

**Do differently from day 1:**

1. **Make the working session short-lived and stateless by construction, not by discipline.**
   The single highest-leverage architectural change validated by this project's own data: spawn a
   fresh, scoped execution context per unit of work (ticket/task), re-inject only a curated
   contract + references, and never require cross-compaction file-read state. This deletes the
   #1 error class (260/791, 33%) by construction rather than mitigating it with rules that "never
   improved across 7.5 weeks" (the tracker-lifecycle-violation class is the control group proving
   prompt-only mitigation plateaus at zero improvement).
2. **Design the tracker as the durable substrate from day 1, not a markdown apparatus bolted on
   later.** `AUTONOMOUS_PROGRESS.md` becoming the #1-churn file (17% of all commit history) is a
   symptom of a missing structural need, not a process bug — a system-of-record with evidence
   rows, state transitions the runner (not the agent) walks, and frontier views (deterministic
   "what's next") removes the *reason* for hand-maintained handoff docs. Budget for this at
   architecture time, not as a context-budget patch (the 12 KB/40 KB caps here were a reactive fix
   applied 2026-07-03, ~7 weeks in).
3. **Give fan-out tools a hard, structural ceiling — not a prompt convention.** The 75-agent
   runaway happened specifically because `general-purpose` carries the `Agent` tool; the fix that
   actually holds is either (a) a read-only exploration agent type that CANNOT invoke `Agent` at
   all, or (b) a scheduler-enforced max-agents-in-flight cap independent of which tool path spawned
   them. A prompt instruction ("single pass, do not spawn sub-agents") is exactly the kind of rule
   this project's own data shows plateaus at zero compliance improvement over time for other error
   classes — don't rely on it alone for something this expensive.
4. **Make workflow/pipeline stages independently resumable, not just independently-recorded.**
   Per-agent output-to-disk (this project's mitigation) only helps embarrassingly-parallel corpus
   stages. A synthesis/verify/aggregation stage that depends on N upstream completions needs its
   own checkpoint — otherwise a session-limit death at 95% still loses 100% of the aggregation
   value, as happened twice with the prelaunch-audit workflow.
5. **Make "false fixed" structurally hard to claim, not merely discouraged.** The 68 teeth-
   reverts + honesty-guard cost is real evidence that a *prompt-enforced* honesty culture works but
   isn't free. The rebuild's "agent-driven UAT" direction (probe + humble-object seam so a UI
   claim is mechanically re-run by a runner, not self-attested) is validated by this project's own
   later-era mandates (TEST_PYRAMID §MANDATES) — build that mechanism in from day 1 rather than
   discovering it ~7 weeks into a false-fixed pattern.
6. **Treat "board understates completion" as an equally real failure mode as "board overstates."**
   Reconciliation checkpoints (code-state vs. ticket-state) should run periodically regardless of
   which direction drift is suspected — the c-18 discovery that code was AHEAD of the board is a
   distinct risk from false "fixed" and needs its own detection, not just honesty-guard machinery
   aimed at the opposite direction.
7. **Isolate per-project state in the tracker from day 1** if the tracker is shared across
   projects — the ~24-ticket foreign-project bleed here was a hygiene tax that a namespace/tenant
   boundary at the schema level would have prevented outright.

**Accept as inherent cost (budget for it, don't expect an architecture to erase it):**

- **Diagnostic over-confidence / re-fix loops.** No mitigation tried across the whole 7.5-week run
  reduced this — verification mandates make a wrong guess *cheap to falsify* (fast red) but don't
  reduce the *rate* of nominating a wrong root cause. Budget an SOP rule (hold ≥2 candidate causes
  until a discriminating check splits them) as damage control, not a claimed fix.
- **Worktree/build disk bloat under parallel fan-out.** Inherent to git-worktree-isolated parallel
  agents (~4 GB per SwiftPM debug build here); the fix is operational hygiene (reap on completion,
  build-dirs-outside-worktree where the toolchain allows) applied consistently, not a one-time
  setup.
- **VM/host-boundary or sandbox-boundary self-violations under autonomy pressure.** Even with an
  explicit written rule, the instinct to reach for a faster feedback loop recurred 10 times in one
  session. A hard sandbox enforcement (the agent physically cannot reach the disallowed surface —
  per the v4/cell design) is the only mitigation that converts this from "recurring self-correction"
  to "structurally impossible," and should be adopted rather than relying on prompt discipline.

## Portable rules — candidate directives for the next project (verbatim-adoptable)

1. **Sessions are cheap and short-lived; never make correctness depend on cross-compaction memory.**
   If a unit of work can't be re-derived from a written contract + curated references at the start
   of a fresh session, the unit of work is scoped wrong — split it.
2. **"No more work" is never a valid stop state for an autonomous/cron loop.** If the obvious queue
   looks empty, pull from the tracker's validate/review/triage backlog before concluding there is
   nothing to do — treat an empty-queue stop as a process failure to diagnose, not a fact to report.
3. **Never grant a broad-scoped agent the ability to spawn further agents without an explicit,
   enforced cap.** Read-only/exploration delegation should use an agent type that structurally
   cannot invoke a spawn tool; any agent that CAN spawn further agents needs a hard max-in-flight
   ceiling enforced by the scheduler, not the prompt.
4. **Every multi-stage automated pipeline needs per-stage checkpointing, not just per-task output
   capture.** A quota/session death mid-pipeline should lose only the stage in flight, never
   downstream aggregation work that already had all its inputs ready.
5. **A claim of "fixed" for anything with an observable/rendered/behavioral surface requires a
   mechanically re-run check, not a self-attestation** — build the probe/verification path into the
   system (a runner that re-executes the check), don't rely on an honesty-guard SOP alone, even
   though the SOP alone measurably worked here (68 teeth-reverts) — it worked at a real, ongoing
   cost that a structural fix removes.
6. **Reconcile the tracker against ground truth (code/behavior) in BOTH directions on a standing
   cadence** — check for both false-"done" (board ahead of reality) and stale-"open" (board behind
   reality, understating completion); this project only discovered the second direction ~18/19ths
   of the way through.
7. **Cap and audit the "process apparatus" itself as a tracked cost.** If more than ~15–20% of all
   commits/changes in a given period are process/doc/tracking-only, that's a signal the durable-
   substrate design is insufficient, not that the team needs more logging discipline — fold docs
   into the code commits they describe, and prefer structural state (tracker rows) over prose logs
   wherever the state is machine-checkable.
8. **When a fix needs 2+ patch attempts on the same bug, stop patching the current stage and look
   for a single source of truth to collapse the chain into** — a race/timing bug that survives one
   patch attempt is diagnostic that the sequencing itself is the disease, not the specific stage
   being patched (this project's scroll-restore and UAT-env-delivery arcs both only resolved this
   way, after 24 and 11 commits respectively of stage-patching).
