# Project meta-analysis — repo + board archaeology, cross-checked against the session-jsonl study
2026-07-04 · method: 2 Sonnet grunt agents (repo archaeology; board paging) + Fable synthesis.
Companion to the owner's `TEXTVIEW_STRUGGLE_METAANALYSIS_2026-07-04.md` (1.3 GB jsonl study) —
independent data sources, convergent conclusions.

## The numbers

**Repo (52 days, 2026-05-14 → 07-04):** 3,489 commits (~67/day). Week 23 alone: 1,082 (31%).
By type: docs 1,288 · feat 915 · fix 379 · test 334 · perf 110 · refactor 93.
**Sources/** 162,129 LOC (748 files) · **Tests/** 171,930 LOC (1,120 files) — test LOC > source LOC.
**rust-core/** 50,178 LOC. **812 markdown files** repo-wide; 120 under docs/research/.

**Board (TSK-101→1543, 1,431 tasks):** validated 735 · review 284 · reported 224 · wontdo 57 ·
done 49 · fixed 42 · ack 29 · triaged 11 · progress 0. Open:terminal = 590:841.
Blockers: live-validation 83 · owner-decision (deprecated) 23 · dep-approval 8 · supervised 2.
Hygiene finds: foreign-project bleed (TSK-856..880 belong to another app), 12 id gaps,
2 terminal tasks without validator/dismisser attribution.

## Finding 1 — the process tax is ~⅓ of all motion

**36.5% of all commits are doc-only; 17% of the ENTIRE history is appends to ONE file**
(`docs/AUTONOMOUS_PROGRESS.md`: 14,987 lines, 1,031 touches — the #1-churn file; CHANGELOG #2 at
463; HANDOFF #4 at 245). Six of the ten highest-churn files are tracking docs, not code. Add the
sprawl: ~35 dated point-in-time design docs never merged back, 5 superseded root-level bug
trackers, LESSONS.md at 3,803 lines. **Interpretation:** this is the compaction-survival
apparatus — handoffs, progress logs, backlogs — i.e. the cost of having no durable execution
substrate. It is the same tax the jsonl study measured as error classes (260 amnesia + 180
lifecycle), seen from the commit ledger instead. v4's tracker-as-substrate (stateless cells,
evidence rows, tree) deletes the *reason* this apparatus exists.

## Finding 2 — the human-as-serializer piles are the board's dominant shape

review (284 = 48% of open) + validated-awaiting-done (735) are the two biggest piles; 83
live-validation blockers + 23 deprecated owner-decision blockers are the same pattern in blocker
form. progress = 0 (everything parked). This independently corroborates the jsonl study's
39.8%-validated-stall finding and the owner's "human gates breed overclaiming" rule: the queue
always re-forms in front of the human. v4's merge-queue-closes + runner-posted `usable` +
30-second `accepted` is aimed at exactly this shape.

## Finding 3 — re-fix loops vs epic buildouts (the over-confidence residual, quantified)

Repeat-TSK commit chains split cleanly: **epic buildouts** (TSK-1110 ×63, 1213 ×35, 585 ×26 —
additive slices, healthy) vs **re-fix loops** (TSK-1046 ×13 — wrong hypothesis repeatedly;
TSK-1243 ×21 — harness iteration). The loops match the jsonl study's densest-interrupt clusters
(12 interrupts/58 min). No architecture fixes this; it needs the SOP rule: hold ≥2 candidate
causes until a discriminating check splits them, and put a "discriminating check" field in bug
contracts.

## Finding 4 — quality discipline was real; coverage direction was the gap

Test LOC exceeds source LOC; 68 teeth-reverts (jsonl study); the board's honesty fields audit
clean (0 validated_by/state mismatches). Yet the real-UI apex held only 24 T4/T5 fns for ~30
surfaces — the letter of "every change ships with tests" satisfied headlessly while pixels went
unguarded. Codified fix: the four MANDATES (TEST_PYRAMID §MANDATES, 2026-07-04): per-surface
real-render matrix (TSK-1539) · AX interaction everywhere (TSK-1543) · agent-driven UAT ·
required-evidence-classes named in every ticket.

## v4 assessment (owner ask: does it make sense / will it work / what's missing)

**Verdict: adopt. The design is unusually well-grounded** — its mechanisms map 1:1 to the four
independently-measured pathologies (amnesia→stateless cells; lifecycle violations→runner-walked
states; false-done→probe+runner-rerun; serializer→merge-queue+accepted). Convergent evidence:
this session hit compaction file-amnesia TODAY; the board agent burned 129k tokens paging 20
pages just to COUNT things (frontier views exist for this); TSK-1215 sat ~3 weeks on a two-way
door resolved in one sentence (default-with-veto exists for this).

**Worker-loop division (main agent = groom/gates, Sonnet executes): will work, with one linchpin.**
Evidence: batch-1 this session (5 tickets executed by one subagent off self-contained briefs,
teeth-proven); the fleet failure was scale/limits, not capability. The linchpin is the CONTRACT:
tickets must be worker-executable without session context.

**Gaps to add to the DLD (beyond the doc's own §8 list, which is good):**
1. **Groomed-contract SCHEMA pins `required_evidence[]`** (WV-DOM/AX-press/T5-pixel/…), derived
   from the surface catalog; the runner refuses `green` without those evidence classes. This is
   mandate #4 made mechanical — the doc has checks but not the contract shape.
2. **Model-tier routing table + escalation ladder** — the worker-loop core is unspecified: node
   class → model tier; N work_failures at tier k → one attempt at k+1 → surface. Reserve
   Fable/Opus for groom/review/synthesis. (The jsonl study's own Haiku→Sonnet→Opus pipeline is
   the template.)
3. **Named serial resources in the scheduler** — the VM GUI lane is a singleton (one screen, one
   input stream): T4/T5/AX serialize, WV parallelizes. Scope locks cover files; add resource
   locks or the runner oversubscribes the VM.
4. **Quota-window awareness in dispatch** — the 9-agent fleet died on a session-limit reset
   (~2M tokens lost). budget_kill handles cost; add: no XL dispatch near limit windows +
   checkpoint cadence so a kill loses ≤1 ticket.
5. **Doc-corpus disposition in P3** — migration covers the board corpus; 812 md files do not
   migrate themselves. LESSONS themes → check-authoring SOP + policy rows; dated design docs →
   index-or-archive; else workers retrieve stale designs.
6. **≥2-hypotheses SOP + discriminating-check field** for bug tickets (finding 3; the doc's own
   honest residual).

## Pointers
- Owner's jsonl study + v4 design: `~/Documents/workspaces/claude/project_tracker/pinboard/`
- Mandates: `docs/TEST_PYRAMID.md` §MANDATES · CLAUDE.md §The four testing MANDATES
- PM-model memory: `project_pm_v4_worker_loop` (main-agent/worker division + ticket-as-contract)
