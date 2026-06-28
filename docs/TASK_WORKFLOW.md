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

**CRON / AUTOMATED RUNS — two hard rules (owner directive 2026-06-20):**
**(1) Work INLINE — never use the `Workflow` tool or any multi-agent fan-out.** The main loop does
the work directly, ONE item at a time (spike → implement → test → gate → commit). Fan-out is ONLY for
owner-triggered "ultracode" sessions (a 120-agent reconcile cost ~6M tokens — the cron run is lean/inline).
**(2) NEVER stop with "no more work."** There is ALWAYS work; if the feature pool looks empty, DRAIN the
board (validate `fixed` with teeth, push `review`, triage `reported`, fix bugs). A "no work" stop is a
process failure — see §5.

---

## 0.5 Spike + design autonomy + chipping order (OWNER DIRECTIVE 2026-06-13)

Two standing rules, set during the 2026-06-13 wishlist intake:

**Spike + design are AUTO-APPROVED — never ask permission to investigate or design.**
For any non-trivial ticket (epic, feature, research question, ambiguous ask) the
agent runs the **SPIKE** (scope · what already exists in-repo · feasibility · concrete
options) AND produces the **DESIGN + task breakdown**, autonomously, then implements.
Do **NOT** `task_park` a ticket merely because it "needs design" or "needs a decision
about approach" — that investigation IS the agent's job. Default to investigating, not
asking. (This is why the intake's auto-parks were wrong: an epic is a spike to run, not
a question to ask.)

**Re-surface to the owner ONLY** (via `task_park`, and only AFTER a spike has framed it)
for: (a) a genuine **dependency approval** — a new crate/library/tool; (b) a **true
undifferentiated ambiguity** — you genuinely cannot tell WHAT is being asked (e.g. a
bare "Music" with no other signal); or (c) a hard **blocker** the agent cannot resolve.
A taste/branding call (app name) or a prioritization call (what to cut) still gets a
spike that FRAMES the options first, then a crisp parked question — never a bare "what
do you want?".

**Chipping order (refines §3's rank list):**
1. **Regressions** (re-break of once-working behavior) — first.
2. **Bug fixes** (defects / crashes / wrong behavior) — user-facing first.
3. **Minor features that need NO design** (toggles, menu items, wiring an
   already-built backend, near-free parity items).
4. **Epics** — run spike → design → breakdown → implement (all autonomous per the
   rule above); land in slices.
5. **Very-large / aspirational** items — file-and-forget for now (a backlog ticket,
   no active design until the smaller lanes drain).

**Intake provenance:** the 2026-06-13 wishlist source is
`docs/research/wishlist-2026-06-13/SOURCE.md`; the triage report (counts, dedup, items)
is `TRIAGE.md` in that dir; every filed ticket carries the `wishlist-2026-06-13` tag and
a `[WISH][P-tier][bucket]` title prefix, and the parked ones were converted to `spike`
type (this directive).

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

**0. PRIMARY SELECTOR (owner directive 2026-06-22): DRAIN `BACKLOG.md` top-down — the SINGLE curated worklist.**
The repo-root `BACKLOG.md` is the ONE owner-curated worklist (the dated `docs/CURATED_TASKS_*.md` + `WORK_QUEUE.md`
were folded into it + archived under `archive/tracking-2026-06-22/`), priority-ordered (P0 user-facing bugs/perf →
P1 user-facing features → P2 internal/rust-core/test). Each firing: pick the next actionable item, drive its
`TSK-###` on the board to at least `review`/`validated`. The board (`tasked`) is the SYSTEM OF RECORD for task
STATE — advance items THERE, do NOT check them off in a file. The rank rules below order *within* the worklist and
govern the FALLBACK once it is fully drained — and a fresh USER-FACING regression (rule 1) still pre-empts. When an
item is owner-blocked, `task_park` it and take the next. When `BACKLOG.md` is drained, fall to the groomed pools
(rule 2) then the validation drain (rule 1.5).

Rank order each firing (within the queue, and the fallback when it is drained):

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
2.5. **MIGRATION POLICY (OWNER DIRECTIVE 2026-06-11): do NOT build/optimize Swift engines
   that are port targets.** "Tasks that are eventually going to be ported are not worth
   building in Swift core." Concretely: an engine with an approved Rust port ticket
   (find — TSK-630, markdown→HTML — TSK-631, transcript/JSONL parsing — TSK-632,
   fuzzy matching — TSK-633; CSV/diff/hex already ported) takes **user-facing bugfixes
   only** on the Swift side — no perf work, no internal refactors, no feature additions,
   no test backfill on the Swift twin. Deep-audit findings against those Swift engines
   (e.g. the Swift CSVParser O(n²) cell scan, Swift ReDoS wall-clock caps) get re-tagged
   `port-superseded` and closed against the Rust port instead of fixed twice. The Rust
   port + the contract work that unblocks it (Phase 1: windowed snapshot, error model v2,
   envelope; TSK-634 FFI velocity) rank ABOVE Swift-side internal-quality work — this
   amends rule 3's old "[PORT] last" for the *engine* ports specifically (the TUI/web
   *front-end feature* `[PORT]` lane stays last-resort).
