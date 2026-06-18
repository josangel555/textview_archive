<!-- CLAUDE-HANDOFF v1 -->
# Handoff — loop running UNATTENDED (owner away ~24h); build+VM green; WORK_QUEUE merged; vim shipped  (2026-06-16 ~05:50)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `b293260`

> **OWNER AWAY until ~tomorrow night (2026-06-17 PM).** The 10-min cron `50d0fbc8` drives the loop
> unattended — drain `WORK_QUEUE.md`, commit per item, keep `main` gate-green. Build/test + VM validated
> green this checkpoint. No owner in the loop: `task_park` anything needing a decision/dep-approval and keep
> shipping host-fixable items + papercuts (owner directive: "progress is the goal").

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
- **In flight:** **TSK-906** (palette dismiss loses editor focus) — investigated, NOT yet implemented (no edits).
  Fix = an `editorFocusRequest: Int` nonce on `DocumentModel` (mirror `gotoLineRequest`): `dismissPalette()`
  increments it; `CodeMirrorEditorView` reacts → `webView.window?.makeFirstResponder(webView)` +
  `dispatch(.focus)`. Nonce sites to mirror: `CodeMirrorEditorView.swift:47/122/160/289/322/367/484`.
  Host-test the increment in `DocumentModelTests`; live-focus = VM tail. The loop implements it next.
- **Next action:** loop drains `WORK_QUEUE.md` top-down. ★ Intake **P0 perf needs a VM/Instruments trace** —
  VM is up + validated so a trace IS possible; else the first host-fixable batch: **TSK-906 / 910 / 905**.

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
