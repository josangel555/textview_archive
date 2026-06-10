# TASK_WORKFLOW — how every firing works off the tracker

**READ THIS FIRST, EVERY FIRING. This is the operating procedure. Follow it.**
The project tracker is the **`tasked` board** (HTTP JSON-RPC at `http://localhost:8787/mcp`).
It is the **single system of record** — NOT `BACKLOG.md`, NOT the Claude Code TaskList, NOT this
repo's docs. Those are narrative/history; the board is the live state. When in doubt, query the
board.

---

## 0. The prime directive (why this doc exists)

The owner caught the loop **drifting into paper cuts** (endless pure-logic test backfill) while the
real backlog sat untouched. That is the failure mode this doc exists to prevent.

**Each firing: pull the highest-value REAL task off the board and move it forward.** Test backfill
is a *last resort*, never the default. If the only thing left is paper cuts, you are probably
ignoring the board or mis-prioritizing — re-query and re-read §3.

---

## 1. Query the board (recipe)

**Drive the board ONLY via the `mcp__tasked__*` MCP tools** (the server at
`http://localhost:8787/mcp` is already connected). The old `/tmp/board.py` helper and the human
REST endpoint are **retired** — never recreate or spoof them. These tickets are NOT the built-in
Claude Code TaskList (`#NNN` ≠ board `TSK-NNN`); always `task_get` a board id before acting on it.

**Tools:** `task_next {agent}` (ranked head — but see §2, it does NOT project-filter), `task_list
{project, state?, ...}`, `task_get {id}`, `task_create {project, agent, title, report, type,
confidence}` / `task_create_many`, `task_advance {id, agent, to, understanding, note, summary}`
(one-shot walks reported→fixed), `task_record` (to progress/fixed/review), `task_validate`
(evidence-gated close, see §4), `task_park` (owner gate + ping), `task_dismiss` (already-fixed/
wontfix/duplicate/invalid/foreign — already-fixed needs demonstrative proof), `task_retract`,
`task_flag`, plus grooming tools (`task_restate`, `task_triage`, `task_claim`, `task_comment`,
`task_link`, `task_set_parent`, `task_tag`, `task_block`/`task_unblock`). Most accept
`quiet: true` for ~90%-smaller echoes. Agent name: `claude-mdv`. The server occasionally restarts
during owner-side upgrades — on a connection error, retry once before assuming it's down.

markdown_viewer tasks live under **project `tasked`** (prefix `TSK`).

---

## 2. The board is SHARED across projects — filter foreign tasks

The `tasked` board also holds `agent:forge`'s tasks (public API / SSE / CSV-streaming, e.g.
TSK-104). `task_next` is NOT project-aware and will surface them. **Before acting on any task,
grep this repo for the symbols/feature it names** — if they don't exist here, it's foreign; skip it.
(Memory: `reference_tasked_board_is_shared_across_projects`.)

---

## 3. Prioritize (pick the ONE highest-value actionable task)

Rank order each firing:

1. **Owner priority (2026-06-10): USER-FACING bug fixes first.** Bugs the owner hits in the
   running app — open/view/edit/navigation behavior, rendering glitches, perf the user FEELS
   (tab open/close/switch latency, HEX slow, Editor→HEX flash), data-loss/state bugs. These
   outrank internal-quality work (gates, lint walls, contract hardening) even when the internal
   item is "more severe" on paper. The deep-audit `[S2]/[S3]` user-visible bug/perf tickets and
   owner-reported `BUG:` tickets are the richest pool.
1.5. **VALIDATION DRAIN (added 2026-06-10 board review): when no P1 user-facing bug is
   actionable, drain the `fixed` lane before starting NEW work.** ~56 tickets sat at `fixed`
   pre-dating the 2026-06-07 self-validation policy. Re-running a fixed ticket's evidence
   FRESH is not bookkeeping — the TSK-108 re-validation caught a live regression (TSK-621)
   that had already shipped to the owner's installed app. Per ticket: re-run the named suites
   on current `main` (host + the VM lane it claims), then `task_validate` on green, or file
   the regression and bounce the ticket to `progress` on red. Never validate off stale
   fix-time claims.
2. **Then other real bugs / perf / security** (`type: bug|perf|security|leak|race|contract`)
   over features, features over **test/quality paper cuts**. With the 2026-06-10 user-facing
   epic (TSK-590) reconciled, the groomed default pools are: the `TSK-538` rust-core epic's
   P1 children (579/581/582 — headless, real), then the backend-not-surfaced UI items
   (TSK-463/464/469 — user-visible, mostly built).
3. *(superseded 2026-06-05 ranking, kept for context: SwiftUI app over the Rust `[PORT]` lane —
   still true as a tiebreak; `[PORT]` remains the last-resort lane.)*
4. **Headless-actionable now** vs **live-gated**. Decide honestly:
   - *Headless* (land it): pure logic in `ViewerCore`/`ViewerKit`, model layer, parsers, FFI
     decode, security guards, correctness bugs. Validate with `scripts/test-headless-gate.sh`.
   - *Live-gated* (needs a window): anything in the SwiftUI view tree, layout/chrome, view-mode
     switching, perf you can only feel on screen. **UI validation runs on the UTM VM**
     (`scripts/test-in-vm.sh`; GUI/pixel lane needs `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password>`)
     — the VM builds + tests fine now (TSK-401/439/500 all fixed); never run UI tiers on the host.