3. *(superseded 2026-06-05 ranking, kept for context: SwiftUI app over the Rust `[PORT]` lane —
   still true as a tiebreak for FRONT-END feature ports; engine ports are governed by 2.5.)*
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
- **Regression tests must have teeth (mechanics).** A green never shown to go red is not a
  guard. For every fix/feature you land: break the code under test (a "mutation") → confirm the
  new test goes RED → restore. This is hand-run mutation testing of the *specific* thing you
  shipped (there is no teeth-automation script, by design). Four documented footguns —
  internalize them or you'll re-learn them the hard way (`LESSONS.md` has the war stories):
  - **Independent oracle.** The *expected* side of a teeth assertion must NOT flow through the
    helper you're mutating, or both sides move together and stay green (self-referential false
    green — `LESSONS.md` ~3147). Use a different std API or hardcoded literals.
  - **The mutant must have compiled.** SwiftPM's incremental build can miss a same-second
    rewrite, so a "surviving" mutation may just be the OLD binary — confirm `Compiling <module>`
    ran. And a surviving mutation isn't always a weak test: verify the mutant actually changes
    behavior first (`LESSONS.md` ~3187).
  - **Restore with the inverse Edit, never `git checkout`, until committed.** `git checkout --
    <file>` during a teeth check restores the *committed* state and WIPES your uncommitted fix +
    new test (`LESSONS.md` ~2803).
  - **Don't mutate while a build is in flight.** A teeth mutate/restore cycle during a background
    `build-app.sh` hard-fails SwiftPM ("input file modified during build"). Order per item:
    teeth → restore → commit → gate → THEN install (`LESSONS.md` ~2910).
  - **UI render-path teeth are VM-only** (T5 pixel tests; revert→rebuild→confirm FAIL→restore) —
    consistent with the self-validation policy above: host tests cover the model, not the pixels.
- **Log the narrative** in `docs/AUTONOMOUS_PROGRESS.md` (survives compaction; the board is live
  state, the doc is the story).
- **Update `CHANGELOG.md` for USER-FACING changes (owner ask, every firing).** If the item that
  landed is something the owner can SEE or FEEL in the app (feature / fix / addition), add a
  one-line plain-language entry to the repo-root `CHANGELOG.md` under today's date (Added / Fixed /
  Performance), written from the user's seat, newest first. EXCLUDE tests/validation/CI/refactors/
  infra — those stay in `AUTONOMOUS_PROGRESS.md`. A tick with no user-facing change leaves it alone.

---

## 5. The actionable pool is almost NEVER genuinely empty (owner directive 2026-06-20)

**Do NOT stop with "there is no more work."** Before any HOLD, DRAIN THE BOARD — this is real work,
not paper cuts: validate `fixed` items (with teeth that would catch a regression), push `review`,
triage `reported` into actionable lanes, re-verify landed work, fix the next bug. Only when EVERY lane
is genuinely exhausted AND the remainder is truly owner-gated is a **documented HOLD** the honest move
— a no-op that keeps `main` gate-green, with the owner-gated blockers crisply listed in `DECISIONS
NEEDED`. Even then, prefer board-draining (validate / review / triage) over marginal paper-cut backfill.
A "no work" stop while `reported`/`fixed`/`review` still have items is a PROCESS FAILURE, not a HOLD.

