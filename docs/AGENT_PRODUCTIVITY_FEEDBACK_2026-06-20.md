# Agent productivity feedback — what blocked one-shotting (2026-06-20 session)

Written for the MCP-tools-for-agents effort. Every item is grounded in a *real*
incident from this session, categorized by root cause, with the concrete tool
capability that would have prevented the friction. Ranked roughly by impact.

---

## TL;DR — the single biggest lever

**The verification-tier gap.** The overwhelming majority of wasted cycles this
session came from one structural fact: **agents can host-test the MODEL layer
but cannot verify RENDER/on-screen behavior** without a slow, flaky VM lane.
Every "fixed it" → "no it's still broken" loop (scroll, twice) traces to this.
A host test going green is *not* evidence the user's problem is solved, but it
*reads* like it is. If you build one thing: **a fast, agent-drivable render/pixel
verification loop** (or a crisp, automatic "is this claim host-provable or
render-path?" classifier that refuses false confidence).

The second biggest: **agents are blind to real machine state** (memory, what
other agents touch, what tests cover a file) and to **the codebase's wiring**
(who consumes X, where is Y hooked). Most of the rest below is a flavor of one
of those two.

---

## Category 1 — Visibility (the dominant blocker)

### 1a. Render-path behavior is invisible to host tests → false "done"
- **Incident:** the scroll-reset bug. Model-layer fixes (TSK-1037/1041) passed
  host tests and were relayed as "fixed" — **twice** — while the on-screen bug
  never changed (the offset never reached the live WebView). Burned owner trust.
- **Why it blocks one-shot:** the agent's strongest available signal (host gate
  green) is *uncorrelated* with the actual acceptance criterion (pixels).
- **Tool:** (a) a render-verification MCP that an agent can call cheaply
  (screenshot a component + assert), not a 5-min VM round-trip; (b) failing that,
  a `classify_change(files)` tool that returns `host-provable | render-path |
  needs-VM` so the agent *knows* it can't self-certify and says so.

### 1b. Real process memory is unreadable from the shell
- **Incident:** a test process showed 77 GB. I called it "RAM" (wrong), then
  "benign VSZ" (also wrong). The owner had to correct me twice: Activity
  Monitor's "Memory" = `phys_footprint` (includes the *compressed* pool), RSS
  was 200 MB, VSZ was 415 GB — three numbers, all misleading in isolation.
- **Why:** `ps`/`top` expose VSZ + RSS but not `phys_footprint`/compressed/
  swapped, which is the number that actually matters. Agents will misdiagnose.
- **Tool:** `process_memory(pid)` → `{phys_footprint, resident, compressed,
  swapped, is_compressible_estimate}` + a system view `{free, compressor_pool,
  swap_used}`. Directly buildable; would have saved a 4-message detour and a
  wrong agent-stop.

### 1c. No cross-agent "who's touching what file" map
- **Incident:** three "clean-boundary" agents (save-path, storage, viewer) all
  ended up editing the LocalHistory area — **two added a duplicate
  snapshot-on-save hook**, two added duplicate secret-exclusion. Discovered only
  at integration.
- **Why:** parallel agents have no shared registry of file ownership / pending
  edits; "clean boundaries" in the prompt aren't enforced.
- **Tool:** a live `active_edits` registry — `claim_files(agent, globs)` +
  `who_touches(path)` — so an orchestrator can detect overlap *before* dispatch
  and agents can see contention.

### 1d. What tests cover this file/symbol?
- **Incident:** changed the invisibles glyph `¶`→`↵` with a build-check only;
  missed `CodeMirrorBundleTests.testInvisiblesPluginUsesIntelliJStyleGlyphs`
  which pins the literal glyph. It reached `main` red.
- **Why:** no fast "what asserts on this file/symbol/string?" lookup; a grep for
  the glyph drowned in unrelated matches.
- **Tool:** `tests_covering(path|symbol|string)` → the test cases that touch it,
  so an edit knows its blast radius before commit.

### 1e. Orchestration state across many agents
- **Incident:** at peak there were ~10 worktrees/agents in flight; tracking
  which were done / running / dead / merged / superseded was manual and
  error-prone (I reaped, mis-pathed the reap, re-did it).
