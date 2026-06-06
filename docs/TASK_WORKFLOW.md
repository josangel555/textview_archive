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

A helper usually lives at `/tmp/board.py`. `/tmp` is ephemeral — if it's gone, recreate it:

```python
# /tmp/board.py — minimal tasked-board caller.  Usage: board.py <tool> '<json-args>'
import sys, json, urllib.request
tool = sys.argv[1]; args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
body = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
                   "params":{"name":tool,"arguments":args}}).encode()   # NB: arguments, not params
req = urllib.request.Request("http://localhost:8787/mcp", data=body,
        headers={"Content-Type":"application/json","Accept":"application/json, text/event-stream"})
raw = urllib.request.urlopen(req, timeout=20).read().decode()
for line in raw.splitlines():                                           # unwrap optional SSE framing
    if line.strip().startswith("data:"): raw = line.strip()[5:].strip(); break
d = json.loads(raw)
print(d["error"] if "error" in d else d["result"]["content"][0]["text"])  # result text is double-encoded JSON
```

Gotchas (these have bitten before): args go under **`arguments`** (standard MCP, not `params`);
responses may be **SSE-framed** (strip the `data:` line); `result.content[0].text` is a **JSON
string** you decode again.

**Tools:** `task_next {agent}` (ranked head — but see §2, it does NOT project-filter), `task_list
{project, state?, ...}`, `task_get {id}`, `task_create {project, agent, title, report, type,
confidence}`, `task_advance {id, agent, to, understanding, note, summary}` (one-shot walks
reported→fixed), `task_flag`, `task_record`, `task_park`. Agent name: `claude-mdv`.

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

## 4. Work the task (lifecycle + discipline)

- **Lifecycle:** `reported → ack → triaged → progress → fixed`. **The agent only reaches
  `fixed`.** A human gates `review → validated → done`. Use `task_advance` to walk it, with an
  honest `understanding` / `note` / `summary` (include the commit SHA).
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
