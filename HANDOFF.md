<!-- CLAUDE-HANDOFF v1 -->
# Handoff — terminal tabs + CM6 editor features + tasked-MCP migration  (2026-06-07 03:15)

**Session:** claude-mdv (autonomous loop + interactive owner requests)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main @ dbcc1c9`

## Mission
SwiftUI macOS app **TextView/MarkdownViewer** (`Sources/`). Ship owner-requested features/bugs + autonomous-loop work; keep `main` headless-gate-green; commit per item; land via rebase+ff. Owner runs the installed `/Applications/TextView.app`.

## Current state
- **Done + installed this session (relaunch picks up):**
  - **Terminal tab-strip position** left(default)/top/right + persisted + Settings→Terminal picker (TSK-488); **terminal scroll persists across tab switch** (TSK-489) — both `dd8570f`, gate-green, `fixed`.
  - **CM6 editor code folding** end-to-end (TSK-466, `24cc94b`+`bef2b82`); **indent guides** opt-in (TSK-487, `f5a3f38`); **Insert Date & Time** Edit-menu cmd (TSK-299, `63b03ce`). All `fixed`.
  - **Preview-tab model core** (TSK-306 Phase 1, `a37f861`) — `progress`.
  - **Self-validation policy** + **tasked-MCP migration** encoded (`5d66180`, `0e8ef68`).
- **In flight:** nothing half-coded. Tree clean at `dbcc1c9`.
- **Next action:** await owner verdict on terminal (they're testing the live build). Likely next: implement the **terminal alternate-screen buffer** (the real `top`/`vim` fix — owner asked "want me to take that next?") OR **preview-tab Phase 2** (sidebar triggers). Both are standing forward threads.

## Key decisions & rationale
- **Use `mcp__tasked__*` tools, NOT `python3 /tmp/board.py`** (owner connected the MCP; shim retired). `task_advance` auto-walks lanes in one call (load schemas via ToolSearch `select:` first — deferred).
- **Agent self-validation requires an automated behaviour test** (owner policy). WebView/AppKit-rendered behaviour has no host coverage → do NOT self-validate; leave at `fixed`. (Why all this session's UI features stopped at `fixed`, not `validated`.)
- **Terminal scroll fix = lift `scrollOffset` to the per-tab `TerminalModel`** (not a mount re-architecture) — minimal, survives the `.id(selectedTabID)` remount.
- **Did NOT blind-fix `top` rendering** — root cause is the missing alternate-screen buffer (separate parser feature), flagged not guessed.
- **Preview-tab persistence = Option A (promote-on-save)** — owner-confirmed; free because `Tab` is not `Codable`.

## Gotchas / lessons (full text in LESSONS.md "Session 2026-06-07")
- CM6 `foldingRanges`/`indentGuides`/insert were plumbed in view+JS but never passed at `ContentView.swift:~570` — grep the call site before assuming a feature is unbuilt.
- `Tab` is NOT `Codable` (persistence via `TabSnapshot`) → in-memory-only fields are non-persisted for free.
- Terminal view-local state is lost on tab switch (`.id(selectedTabID)` remounts the NSView) → store per-tab state on `TerminalModel`.
- Alternate-screen buffer unimplemented (`TerminalScreen.swift:~22`) → `top`/`vim`/`less` mis-render; separate from scroll.

## Files that matter
- `Sources/ViewerUI/Terminal/TerminalView.swift` — `TerminalPaneView.body` switches on `store.tabPosition`; `terminalSurface` + `verticalTabStrip`/`horizontalTabStrip`; representable seeds/persists scrollOffset.
- `Sources/ViewerUI/Terminal/TerminalModel.swift` — per-tab `scrollOffset` (TSK-489).
- `Sources/ViewerUI/Terminal/TerminalNSView.swift` — `initialScrollOffset` + `onScrollOffsetChange`.
- `Sources/ViewerCore/Terminal/TerminalPaneLayout.swift` — `TerminalTabPosition` enum + persist; `TerminalPaneStore.swift` — `tabPosition`/`setTabPosition`.
- `Sources/ViewerUI/DocumentModel.swift` — `refreshEditorFolds()`, `editorIndentGuides`, `insertDateAndTime()`, `editorFoldRangesByTab`; `TabsState.swift` — `openPreview`/`promoteTab`/`previewTabID`.
- `Sources/ViewerUI/CodeMirrorEditorView.swift` + `Resources/codemirror/codemirror.html` — fold/indent/insert bridge (all real).
- `docs/PREVIEW_TAB_DESIGN.md` — TSK-306 plan (Option A confirmed). `CLAUDE.md` (Automated runs SOP) — self-validation policy + MCP usage.

## Open questions / blockers
- **Owner verdict on terminal** (tabs placement + scroll) — testing the installed build.
- **Alternate-screen buffer** — offered; awaiting go (fully fixes `top`).
- VM lane needed to live/visually validate the WebView/AppKit features shipped at `fixed`.

## Tracker (tasked MCP — `mcp__tasked__*`, agent `claude-mdv`, project `tasked`)
- TSK-488 (terminal tab position) **fixed** · TSK-489 (terminal scroll persist) **fixed** — both `dd8570f`
- TSK-466 (CM6 folds) **fixed** · TSK-487 (indent guides) **fixed** · TSK-299 (insert date) **fixed**
- TSK-306 (preview tab) **progress** (Phase 1 `a37f861`; Phase 2/3 remain) · TSK-272 commented (same feature)
- All `fixed` await human `validated`/`done` (agent self-validates only with an automated behaviour test).

## How to resume
1. `cd /Users/me/Documents/workspaces/claude/markdown_viewer` · `git log --oneline -8` (HEAD `dbcc1c9`).
2. Read `docs/AUTONOMOUS_PROGRESS.md` LOG latest+47 → +43 for the narrative.
3. Board via **MCP** (`mcp__tasked__task_list {project:"tasked"}` etc.), NOT `/tmp/board.py`. Schemas are deferred — `ToolSearch select:mcp__tasked__...` first.
4. Gate before landing: `bash scripts/test-headless-gate.sh` (window-free; FoldBench/CrossFileSearchBench flake under load — re-run if those are the only reds). Build+install for owner: `bash scripts/build-app.sh debug --install` (safe; no killall).
5. If owner greenlit: implement **terminal alternate-screen buffer** in `Sources/ViewerCore/Terminal/` (ANSIParser + TerminalScreen, golden tests → self-validatable). Else **preview-tab Phase 2**: sidebar triggers at `SidebarView.swift:257`/`:1174` → `store.openPreview`/`promoteTab` (single-click preview, double-click/Enter pin, edit auto-promotes), italic preview-tab title.
6. UI/live-tier validation is VM-only (owner directive): `ssh macOS15` + `scripts/test-in-vm.sh`. Never run T4/T5 on the host.
