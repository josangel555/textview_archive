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
confidence}`, `task_advance {id, agent, to, understanding, note, summary}` (one-shot walks
reported→fixed), `task_record` (to progress/fixed/review), `task_validate` (evidence-gated close,
see §4), `task_park` (owner gate + ping), `task_flag`. Agent name: `claude-mdv`.

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

1. **Owner priority (2026-06-05): SwiftUI app (`Sources/`) features & fixes** over the Rust
   TUI/web ports. `[PORT]`-tagged tasks are deprioritized — only fall to them if nothing else
   is actionable.
2. **Real bugs / perf / security** (`type: bug|perf|security|leak|race|contract`) over features,
   features over **test/quality paper cuts**. Loudest current pain = the **perf cluster**
   (TSK-108/266/267/270/273: tab close/switch/open ~1s, HEX slow).
3. **Headless-actionable now** vs **live-gated**. Decide honestly:
   - *Headless* (land it): pure logic in `ViewerCore`/`ViewerKit`, model layer, parsers, FFI
     decode, security guards, correctness bugs. Validate with `scripts/test-headless-gate.sh`.
   - *Live-gated* (needs a window): anything in the SwiftUI view tree, layout/chrome, view-mode
     switching, perf you can only feel on screen. The VM can't build (TSK-401), so live = a
     **supervised host** `bash scripts/build-app.sh debug` (T4 ViewModeMatrix gate).
4. **Owner-decision-gated** (a UX/format/algorithm call): don't guess — append to the
   `DECISIONS NEEDED` block in `docs/AUTONOMOUS_PROGRESS.md`, then pick a different actionable task.

**Anti-paper-cut rule:** test backfill / coverage is allowed ONLY when no real bug/feature/perf
task is headless-actionable. Never let it become the per-firing default. If you've done it 2+
firings running, stop and re-read this section — surface the live-gated blocker to the owner
instead (one crisp ask in DECISIONS NEEDED) rather than manufacturing marginal tests.

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