- **Tool:** a worktree/agent dashboard: per worktree `{branch, status, commits
  vs main, files touched, .build size, merged?}`.

---

## Category 2 — Tooling / harness gaps

### 2a. Long external runs (VM) stall sub-agents
- **Incident:** scroll sub-agents repeatedly hung waiting on multi-minute VM
  GUI-lane runs — one burned ~27 min / 295 K tokens and returned *nothing*
  ("waiters armed, waiting"). Pattern recurred across 3 agents. Workaround:
  the main loop drives every VM run via background bash; agents must STOP before
  the VM.
- **Why:** the sub-agent wait primitive can't bridge a 4–20 min external job.
- **Tool:** a proper async-job primitive agents can await without spinning
  (submit → poll/notify), OR a documented "hand long jobs to the parent" contract
  baked into the harness rather than re-learned each time.

### 2b. Tests can OOM the whole machine (no resource sandbox)
- **Incident:** an agent's naive `LineDiff` LCS allocated an O(n×m) matrix → a
  test ballooned to ~77 GB `phys_footprint`, driving the Mac into 25 GB swap and
  thrashing everything (including the owner's UI).
- **Why:** `swift test` runs with no memory/time ceiling; one runaway test takes
  the machine, not just the test.
- **Tool:** memory/CPU/time-bounded test execution (ulimit/cgroup-style) so a
  runaway test is *killed*, not the host — plus a per-run peak-footprint report.

### 2c. Load-flaky perf benches → false reds, every gate
- **Incident:** `CrossFileSearchBench`, `TabOpPerfTests`, `MsgPackReader`,
  `FileWatcher` failed under concurrent build/test load, repeatedly, then passed
  in isolation. Each cost a triage round-trip.
- **Why:** wall-clock asserts run in the same parallel sweep as everything else.
- **Tool:** a flake classifier (`is_known_flake(test)`), and/or a quiesced perf
  lane; the gate should auto-retry/annotate wall-clock failures rather than
  surfacing them as hard reds an agent must hand-triage.

### 2d. Worktree `.build` bloat
- **Incident:** 10 worktrees × ~3 GB `.build` = ~28 GB (plus 27 GB main). The
  owner noticed the disk. CLAUDE.md *documents* pointing build output outside
  worktrees (`CARGO_TARGET_DIR`/`SWIFTPM_BUILD_DIR`) but it isn't set up.
- **Tool:** auto-configure a shared build dir when creating an agent worktree;
  a `reap_worktrees(merged|dead)` helper that reclaims them safely.

### 2e. Board free-text search is broken
- **Incident:** `task_list q=<keyword>` returns the same priority-sorted page
  regardless of query (flagged independently by two agents). Couldn't find
  existing tickets by topic → risk of duplicates or working ticket-less.
- **Why:** a bug in the board tool itself.
- **Tool:** fix `q` (it's load-bearing for "don't re-file the same thing").

---

## Category 3 — Process / workflow friction

### 3a. Lane-walk ceremony for every landing
- **Incident:** landing a one-line fix required `task_restate → task_triage →
  task_claim → task_record` (reported→ack→triaged→progress→fixed) — 4 MCP calls
  with reads between, for trivial work. Repeated for every item.
- **Tool:** a single `land(id, summary, artifacts, to)` that walks the legal
  lane path server-side; agents shouldn't orchestrate the state machine by hand.

### 3b. Over-claimed "fixed" tickets (board ↔ code drift)
- **Incident:** the board-reconcile found **31 over-claims** — tickets marked
  fixed/validated where work was partial or "model shipped, UI never wired" (the
  AU-plugin epic was the archetype: marked fixed, the headline capability sat in
  a transition *note*, not a ticket). Required a whole reconcile pass to catch.
- **Why:** nothing verifies a completion claim against the code; remaining work
  hides in comments on closed tickets.
- **Tool:** `verify_claim(ticket)` — correlate the ticket's claim with the actual
  code/tests and flag "reachable in UI? test exists? matches title?". This
  session's manual reconcile *is* that tool, done by hand at ~3 M tokens.

### 3c. Commit-before-gate slips (mine)
- **Incident:** I committed the invisibles change on a build-check, not the full
  gate → a pinned test reached `main` red. Honest self-critique: the gate is the
  contract; "it's just a resource file" was a rationalization.
- **Tool/guardrail:** a pre-commit hook that runs the relevant filtered tests for
  the changed files (using 1d's coverage map) so "small" changes can't skip it.

---

## Category 4 — Code navigation / comprehension

### 4a. Every task starts with grep-to-find-the-seam
- **Incident:** locating the right hook cost repeated grep round-trips each time —
  the save path, the panel-layout init, the highlight consumers, the three scroll
  channels, the version-source seam, the HTML render path/CSP. Minutes per task
  in "where is this wired."
- **Why:** grep finds strings, not *relationships* (who calls, who consumes,
  what's the data path). Big files (DocumentModel ~7 K lines) make it worse.
- **Tool (probably your core thesis):** semantic code navigation —
  `who_calls(sym)`, `who_consumes(type)`, `call_path(from,to)`,
  `where_wired(feature)`. This would compress the most-repeated motion of the
  whole session. The app *has* an LSP/tree-sitter core — expose it as agent MCP.

### 4b. "Is this already built but unwired?" is expensive to answer
- **Incident:** repeatedly the right move was "check what exists first" and it
  paid off — FolderTreemapView, FocusWorkMode, LocalHistoryStore, TextTransform,
  DiskConflictResolver were all **built-but-unwired**; several tickets were just
  "wire the existing tested engine." But discovering that took a full read each
  time, and the AU case was *missed* until the owner remembered it.
- **Tool:** `find_unwired(symbol|type)` — definitions with no production caller —
  surfaces the cheapest high-value work (wire what's already tested) and prevents
  rebuilding what exists.

---

## Category 5 — Clarity / prioritization (least friction, but present)

- **Mostly fine this session** — the owner's asks were clear and the curated
  list + chipping order worked well. The friction that *did* appear:
  - **Render-vs-host acceptance criteria were implicit** — "is it fixed" meant
    pixels, but the agent's default proof was the model. (Same as 1a; it's a
    clarity problem dressed as a visibility problem.)
  - **A genuine architecture decision (keep NSTextView + rust tree-sitter?)**
    needed me to assemble facts (bundle sizes, file caps, consumers) that were
    scattered — answering it well took measurement, not lookup. A `feature_facts`
    surface (size, caps, consumers, design-doc refs per subsystem) would make
    these decisions one-shot. (The answers were actually *in* the code as
    design-locked constants — but only findable by reading.)

---

## Ranked: what to build first (for max agent throughput)

1. **Semantic code nav MCP** (4a/4b) — who-calls / who-consumes / where-wired /
   find-unwired. Hits the single most-repeated motion; the LSP/tree-sitter core
   already exists to power it.
2. **Render/pixel verification loop OR a host-vs-render classifier** (1a) — kills
   the false-"done" cycle that cost the most trust this session.
3. **`process_memory` + system memory MCP** (1b) — cheap to build, prevents a
   whole class of misdiagnosis; would have saved a wrong agent-stop.
4. **Resource-bounded test execution** (2b) — one runaway test should never take
   the machine. High blast-radius prevention.
5. **`verify_claim` / board-code reconcile** (3b) — turns the 3 M-token manual
   reconcile into a tool; keeps the board honest so the loop picks real work.
6. **Cross-agent file-ownership registry** (1c) + **worktree dashboard** (1e) —
   makes parallel fan-out safe instead of conflict-prone.
7. **Fix board `q` search + a single `land()` lane-walk** (2e/3a) — small, daily.
8. **Flake classifier / quiesced perf lane** (2c) — stops the recurring
   false-red triage tax.

---

## Honest self-assessment (not tool-fixable — agent discipline)

These were *mine*, and worth separating from tooling gaps so the tools aren't
asked to paper over judgment:
- Relayed model-green as "fixed" for a render bug (twice) — should have led with
  "model-proven, on-screen unverified."
- Misread memory metrics (VSZ/RSS/phys_footprint) before grounding — should have
  measured the right number first.
- Committed without the full gate once.
- Over-spawned concurrent builds/agents, contributing to the memory pressure I
  then investigated.
The pattern: **over-confidence at the verification boundary.** Better tools (1a,
1b, 2b) would reduce the *opportunity* for these, but the discipline is to state
uncertainty at that boundary, not resolve it optimistically.
