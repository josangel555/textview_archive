# Inefficiency Types — where effort was wasted (markdown_viewer, 2026-05-14 → 07-10)

Dimension brief: doc-churn/process tax, re-diagnosis after compaction, harness-patching loops,
over-deliberation, token-burn patterns, rework from unverified assumptions, worktree/build bloat,
duplicate/parallel implementations. Evidence-first; every claim below cites a report, commit, or file.

Sources used: `summaries/commits/INDEX.md` (19 era reports, 3,733 commits, 100% coverage),
`summaries/INDEX.md` (53 code/doc batch reports), `TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md`
(1.3 GB transcript study: 791 tool errors, 224 self-corrections, 58 interrupts, 150 compactions),
`project-meta-analysis-2026-07-04/SYNTHESIS.md`, `prelaunch-audit-2026-07-09/inefficiencies.md` +
`dual-ui-refactor.md`, `LESSONS.md`, `CLAUDE.md`.

---

## Taxonomy — the distinct types

### 1. Post-compaction context amnesia (session-substrate, NOT app logic)
**Frequency: 260 errors — 33% of all 791 tool errors, the single largest class.**
Every ~1.6 h a compaction wipes the "files I've read" set; the agent immediately fires
`Edit`/`Write` on files it no longer holds tracked state for, gets a stale-state rejection, and
re-reads. Burst pattern: a compaction at 02:44 → 5 identical "File has not been read yet" errors
in the next 12 s. **Never self-healed across 7.5 weeks** — each of the 150 compactions restarted
the loop (`TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md` §1.A#1, §2). A related class, **stale-edit
target** (`old_string` no longer present because the file was reformatted/already-edited across a
compaction boundary), added another 50 errors, compaction-adjacent (§1.A#3).

### 2. Doc-churn / process tax — the "log everything" tax
**Frequency: docs-to-code commit ratio peaked 1.5–1.7:1 across c-06–c-12 (a ~6-week mid-project
plateau); one era (c-10) hit 1.54:1 as its stated peak** (`commits/INDEX.md` "Docs-to-code ratio
trend"). Almost entirely "log +N" progress entries, CHANGELOG pairings, and handoff/BACKLOG
checkpoints (`commits/INDEX.md` whole-history taxonomy: `docs` commits ranged 16%–63%, mode
~45–56%, dominant category in 14 of 19 eras). Root cause: an autonomous-run mandate ("log every
landed item") that had no fold-into-code discipline attached — every logged item got its own
standalone commit. This is distinct from useful documentation (design docs, LESSONS entries) —
it's specifically the *standalone commit* overhead, since git history itself, board state, and
CHANGELOG already carry the same information redundantly.

### 3. Harness-/vehicle-patching loops instead of questioning the test vehicle
**Frequency: at least 3 named multi-commit arcs, 11–24 commits each.** The pattern: a bug is
patched at the wrong layer repeatedly because the *test/validation vehicle itself* (not the
production code) is broken or mismatched to the bug class, and each patch attempt "fixes" a
symptom the vehicle can observe, without addressing the mechanism:
- **UAT env-delivery crisis** (TSK-1243): 11 commits over 10+ VM round-trips chasing `open --env`
  under `sudo -u` silently dropping env vars; harness-level patches (probe timeouts, async-await
  bridges) didn't stick — fixed only by a config-file side-channel that bypassed LaunchServices
  env-var drop entirely (`commits/INDEX.md` "big rework arcs" table).
- **Scroll-restore timing race** (TSK-1046/1047): 24 commits across 3 patch attempts sequencing an
  async handoff chain — fixed only by collapsing to a single pull-based source of truth
  (`tab.renderedScrollY`), not another sequencing patch (`commits/INDEX.md`).
- **Compositor occlusion**: 3 re-attempts in c-01 plus a 9-commit TSK-488 rework in c-05, "didn't
  stick until pixel-level (WindowServer `screencapture`) regression testing was mandated" — the
  in-process `ImageRenderer`/`cacheDisplay` vehicle gave a **false green** for the entire bug class
  because it rasterizes SwiftUI's own tree in isolation and can't see AppKit-layer occlusion
  (`commits/INDEX.md`, `d-lessons-1of2.md`, `CLAUDE.md` "compositor occlusion" section).

The `CLAUDE.md`-codified rule that emerged (`question-the-test-vehicle`, per MEMORY) is a direct
scar from this pattern: "3+ rounds of harness-patching → check for an established simpler pattern."

### 4. Diagnostic over-confidence / re-diagnosis loops
**Frequency: "the real bug" named 2–4× per arc; one arc (scroll-restore, June 23) hit 12 interrupts
in 58 minutes.** (`TEXTVIEW_STRUGGLE_METAANALYSIS` §1.B, "Diagnostic over-confidence".) A related,
board-specific instance: TSK-1046's complete fix + a 260-line on-screen UAT already existed on a
reaped ultracode worktree, never merged — **a full session was burned re-diagnosing and reinventing
a partial subset** before `git log --all` surfaced the prior work (`LESSONS.md:301`). Root cause is
cognition, not architecture — confirmed as the one class the tracker-redesign (v4) does NOT fix
structurally, only makes cheaper to falsify via fast-red gates (`TEXTVIEW_STRUGGLE_METAANALYSIS`
§2, §3.3).

### 5. Task-tracker lifecycle violations
**Frequency: 180 errors — the #2 error class, ~23% of all tool errors.** Illegal state transitions
(`reported→fixed`, `progress→review`, `ack→fixed` shortcuts), omitted required fields. **"Never
improved across 7.5 weeks despite constant rejection feedback"** (`TEXTVIEW_STRUGGLE_METAANALYSIS`
§1.A#2) — a pure procedural-friction tax with zero learning curve, because each rejection was a
dead-end retry rather than a structural fix. A related, lower-volume class: **board-identity
confusion** (~8 corrections) — conflating the tracker's `TSK-###` with Claude Code's own built-in
`TaskList #NNN`, updating the wrong item repeatedly (`TEXTVIEW_STRUGGLE_METAANALYSIS` §1.A#4;
codified later as `reference_board_vs_tasklist_numbering.md`).

### 6. Subagent/workflow fan-out runaway
**Frequency: one documented catastrophic instance (~75 agents from an intended handful, ~half a
session's token quota), one smaller instance (47-agent/172-finding pre-launch audit — controlled
and healthy by contrast).** The Canvas epic's design-spike research (giga-epic TSK-1342, c-17,
2026-07-01) recursively expanded from an intended 3-agent probe to ~75 agents before being reined
in; recorded same-day as a standing lesson ("never delegate broad research to general-purpose
agents") (`commits/INDEX.md` "big rework arcs" — Canvas epic row; `c-17of19.md` "Top 10 Most
Consequential" #3; MEMORY `feedback_no_broad_subagent_fanout.md`: "a 3-agent delegation fanned to
~75"). Contrast case: the 47-agent pre-launch audit (c-03) was bounded, severity-triaged, and
became a *reused, healthy* playbook for three subsequent audits — the difference was a defined
scope/kill-criteria vs. open-ended "explore this epic."

### 7. Worktree/build bloat from orphaned parallel-agent isolation
**Frequency: one measured catastrophic case — ~124 GB across 60 worktrees while `.git` itself was
36 MB; a related dated incident hit 96 GB / 97% disk with each worktree's cold SwiftPM debug build
alone ≈4 GB.** (`CLAUDE.md` "Worktree hygiene" section; `LESSONS.md:483-491` "Parallel ultracode
worktrees exhaust disk".) Mechanism: agent/workflow isolation spins up git worktrees, `--lock`ed
with the owner PID; a crashed or interrupted run leaves them locked forever, and each carries its
own independent `.build` directory — build artifacts (not committed work) dominate the bloat.
Compounding failure mode: worktrees isolate the *filesystem*, not *semantic scope* — three
"clean-boundary" agents independently added the same snapshot-on-save hook in separate worktrees,
producing duplicate work that only collided at merge time (`LESSONS.md:435`, TSK-1196).

### 8. Duplicate/parallel implementations (the dual-engine tax)
**Frequency: at least 5 distinct duplicated subsystems identified in a dedicated audit** —
"five find runtimes behind four state bags with divergent capabilities, three scroll-persistence
channels with three different keyings (the recurring TSK-821/1037/1041/1046/1047 bug family), two
syntax-highlight engines that classify tokens differently, two fold-region engines, two warm-WebView
caches" (`prelaunch-audit-2026-07-09/dual-ui-refactor.md` executive summary). Root cause: the app
grew a native (NSTextView/AppKit) rendering stack and a web (WKWebView/CodeMirror6) rendering stack
for the *same text lens* organically, feature-by-feature, without a single consolidation decision
made early — by audit time the split spans `.source`, `.editor`, `.rendered` markdown, raw HTML,
Canvas, and Walkthrough-mermaid as **six separately-wired WebView/native hosts**. The Rust-core
migration (CSV, hex, diff, transcript, formula) shows the antidote pattern already in-tree — see
"What worked" below — so this is a case of the antidote existing but not being applied to the
Swift-vs-web UI split from day one.

### 9. Architectural round-trip tax baked into the hot path (a *design*-level inefficiency, not process)
**Frequency: 1 finding, P2, confirmed live in the current codebase.** Every CM6 keystroke-batch
edit round-trips the *entire* document through Rust FFI via MessagePack (`cm_apply`) — ~5
whole-document allocations/copies per edit batch, then the full string is re-walked and
re-propagated to every downstream reducer (dirty-tracking, autosave, outline/breadcrumb), each of
which re-scans the whole buffer again (`prelaunch-audit-2026-07-09/inefficiencies.md` F1/F2). This
is O(n) per edit → O(n²) over a session on large files. Root cause: the incremental JS→Swift bridge
was correctly built to ship deltas, but the Swift-side handler immediately re-inflates to a full
string before crossing the FFI boundary the *second* time — the delta discipline wasn't carried
all the way through the pipeline. Distinct from the process-inefficiency types above: this is
*shipped design debt*, not wasted agent effort, but it is a direct rebuild-relevant "don't repeat
this" data point since it stems from the same organic-growth-without-an-end-to-end-contract pattern
as #8.

### 10. Over-deliberation / flip-flopping
**Frequency: qualitative, self-reported at least once verbatim** — *"I badly over-deliberated this
tick (many spikes, flip-flopping)"* (`TEXTVIEW_STRUGGLE_METAANALYSIS` §1.E). Lower-volume than the
other classes but named explicitly as a process struggle; likely undercounted since it doesn't
throw a tool error and only surfaces via self-report or owner interrupt.

---

## What worked — practices that earned their keep

- **Fold-docs-into-code directive (2026-06-22 owner directive) demonstrably cut the doc-churn tax
  in half.** Docs-to-code ratio fell from the 1.5–1.7:1 mid-project peak to ~0.30:1 (c-16) and
  0.48:1 (c-19), with c-19 reporting "zero standalone process-noise commits" (`commits/INDEX.md`).
  This is a clean before/after natural experiment inside the same project.
- **Severity-triaged audit-then-fix, reused as a repeatable ritual.** The first 47-agent/172-finding
  fanout (c-03) established a G1–G14 severity-batching pattern that was reused nearly verbatim for
  an 80-finding audit (c-04), a 17-pass quality sweep (c-18), and a crash-class audit (c-19) — by
  the end, "audit → batch by severity → land per-subsystem" was muscle memory, not a one-off cost
  (`commits/INDEX.md` "Process evolution").
- **Rust-core migration's staged-soak + parity-fuzz template avoided the duplicate-engine trap for
  new ports**, even while the *existing* Swift/web UI duplication (finding #8 above) went
  unaddressed. The A/A0/round2-4 soak stages plus differential fuzzing (vs. the Swift reference)
  caught 5 silent parity bugs pre-ship, and Swift-twin deletions later landed with zero reverts
  because the bridge+fallback was built first (`commits/INDEX.md` "big rework arcs" — Rust-core
  engine ports row).
- **DocumentModel SRP extraction as a scheduled, gated refactor sprint** (not opportunistic
  cleanup): 40 slices, 7542→5150 lines, zero render regression — proof that a *planned* debt-paydown
  sprint, gated slice-by-slice, avoids the rework churn that ad-hoc refactoring produces elsewhere
  (`commits/INDEX.md`).
- **The honesty/teeth-demonstration discipline was a net efficiency win despite its cycle cost.**
  68 deliberate revert-to-prove-red demonstrations, 12 held-for-gate admissions ("cannot
  self-validate"), 8 premature-fix-claim retractions — the agent caught and disclosed its own
  overclaims rather than letting them ship, converting what would have been *silent* rework
  (shipped-then-discovered-broken) into *visible*, bounded cycles
  (`TEXTVIEW_STRUGGLE_METAANALYSIS` §1.C).
- **Reduction-before-LLM methodology for post-hoc analysis itself is a portable efficiency
  pattern**: deterministic streaming reduction took the 1.30 GB session transcript to an 8.8 MB
  struggle corpus (~150:1 reduction) *before* any token spend, then fanned Haiku/Sonnet only over
  the reduced corpus (`TEXTVIEW_STRUGGLE_METAANALYSIS` §4).

## What hurt — costly failures and root-cause mechanism

- **Post-compaction amnesia (33% of all tool errors) is a pure session-substrate defect, not an
  app-logic or agent-skill problem.** Mechanism: the harness's "files I've read" tracking is
  session-scoped state that a compaction silently zeros while the agent's *plan* (which files it
  intends to touch next) survives in the re-injected summary — so the agent acts on stale
  intentions against a fresh-but-untracked file-state, gets rejected, and burns a retry cycle.
  It **never improved over 150 compactions** because nothing in the loop teaches the agent to
  re-read defensively after a compaction boundary — it's a structural gap, not a skill gap.
- **Board lifecycle violations were 100% flat over 7.5 weeks (180 errors) despite constant
  rejection feedback** — the tracker's illegal-transition errors gave no learning signal because
  each rejection was a dead-end retry, not a state the agent could inspect and correct from. This
  is the harness giving error *messages* without giving error *recovery scaffolding*.
- **Harness-patching loops burn the most when the diagnostic layer and the bug's actual layer are
  different** — UAT env-delivery (11 commits, "harness introspection" ~12% of one slice's commits
  per the doc), scroll-restore (24 commits), compositor occlusion (12+ commits across two eras).
  The common mechanism across all three: the FIRST few patches targeted the layer the *symptom*
  was observed at (the probe, the sequencing, the in-process snapshot) rather than the layer the
  *defect* actually lived at (a silent env-var drop, an async race with no single source of truth,
  a compositor-level occlusion invisible to in-process rendering). Each got progressively cheaper
  to diagnose only after the team explicitly asked "is my test vehicle even capable of observing
  this bug class" — which happened late, after multiple burned rounds each time.
- **Worktree bloat (124 GB) was a pure hygiene gap, not a design flaw** — the harness/workflow tooling
  had no automatic reap-on-completion or reap-on-crash step, so a crashed or interrupted parallel
  run left `--lock`ed worktrees (and their ~4 GB `.build` each) accumulating silently until disk
  pressure forced discovery. Zero committed work was ever at risk (worktree dirs are disposable),
  making this pure *unmonitored* waste rather than risk.
- **The dual-engine UI split (finding #8) accumulated because no single "pick the surface, migrate,
  delete the twin" decision was made until late** — each new surface (rendered markdown, raw HTML,
  Canvas, Walkthrough) was independently wired to whichever stack was locally convenient at the
  time it was built, and the resulting fragmentation (5 find runtimes, 3 scroll-persistence
  channels) directly *caused* a recurring, expensive bug family (TSK-821/1037/1041/1046/1047 —
  the same scroll-restore arc counted under harness-patching above). This is the clearest case in
  the corpus of a process-inefficiency (deferred consolidation decision) *manufacturing* a
  downstream engineering-inefficiency (duplicate state, recurring bugs) — the two are causally
  linked, not independent.
- **Subagent fan-out runaway was a token-burn event with no circuit breaker** — an "explore this
  epic" research spike had no agent-count ceiling or budget checkpoint, so it recursively expanded
  unbounded until roughly half a session's quota was gone before anyone noticed and intervened.

## Design implications for the rebuild

**Do differently FROM DAY 1 (structural fixes, not SOP reminders):**

1. **Make the agent's working session stateless/short-lived by construction, not by discipline.**
   The metaanalysis's own verdict: "anything short of 'the working session is short-lived and
   rehydrates from the tracker' leaves [amnesia] in place" — this is exactly the tracked-project's
   v4/HLD "stateless cells" design (fresh spawn per ticket, contract + curated refs re-injected).
   Don't rely on "re-read files after compaction" as a prompt-level rule; that rule already existed
   here in spirit and the error rate stayed flat.
2. **Give the tracker a state machine the runner walks mechanically, not one the agent transitions
   by hand.** 180 flat-lined lifecycle-violation errors over 7.5 weeks is proof that "the agent will
   learn the correct transitions from rejection feedback" does not happen. Either the tracker
   enforces valid transitions structurally (agents only emit data-plane verbs; a runner walks the
   lifecycle) or the same tax repeats.
3. **Land the fold-docs-into-commit rule in CLAUDE.md/SOP before commit #1**, not after a
   mid-project directive. This project's own before/after (1.5–1.7:1 → 0.3–0.5:1) is the strongest
   evidence in the corpus that this single rule change halves a real, measured tax — don't wait 6
   weeks to discover it.
4. **Pick the rendering-stack consolidation decision (native vs. web, or whatever the rebuild's
   equivalent fork point is) explicitly, in writing, before the second surface is built** — not as
   a later "surface consolidation" epic. The dual-UI tax here wasn't one bad call, it was N
   uncoordinated locally-convenient calls; a single early ADR-style decision (with a documented
   migration plan for exceptions) prevents the fork from happening at all.
5. **Cap subagent/workflow fan-out with a hard ceiling and a budget checkpoint, enforced by the
   harness, not by prompt.** "Never delegate broad research to general-purpose agents" is a lesson
   that had to be *learned* here after burning ~half a session's quota; a hard agent-count ceiling
   (or mandatory single-pass/read-only default) for exploratory research removes the need to learn
   it again.
6. **Automate worktree/build-dir reaping on completion AND on crash recovery**, and default build
   output outside the worktree (`SWIFTPM_BUILD_DIR`/`CARGO_TARGET_DIR` equivalents) from the first
   parallel-agent workflow — don't wait for a 124 GB incident to add the hygiene step.
7. **When a bug survives 2 patch attempts, make "is the test vehicle even capable of observing this
   defect class" a mandatory checkpoint before a 3rd attempt** — codify the pixel-vs-in-process
   distinction (or whatever the rebuild's equivalent false-green trap is) as an explicit gate, not
   a retrospective lesson. Every named harness-patching arc here (UAT env-delivery, scroll-restore,
   compositor occlusion) paid double-digit commits before this checkpoint was applied.

**Accept as inherent cost (budget for it, don't try to design it away):**

- **Diagnostic over-confidence / re-diagnosis loops** are agent cognition, not architecture — the
  metaanalysis explicitly marks this the one struggle class its own next-gen tracker design does
  NOT fix structurally, only makes cheaper to falsify (fast-red gates). Budget cycles for it; don't
  expect a process fix to zero it out. A cheap mitigating SOP: hold ≥2 candidate causes until a
  check discriminates them, rather than nominating "the real bug" on the first plausible signal.
- **VM/render test-harness investment is permanent infrastructure tax, not a one-time setup cost** —
  every new validation surface here (webview, T4 live-app, T5 pixel, AX automation) needed its own
  multi-commit unblock spread across the whole timeline (TCC, ulimit, launchctl, env-delivery,
  ARG_MAX). Plan a standing maintenance budget for this, don't schedule it as a single milestone.
- **Some over-deliberation and self-correction cycles are the visible cost of an honesty discipline
  that is otherwise a net win** — 68 teeth-reverts + 12 held-for-gate admissions cost cycles but
  prevented silent false-closes; don't tune the discipline away to save the cycles.

## Portable rules — candidate directives for the next project

1. **Sessions rehydrate from durable state, never accumulate a load-bearing in-memory read-set
   across a compaction boundary.** If compaction can happen mid-task, the task's working unit must
   be short enough, and its state external enough, that compaction is a no-op for correctness —
   don't rely on "re-read defensively" as a prompt rule.
2. **The task tracker enforces its own lifecycle machine; agents only ever emit data-plane verbs.**
   No agent-driven state transitions that can be issued illegally and merely rejected — that pattern
   demonstrably never self-corrects (180 flat errors / 7.5 weeks here).
3. **Fold process documentation (handoffs, progress logs, changelogs) into the code commit it
   describes; no standalone doc-churn commits.** Adopt this from commit #1 — this project's own
   halved-ratio result after adopting it mid-project is the evidence.
4. **Any architectural fork that duplicates a subsystem across two stacks (two UI toolkits, two
   language runtimes, two storage formats) gets an explicit, written, single decision before the
   second instance is built** — not resolved by whichever surface happens to need it next.
5. **Cap exploratory/research subagent fan-out with a hard ceiling (single-pass or a fixed agent
   count) enforced by the harness** — "explore broadly" without a bound reliably runs away (3→75
   agents, ~half a session's quota, observed once here and already a standing lesson).
6. **Automate worktree/build-artifact reaping (unlock → remove → prune) as part of every
   parallel-agent workflow's completion AND crash-recovery path**, and default build output outside
   the worktree from day one. Treat "check for stale worktrees" as a scheduled maintenance task, not
   an incident response.
7. **A bug that survives two independent patch attempts triggers a mandatory "is my test/validation
   vehicle capable of observing this defect class" checkpoint before a third attempt** — every
   multi-round harness-patching arc in this corpus (11–24 commits each) paid for skipping this
   checkpoint.
8. **Treat honest self-correction (teeth-reverts, held-for-gate admissions, retracted claims) as a
   feature to preserve, not overhead to optimize out** — it converts silent shipped-then-discovered
   rework into visible, bounded, cheap-to-audit cycles.
