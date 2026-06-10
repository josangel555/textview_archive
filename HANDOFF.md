<!-- CLAUDE-HANDOFF v1 -->
# Handoff — user-facing fix run + measurement harness; TSK-592 trace ready to parse  (2026-06-10)

**Session:** claude-mdv (autonomous loop, cron :03/:13/:23/:33/:43/:53)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `8f1d2b0` (+ uncommitted LESSONS/BACKLOG/CLAUDE/HANDOFF handoff edits — commit them)

## Mission
USER-FACING bug fixes first (owner 2026-06-10, encoded in `docs/TASK_WORKFLOW.md` §3
rank 1). Two standing owner corrections from this session now govern all perf work:
**measure with the PerfSignpost/xctrace harness, don't attribute by elimination**, and
**anything that opens app UI (including profiling launches) runs on the UTM VM**.

## Current state
- **Fixed + installed (release /Applications/TextView.app, 44MB, codesign OK):**
  TSK-599 explicit session-opens under `~/Documents` (TCC guard now implicit-only,
  418b0b4) · TSK-600 `+`→GoTo `~` spawns a session (goToPathNewSessionIntent, f5cb39b) ·
  TSK-609 rail toggle reveals collapsed sections (expandedStateKey reveal-on-on,
  c82498f) · TSK-266 close paths materialize the lazy neighbor
  (settleSelectionAfterClose, 5336262; residue = MountedPanesLRU, live-validation).
- **Measured (not guessed):** TSK-598 MD-open lag = **94% WebKit**
  (`WKWebView.loadToFinish` 3457ms vs ~230ms app-side, VM capture of LESSONS.md,
  no mermaid). Parked to owner: approve supervised MountedPanesLRU (now data-backed;
  also clears TSK-266 residue + tab-switch lag).
- **Harness built:** `scripts/vm-profile.sh <file> <secs> [open|resize]
  [release|debug]` (1cb22cd + 8f1d2b0) — rsync → VM build → xctrace
  `--instrument os_signpost` under the asuser bridge → in-sudo chown → pull.
  `resize-sweep` script verb (ScriptRunner) + pure `ResizeSweep.width` (3 tests).
  Fixed the BROKEN doc recipe (`--instrument` was missing, 1668d68) + added the
  `WKWebView.loadToFinish` signpost.
- **In flight — TSK-592 (resize jank):** capture DONE, parse NOT started. A 25s
  symbolicated (debug-config) trace of open + ~4s resize sweep sits at
  **`/tmp/mdv-592-resize.trace`** (6.5MB, host). Nothing else torn.
- **Next action:** parse that trace (see How to resume #2) and fix what the
  main-thread samples indict.

## Key decisions & rationale
- TSK-599 contract change: explicit user gestures open/persist sessions under TCC
  roots; only implicit launch paths keep the guard (owner's whole workspace is under
  `~/Documents`; silent no-op was the bug). Documented in `docs/uat/smokes/sessions.md`.
- TSK-598/266/592 perf: no blind fixes — measurement first (owner). MountedPanesLRU
  stays parked until the owner approves the supervised session.
- Ad-hoc inline sudo heredocs over ssh are classifier-denied; committed harness
  scripts (vm-smoke.sh shape) are the sanctioned route — hence vm-profile.sh.

## Gotchas / lessons (full entries in LESSONS.md "2026-06-10 (later)")
- `xctrace --template 'Time Profiler'` does NOT record custom-subsystem signposts
  without `--instrument 'os_signpost'`; `log show` is NOT a fallback (OSSignposter
  intervals aren't persisted).
- The sudo'd asuser bridge root-owns everything it writes — chown in-bridge
  (vm-profile.sh does; TSK-502 class, two new sites found).
- Release bundle is stripped ⇒ Time Profiler samples are addresses; use the debug
  config for attribution, release for honest signpost timings.
- `resize-sweep` drives setFrame, not a live drag — `NSWindow.inLiveResize` paths
  unexercised (caveat on TSK-592).

## Files that matter
- `scripts/vm-profile.sh` — THE VM profiling pipeline (modes/configs in header).
- `docs/PERFORMANCE_PROFILING.md` — fixed recipe + signpost table (incl. loadToFinish).
- `Sources/MarkdownViewer/ScriptRunner.swift` — `resize-sweep` verb (~line 92).
- `Sources/ViewerCore/Perf/ResizeSweep.swift` — pure sweep schedule (+tests).
- `Sources/ViewerUI/MarkdownRenderedView.swift` — loadToFinish signpost pair.
- `Sources/ViewerUI/Git/TrackedReposChannel.swift` — norm-cache miss/reset counters
  (TSK-591 live checklist).
- `/tmp/mdv-592-resize.trace` — UNPARSED symbolicated resize capture (the next action).
- Begin/End signpost pairing parser: in `docs/AUTONOMOUS_PROGRESS.md` LOG +135 context;
  working python in the transcript — re-derive: export os-signpost table rows, resolve
  xml id/ref dedup recursively, pair Begin/End by (category, name, signpost-id).

## Open questions / blockers
- **MountedPanesLRU supervised session** — parked on TSK-598 (waiting:human), now
  measurement-backed. Clears TSK-598 + TSK-266 residue + tab-switch in one move.
- TSK-591 hover lag — needs a 10s live hover + read of `trackedRepos.norm.miss`/
  `.reset` counters (owner's machine or VM), three candidates on the ticket.
- TSK-589 session-eviction policy (options a–d) — still parked.

## Tracker (board @ :8787, project `tasked`, agent `claude-mdv`)
- Fixed today: TSK-599, 600, 609, 266 (all with checks + commits).
- In progress: TSK-592 (capture done, parse next — checkpoint comment has the recipe),
  TSK-591 (instrumented, live-validation), TSK-598 (measured, waiting:human).
- Pool remaining: TSK-593..597, 601..608, 610 (unexplored children) + bumped P1s
  TSK-267/313/314/327/359/363/522/523.

## How to resume
1. `git -C /Users/me/Documents/workspaces/claude/markdown_viewer status` — commit the
   handoff doc edits if dirty (`docs: handoff 2026-06-10 (later)`).
2. **TSK-592 parse (the in-flight item):**
   `xcrun xctrace export --input /tmp/mdv-592-resize.trace --toc` → find the
   `time-profile` table → export via
   `xcrun xctrace export --input /tmp/mdv-592-resize.trace --xpath
   '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'` → aggregate
   MAIN-THREAD top frames inside the sweep window (sweep ≈ t+5s..t+9s; anchor with
   the os-signpost lane in the same trace). Fix what the samples indict; if samples
   are clean, suspect inLiveResize-gated paths (driver caveat on the ticket).
3. Then continue the pool: next unexplored children (TSK-593..597, 601..608, 610) —
   `task_get` each, headless-first, gate, commit per item, log to
   `docs/AUTONOMOUS_PROGRESS.md`, install via `bash scripts/build-app.sh release --install`.
4. Per-tick discipline: read `docs/TASK_WORKFLOW.md` every firing; board via
   `mcp__tasked__*` only; UI-opening anything → `scripts/vm-profile.sh` /
   `scripts/test-in-vm.sh` on the VM; measure perf before attributing.
5. Cron job `82bf2d3a` (session-only) fires :03/:13/...; recreate via CronCreate if
   the session restarted (same prompt as previous ticks).
