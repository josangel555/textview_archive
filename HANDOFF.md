<!-- CLAUDE-HANDOFF v1 -->
# Handoff — autonomous run 06-16→18; shipped 906/917/820/574/836/850/947; VM-validated 5825t/0-fail; GOOD-ROI host-wins DRAINED  (2026-06-18)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `b3a3aae` (verify with `git log -1`; the Vim/953 block below is PRIOR-session history, still accurate)

> **OWNER likely BACK** (today is 2026-06-18; expected return was ~06-17 PM). The 10-min cron `50d0fbc8` ran
> the loop unattended and shipped 5 items (below). **The host-clean win well is now DRAINED** — what remains
> in `WORK_QUEUE.md` needs OWNER DIRECTION (see "Next action"): VM/Instruments traces for the P0 perf items,
> shortcut-key decisions for the parked cluster, or a design-first render/refactor pick. `main` is gate-green.

## Mission
Autonomous loop. The owner re-armed it: a **10-minute cron** drives the Automation SOP to **drain
`WORK_QUEUE.md` top-down**, each item → board `≥review`, commit per item, gate once per batch.

## Current state
- **Done + verified this session:**
  - **Vim mode (TSK-679)** shipped + installed to `/Applications/TextView.app`: opt-in `View → Vim Mode`
    (`@replit/codemirror-vim` 6.3.0, Compartment-gated), `:w`/`:wq`/`:x` save, footer NORMAL/INSERT/VISUAL
    chip, blue block cursor. Host teeth green; live keystroke/pixels = VM tail (TSK-679 stays `review`).
  - **VM harness fix (TSK-953, validated):** GUI-lane UAT false reds were a cross-user-temp issue — root's
    `/var/folders/.../T` is SIP-locked (can't `chmod`); fix = fixtures under the **spawn user's home** +
    AppLauncher in-place chown. Cm6/Sidebar UAT 31→0.
  - **`WORK_QUEUE.md` reorganized** (active-first, completed appended) + **30 board tickets merged in**
    (rust-core/perf into §0, small/build into A, partial-continuations into B, medium+test-infra into C,
    epics into D). Owner-gated 343/470 marked `[⊘]`.
  - **`docs/FEATURE_EXPLORATION_2026-06-16.md`** — Jupyter notebook architecture (host-kernel via
    jupyter-server; Option-A primitives vs embed-Lab vs Thebe; Pyodide discard), localhost browser-tab
    design, 7-feature feasibility. **New epics filed:** TSK-955 (RSS), 956 (AU/MIDI/VST), 957 (Macros),
    958 (Universal Paste); enriched 717/676/690/682.
  - **Loop cron `50d0fbc8`** live (`4,14,24,34,44,54 * * * *`, session-only, 7-day auto-expire); fires only
    when the REPL is idle.
  - **Build/test ✅** (this checkpoint): `swift build` clean + headless Swift gate PASSED + rust-core gate
    green → `main` @ `b293260` fully green, **no blockers**.
  - **UTM VM ✅ validated + cleaned:** Swift 6.3 `swift build` green (forward-compat); reclaimed ~1.4 GB
    (removed redundant `~/swift.pkg` installer + `/tmp/mdv-*` scratch) → **5.7 GB free (87%)**. `.build`(2.8G)
    + Caches left INTACT (offline mirror — never wipe). `dist/` ~1 day stale → render/UAT needs `test-in-vm.sh all`.
- **Done this autonomous run (06-16→18), all gate-green, committed per item:**
  - **TSK-906** (`bc93d6f` → review): palette dismiss refocuses the editor (`editorFocusRequest` nonce).
  - **TSK-917** (`b675551` → review): CM6 gutter non-selectable + default cursor (`.cm-gutters` CSS).
  - **TSK-820** (`6e4c821` → VALIDATED): removed 5 dead per-method FFI exports (all envelope-routed; rust + headless gates).
  - **TSK-574** (`a4973ad`+`16b0fb3` → VALIDATED): zero-consumer pub surface — `pub(crate)` 6 helpers, deleted
    dead `from_table`, marked 3 deliberate future-API items; WireError was already done (577/669).
  - **TSK-836** (`0d59480`+`cadb5ea` → review): per-class swift-test timing tool (`scripts/test-timings.py/.sh`
    + `TestTimingsTests`). Caught+fixed a parallel-vs-serial reporter trap (LESSONS). Ran the real measurement → 849/850 scoped.
  - **TSK-850** (`ee140da`+`4150b91`+`4eb396c` → review): shared batched `GitTestRepo` (one shell vs 4 git spawns)
    + migrated **6** ViewerCoreTests git classes (HistoryStats/Panel/GrepLog/CumDiff/ScopeDiff/GitClientStatus).
    Within-target migrations EXHAUSTED; the rest are ViewerUITests (cross-target → need a TestSupport SwiftPM target,
    POOR ROI — the 836 measurement proved the cost is git-WORK not spawns, so the restructure buys only seconds).
  - **TSK-947** (`abaa36c` → review): ⌘F gated off in HTML-rendered mode (no more invisible find bar) — pure
    `canFindInPage` gating, host-tested; live menu-grey = VM tail. Also diagnosed **905**'s root cause (no
    first-responder mgmt for the preview → fix-ready, but VM-gated for over-grab risk).
  - **VM-validated the whole run** (`test-in-vm.sh`, Swift 6.3): 5825 tests / 0 failures — but FIRST caught + fixed
    a flaky test I'd introduced (836's `test_countsAllOutcomes`: stdout-Pipe broken-pipe race → exit 120 on the VM
    only; fixed file-based, `6b128d2`; LESSONS). So all accumulated Swift+rust changes are confirmed VM-compile/
    headless-clean (render/live of the review-state items is still the GUI-lane VM tail).
  - **Coverage MEASURED** (`b3a3aae`): `swift test --enable-code-coverage` → pure-logic non-engine files ~100%
    (ByteSize/BreadcrumbPath/AudioMetadataRows); the only gaps are IO/error/framework paths → the owner-endorsed
    backfill fallback has NO meaningful target (measured, not assumed; AUTONOMOUS_PROGRESS).
  - **rust-perf dive-deep spikes (board comments, fix-ready/owner-framed):** TSK-564 — FFI double-copy located
    (CoreClient.swift:89-102 = MdvBuf→[UInt8]→unframe `Array(frame[4...])`); safe decode-in-place fix designed
    (NOT a UAF — synchronous decode before free, owned types); architectural (touches every FFI call site) →
    bench-gate + supervise. TSK-543 — cm_apply is the per-keystroke full-doc round-trip keeping Swift's text
    mirror; fix = stateful editor session in the core = a REMOTE-CORE design (owner-framed, not a quick fix).
  - Parked **936/937/938** (shortcut-key UX decision, `waiting:human`); design/scope notes on **905/910/947/948/908/849/850/573/564/543**.