5. **Owner-decision-gated** (a UX/format/algorithm call): don't guess — `task_park` the ticket
   (pings the owner) and/or append to `DECISIONS NEEDED` in `docs/AUTONOMOUS_PROGRESS.md`, then
   pick a different actionable task.

**Anti-paper-cut rule:** test backfill / coverage is allowed ONLY when no real bug/feature/perf
task is headless-actionable. Never let it become the per-firing default. If you've done it 2+
firings running, stop and re-read this section — surface the live-gated blocker to the owner
instead (one crisp ask in DECISIONS NEEDED) rather than manufacturing marginal tests.

**Board hygiene (added 2026-06-10 board review — cheap, fold into any firing):**
- **Stale leases**: a `progress` ticket whose lease expired days ago under a retired agent name
  is a zombie — reconcile it (re-scope, dismiss-as-superseded with proof, or re-claim and
  finish), don't let it squat in the lane.
- **Dedupe before acting**: the audit fleets filed overlapping findings (e.g. TSK-552≡545).
  Before working a finding, search the board for its twin; `task_link`/`task_dismiss` the dup.
- **Gated suites must be IN a lane list**: when a fix adds an env-gated test suite
  (`MDV_RUN_WEBVIEW_TESTS` etc.), wiring it into `test-in-vm.sh` + `nightly-vm.yml` filter
  lists IS part of the change — a gated suite in no lane list runs NOWHERE and its green
  history means nothing (how TSK-621 shipped silently).

---

## 3.5 Lane goals (OWNER DIRECTIVE 2026-06-09 — what each lane MEANS)

Each lane is a distinct kind of work, not just a status. Drive every ticket left-to-right:

- **Reported** — intake. New issues land here (owner or agent files them: feature requests,
  bugs, findings). Filing is cheap; file generously.
- **Acknowledged (`ack`)** — preliminary research. Understand the issue; determine what it
  needs: a design? HLD/LLD? missing information? debugging? a refactor? Restate the
  understanding on the ticket (`task_restate`).
- **Triaged** — make it implementable. Research, break down into sub-tasks, write design docs,
  debug, groom: implementation plan, LLD, dependencies, prerequisite checks, testing plan,
  validation plan, acceptance criteria. A ticket leaving triage should be executable without
  re-deriving any of this.
- **In progress (`progress`)** — work that generates artifacts: code, tests, docs, commits.
- **Fixed / review / validated / done** — built → evidence attached → regression-guarded →
  closed. See the lifecycle rules below.

**Blocked by owner?** Update the ticket asking for the feedback/approval (`task_park` — kind +
question + context, pings the owner) and MOVE ON to the next available task. Never idle on a gate.

**The goal is every task at Done.** There is always something to work on — the question is only
prioritization, consolidation, strategic ordering. If one lane is gated, work another lane of the
same ticket (triage/groom/design) or another ticket.

**Validation is automated — the human is not in the loop.** Use the whole testing pyramid: unit →
integration → headless → UI tests → screenshots/smoke. Screenshots/smoke are acceptable for
*validation* but a **last resort for verification** — prefer simpler, more reliable automated
tests (model/state assertions, behavior tests) to verify changes; use pixels only where nothing
cheaper can prove the behavior (compositor/occlusion class). Disturb the human only if you must.

---

## 4. Work the task (lifecycle + discipline)

- **Lifecycle:** `reported → ack → triaged → progress → fixed → review → validated → done`.
  Use `task_advance` to walk it, with an honest `understanding` / `note` / `summary` (include the
  commit SHA). **Self-validation policy (owner, 2026-06-07):** the agent MAY close its own work via
  `task_validate` (to `validated`/`done`) — but ONLY with a `checks` artifact proving an automated
  test that exercises the actual behavior and would fail on regression. Host-testable logic →
  self-validate; rendered-pixels behavior → needs the VM lane evidence first (or hold at `fixed`).
- **Mark `progress` before starting; `fixed` only when fully done AND validated** (gate green).
  Never `fixed` on a partial/failing change. If blocked mid-way, leave it open and file the blocker.
- **Commit per item.** One-line subject. Land on `main` as a fast-forward (no merge bubbles).
- **Re-verify with the CENTRAL gate on the COMMITTED commit:** `scripts/test-headless-gate.sh`
  (Swift) / `scripts/rust-core-gate.sh` (rust-core). Read the real result, not a wrapper.
- **Regression tests must have teeth:** mutation-check (break the fix → test fails → restore).
- **Log the narrative** in `docs/AUTONOMOUS_PROGRESS.md` (survives compaction; the board is live
  state, the doc is the story).

---

## 5. When the actionable pool is genuinely empty

Then — and only then — a **documented HOLD** is the honest move (a no-op that keeps `main`
gate-green), with the live-gated / owner-gated blockers crisply listed in `DECISIONS NEEDED`.
Do NOT fill the gap with marginal paper cuts. The owner would rather see "blocked on X, here's
the one decision I need" than ten throwaway tests.

---

## 6. Pointers

- `docs/AUTONOMOUS_PROGRESS.md` — run narrative + `DECISIONS NEEDED` (owner-gated queue).
- `docs/HANDOFF_2026-06-05.md` — fresh/compacted-session bootstrap.
- Memory: `project_autonomous_loop_mandate`, `feedback_tasked_board`,
  `reference_tasked_board_is_shared_across_projects`, `project_audit_pending_list_stale`.