---

## 6. Pointers

- `docs/AUTONOMOUS_PROGRESS.md` — run narrative + `DECISIONS NEEDED` (owner-gated queue).
- `HANDOFF.md` (repo root) — fresh/compacted-session bootstrap (the live handoff; old dated `docs/HANDOFF_*` are archived under `archive/tracking-2026-06-22/`).
- Memory: `project_autonomous_loop_mandate`, `feedback_tasked_board`,
  `reference_tasked_board_is_shared_across_projects`, `project_audit_pending_list_stale`.

---

## 7. The autonomous tick prompt (canonical source)

The autonomous loop is driven by a session cron (`CronCreate`, every 5 min, session-only)
that injects the prompt below each tick. The scheduler does NOT store it on disk — so when
you re-launch the cron in a new session, copy it from HERE so it stays consistent with this
SOP. Selector is `BACKLOG.md` (the dated `CURATED_TASKS_*` / `WORK_QUEUE.md` were folded in +
archived 2026-06-22).

This is the COMPREHENSIVE base — copy it on re-launch and PARAPHRASE per the current
situation (don't ship it generic). Keep the procedure intact; adapt the priority block
to BACKLOG's current `🎯 OWNER PRIORITY ORDER`.

> Autonomous drain tick. MANDATORY FIRST STEP every tick — read NOW, do not skip: (1) docs/TASK_WORKFLOW.md IN FULL; (2) the "Automated / autonomous runs (SOP)" section of CLAUDE.md; (3) BACKLOG.md — the SINGLE curated worklist (its top "🎯 OWNER PRIORITY ORDER" block is authoritative; the dated CURATED_TASKS_*/WORK_QUEUE.md were folded in + archived 2026-06-22). Adapt this prompt to BACKLOG's current priority — as of 2026-06-27 that is P0a (eval/AX self-driving + agent-drivable interfaces: TSK-1254 out-of-process AX driver → TSK-1255 test-pyramid doc → mdv.* AX ids + script-bus action surface → TSK-1256 element-refs) and P0b (battle-test the fixed/review pile to VALIDATED with TEETH — task_validate + a checks artifact for pure-logic/model/FFI/parser; render/WebView/AX-pixel cap at review for owner/VM), CO-EQUAL + interleaved; then P1 = the NEXT WAVE 12; then P2+ = the rest of the board (mcp__tasked__task_next / task_list).
>
> Then DRAIN RELENTLESSLY toward done. NEVER idle, hold, or stop with "no more work" — that is a PROCESS FAILURE; there is ALWAYS work: build features, fix bugs, validate fixed with teeth, reconcile stale/mislabeled tickets toward the owner-close queue, harden untrusted-input/parser code with audit tests, re-verify, triage. When the host-completable BUILD surface is genuinely drained (BACKLOG-confirmed), do NOT manufacture filler or ship risky-blind render/data/security changes — validate + reconcile + audit-harden + keep the owner-unblock list current, and act the MOMENT a new board item / env-unblock / owner decision appears. BUILD render-path / VM-tail / perf features TOO — host-test the model, leave render/VM validation at review; do NOT hold for owner on-screen confirmation.
>
> Work INLINE, ONE item at a time: spike → implement → test → host-gate (bash scripts/test-headless-gate.sh) → commit per item; land rebase+ff; keep main headless-gate-green. COMMIT HYGIENE: fold LESSONS/HANDOFF/AUTONOMOUS_PROGRESS/CHANGELOG updates INTO the item's code commit — no standalone process-noise commits. If an item is GENUINELY owner-blocked (dep approval / true ambiguity), task_park it and IMMEDIATELY take the next item — never let a block stop the loop.
>
> ENV-HEALTH (TSK-1289 — the session hot-loop incident): if work stalls, or before heavy build/git, run `pgrep -fl "git.*remote.*update"` — orphaned (PPID-1) git fetches alive for hours are the SourceKit-LSP zombie-hang that killed the prior session; SIGKILL them. The global git http.lowSpeedLimit=1000 / http.lowSpeedTime=30 timeout is set so stalled fetches self-abort.
>
> Commit trailer: Claude-Session: &lt;current session URL&gt;