- **In flight:** nothing mid-edit. Tree clean (except untracked non-ours `archive/Untitled.txt`, `untitled2.md`).
- **Next action — NEEDS OWNER DIRECTION (host-clean wins drained):**
  - **P0 app-perf (892/887/888/889/890-891-895/908)** — all need a **VM/Instruments trace** (measure-don't-guess).
    908 is now scoped: SwiftUI `.contextMenu` materialization latency (render, not host-logic). Best done with the
    owner supervising a VM-profiling session, or approve me to run `scripts/vm-profile.sh` unattended.
  - **Shortcut cluster 936/937/938** — parked `waiting:human`: pick keys + confirm "view-only" semantics.
  - **Render-design items (905/910/947/948)** — each needs a render slice (design notes on the board).
  - **Systemic build-speed (849/850)** — 850 within-target DONE (6 classes share `GitTestRepo`); the rest needs a
    TestSupport SwiftPM target (cross-target) — POOR ROI (spawn-only gain) → owner judgment. 849 = per-site
    condition-waits (sleeps load-bearing). **573** (web→`core::theme` palette) = design-first + a visual change to the
    web UI (owner-reviewable). All scoped on the board.
  - **Clean GOOD-ROI autonomous work is EXHAUSTED** — verified across WORK_QUEUE + the groomed pool (573/845/382/492/675/787/788
    are all gated / design-first / profile-gated / epic / question). Continuing autonomously would mean poor-ROI churn (the
    TestSupport restructure), owner-judgment calls (573 visual, shortcut keys, 845 profile), or context-heavy board hygiene
    (~20 zombie `progress` claims). The loop is HOLDING for direction: point it at a P0 perf VM trace, the shortcut keys,
    or OK a design-first refactor (573 / TestSupport).

## Key decisions & rationale
- Vim via `@replit/codemirror-vim` (owner-approved) over hand-rolling — mature plugin; Compartment + opt-in.
- Harness fixtures under **spawn-user home**, not `/tmp` — `/tmp` fails the MCP `open_path` containment fence;
  root temp is SIP-locked. Home satisfies both cross-user read/write AND containment.
- Merged the 30 into existing sections by **type/size** (not a dated block) per owner — so they prioritize
  alongside everything else.
- Cron is **session-only** (matches the prior loop) — re-arm if the session restarts.

## Gotchas / lessons (also in LESSONS.md)
- **Vim `:w` is a no-op** unless `Vim.defineEx`'d to the app save; re-export `Vim`+`getCM` (not just `vim`);
  `vim()` first in baseExtensions; blue `.cm-fat-cursor` theme must be ordered AFTER the plugin's theme.
- **Embedding localhost web UI in WKWebView needs an ATS exception** for http/ws to localhost (TSK-717 spike).
- **The board (`tasked` MCP @ localhost:8787) can go DOWN** mid-session (server not listening / MCP
  disconnect). The built-in Claude Code `TaskList` (`#NNN`) is a DIFFERENT system — never drive the board
  through it. On reconnect, reload `mcp__tasked__*` via ToolSearch.
- **VM SIP cross-user-temp trap** (TSK-953) + **stale-`dist/` trap** — both in LESSONS.md.

## Files that matter
- `WORK_QUEUE.md` — the priority SELECTOR (reorganized; active §0/A/B/C/D up top, Completed appended).
- `docs/TASK_WORKFLOW.md:94` — the SOP; §0 already directs draining `WORK_QUEUE.md` top-down.
- `docs/FEATURE_EXPLORATION_2026-06-16.md` — Jupyter/browser/feature feasibility + the 4 new epics.
- `scripts/test-in-vm.sh` — VM lanes; `test` (headless) vs `all` (rebuilds dist/); GUI lane needs
  `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password>`.
- `Tests/ViewerUITests/AppLauncher.swift` + `Harness/LaunchHarness.swift` — the cross-user fixture machinery
  (spawn-user home + in-place chown). **TSK-954 follow-on: `MCPClient` (in PluginsAndMcpAutomationUATTests)
  must also spawn as the console user.**
- Vim wiring: `scripts/codemirror-build/entry.js`, `Sources/ViewerUI/Resources/codemirror/codemirror.html`,
  `Sources/ViewerCore/CodeMirrorBridge.swift`, `Sources/ViewerUI/{CodeMirrorEditorView,ContentView,DocumentModel,StatusBar}.swift`.

## Open questions / blockers
- **TSK-954** (`fixed`) — PMA UAT: `MCPClient`-as-console-user fix is ready, not landed (needs VM verify). BACKLOG.
- **TSK-810** (Stage-B hex carve-out) + **#5–9 Swift-twin deletions** — owner decision (Rust-deprecation endgame).
- **~167 items in review+validated** = the owner-close / validation tail; **~20 zombie `progress`** claims
  (dead leases) cluttering the board — offered a board-hygiene pass, owner hasn't prioritized it.

## Tracker (`tasked`, project `tasked` = markdown_viewer, 846 tasks; board BACK UP)
- TSK-953 → `validated`; TSK-954 → `fixed` (PMA follow-on deferred); TSK-679 → `review`.
- TSK-955/956/957/958 → `reported` (new epics); TSK-717/676/690/682 → enriched (comments).

## How to resume
1. Read this + `docs/TASK_WORKFLOW.md` (the SOP). The **cron `50d0fbc8`** fires the loop every 10 min; if the
   session restarted, re-arm it (CronCreate, `4,14,24,34,44,54 * * * *`, the same SOP prompt).
2. If `mcp__tasked__*` tools are missing, the board MCP needs reconnecting (`/mcp`); then ToolSearch
   `select:mcp__tasked__task_list,...`.
3. Drain `WORK_QUEUE.md` top-down: pick next unchecked `[ ]`/`[~]` (skip `[⊘]` owner-gated), drive its
   `TSK-###` to `≥review`, batch 2-3 + `bash scripts/test-headless-gate.sh` once, commit per item (rebase+ff),
   check off `[x]` with the SHA, log `docs/AUTONOMOUS_PROGRESS.md` (+ `CHANGELOG.md` if user-facing).
4. `git -C <repo> log --oneline -6`; tree clean except untracked non-ours `archive/Untitled.txt`, `untitled2.md`.
