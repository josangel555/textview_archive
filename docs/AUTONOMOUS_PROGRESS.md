# Autonomous run — progress tracker (2026-06-04)

> **STANDING DIRECTIVE (owner, 2026-06-04):** "Tackle as much as you can, do it
> methodically and progressively, but **don't stop**. If you need my input,
> document it [in DECISIONS NEEDED below] and share later — don't block. No time
> rush. Break down, investigate, research, build PoCs. **Validation is key** —
> find ways to validate automatically without me staring. Screen is yours until
> tomorrow (launch the UI as needed). Build PoCs: image editing; an Agent-
> monitoring view over `~/.claude` (list sessions, search transcripts, detailed
> per-session view); research Claude Code hooks for richer info. Prioritization
> not important — if blocked, document and move on; if nothing to do, research
> best practices. Work in waves/chunks, don't stop."
>
> Hourly cron `1c077a77` (:37) revives this if the session stalls. If you are a
> fresh/compacted session: read this file top-to-bottom, then continue from the
> first unchecked item. Keep `main` headless-gate-green; commit per item.

## Validation methods available (no owner staring required)
- **Headless gate** (window-free): `bash scripts/test-headless-gate.sh` → exit 0 + "tier enforcement OK". The merge gate.
- **`--diagnose`**: `MDV_BACKGROUND=1 .build/debug/MarkdownViewer --diagnose [-MarkdownViewer.<key> <val>] <file>` → JSON view tree (frames + classes). Confirms which view mounts / layout geometry. Window-free-ish (brief offscreen).
- **Live footprint**: launch debug binary bg → `footprint <pid>` (phys_footprint), `vmmap -summary <pid>`, `pgrep`-by-ppid for child procs. Screen is ours.
- **Self-read screenshots**: `screencapture -x -o /tmp/x.png` then Read the PNG. (System-wide capture — note the owner's other windows; don't comment on them.)
- **Perf timing**: instrument with signposts / wall-clock logs to stderr, parse from the log.

## Waves
### Wave 0 — infra + land pending fixes  [IN PROGRESS]
- [x] Hourly safety-net cron (`1c077a77`).
- [x] This progress doc.
- [ ] Reinstall the fixed build to /Applications (terminal `6153c9b` + crash `49647fb` + L1 `1625563`) so the owner tests current code. Needs one live smoke (authorized).

### Wave 1 — perf cluster (tab close/switch/open slow)  [NOT STARTED]
Hypothesis: same root as the 108 MB baseline — DocumentModel god-object republishes the whole content tree + touches every always-on subsystem per tab op (#210/#215 lineage). Plan: live-profile a tab switch/close with wall-clock signposts → find the synchronous hot path → fix → validate with a headless timing test + live footprint/timing.
- [ ] Instrument tab switch + close + open with timing.
- [ ] Identify + fix the synchronous hot path(s).
- [ ] Regression guard (headless timing assertion where possible).

### Wave 2 — quick wins (low risk, visible)
- [ ] File ▸ New + right-click folder ▸ New [File].
- [ ] Bookmark remove via Delete key + undo.
- [ ] Default to plain text for renderable-ASCII + plain-text allowlist.
- [ ] Can't-see-right-border-of-last-tab.
- [ ] PNG/media file-info respect zoom.

### Wave 3 — PoCs (research + build, validate automatically)
- [ ] **Image editing PoC** — P0 resize/crop/quality + history/revert. Validate via headless image-pipeline tests (load→op→assert pixels/dims) before any UI.
- [ ] **Agent-monitoring view PoC** — read `~/.claude` (sessions, transcripts), list + search + detailed per-session view. Validate via headless parser tests over fixture transcripts.
- [ ] **Claude Code hooks research** — how to add hooks to gain richer info; write findings doc.

### Wave 4+ — bigger rocks (from BACKLOG 2026-06-04 dump)
HEX 1 MB slow (#218), tab overflow/shrink (#183/#209), `+`-beside-last-tab (B2), up/down nav (#220), natural keybindings (#232), multi-window, sessions-optional, god-object split (#202), FPS meter (#208), drag tabs→sessions, footer drop-ups, repo-stats treemap, undo audit.

## DECISIONS NEEDED (owner — non-blocking; I proceed on best-judgment defaults meanwhile)
- **WebView/memory lever** — parked on the board as TSK-113 (default: trim compositing layers + measure).
- **Perf Fix#1 (per-tab content-view retention)** — this is the dominant ~1s fix BUT it's a
  load-bearing refactor: `loadedView` renders only the ACTIVE tab via `model.currentViewMode`/
  `currentState`; retaining N tabs needs per-tab view-state plumbing (#202 territory). I will build
  the mount-count + republish-count headless guards and attempt it behind them; **if headless
  validation can't confidently prove visual correctness, I'll PARK it for your review** with the
  design + measurements rather than ship a risky half-validated refactor to the central view.
  Meanwhile I land the safe wins (PoCs, Wave-2 quick-wins, Fix#3 double-republish, Fix#4 off-main stat).

## LOG (per item: commit + what shipped + how validated)
- 2026-06-04 `6153c9b` terminal runtime-toggle fix (body greedy + clip + focus) — --diagnose verified, gate-green.
- 2026-06-04 `1625563` L1 LSP-diagnostics reclaim on close + MemoryReclaimOnCloseTests — gate-green.
- 2026-06-04 `49647fb` GitLogTab OOB crash fix + roadmap capture — gate-green.

## Project tracking — `tasked` board (http://localhost:8787, owner's app)
Integrated (owner asked to dogfood it). MCP server registered at user scope
(`claude mcp add --transport http tasked http://localhost:8787/mcp`) → native
`mcp__tasked__task_*` tools in fresh/cron sessions. THIS session uses curl helper
`/tmp/tk.sh <tool> '<json>'`. Tools: task_create/claim/restate/record/park/
comment/triage/next/list/get. Use `task_park(id,agent,kind,question,options)` to
surface owner decisions (sets waiting:"human"). Active tasks: TSK-108 perf
(claimed), TSK-109 quick-wins, TSK-110 image-PoC, TSK-111 agent-monitor-PoC,
TSK-112 hooks-research, **TSK-113 parked decision (WebView/memory lever)**.
Dogfood feedback: (1) helper needed `--data-binary @-` not `-d` to avoid a brace
parse error; (2) no `task_delete` tool (stray test TSK-107 can't be removed);
(3) mid-session `claude mcp add` doesn't hot-load tools — needs reconnect.

## Wave-1 research workflow
`wf_44d60a03-41e` (background): perf hot-path · ~/.claude schema · CC hooks ·
image-edit approach · blank-slate explorer → synthesis. Persist results to
docs/research/autorun-2026-06-04/ when it returns; act on the synthesis.

## Locked plan (from research synthesis wf_44d60a03 → docs/research/autorun-2026-06-04/PLAN.md)
**Perf (TSK-108), ranked:** Fix#1 per-tab content-view RETENTION (bounded LRU ~4,
keep inactive panes mounted via ZStack opacity keyed by tab.id) — kills the ~1s
close + A→B→A WebView reload, THE dominant fix. Fix#2 narrow ContentView
observation off DocumentModel (observe tabCoordinator directly; the documented
pattern at ContentView.swift:7-33) — AFTER #1 (dead-toggle regression history).
Fix#3 collapse double-republish on lazy materialize (DocumentModel.swift:3699).
Fix#4 move refreshDiskStateForActiveTab stats off-main (only matters on network
vols). DO NOT touch git-diff/repoFocus/LSP (already async — confirmed).
**Validation:** existing `InteractionProfileHarness` (MDV_PROFILE-gated, hosts real
ContentView offscreen, has tab.switch/openClose interactions) for timing; ADD a
makeNSView/dismantleNSView mount-count probe (headless-gate: A→B→A ⇒ 0 remounts)
+ a DocumentModel.objectWillChange republish-count test (selectTab on warm
same-mode tab ⇒ 0 god-object republishes).
**Image PoC (TSK-110):** engine spine in ViewerCore (ImageDocument+EditOp ops-list,
Renderer crop-before-resize+orient, Exporter ImageIO); quality is export-only.
**Agent-monitor PoC (TSK-111):** extend existing ClaudeLogParser.swift; ClaudeSessionIndex
streams ~/.claude/projects/*/*.jsonl top-level, key=filename-stem, redaction gate.
**Hooks (TSK-112):** passive JSONL logger feeding the monitor; FLAG FOR OWNER: your
~/.claude/settings.json has NO hooks key — backup-on-write.sh / block-edit-fullfile-
rewrite.sh are on disk but DORMANT/unregistered (you may think they're active).

## STATUS
Wave 1 plan LOCKED + research persisted (d0c87da). Two PoC-build agents dispatched
(image engine + ~/.claude index; write-only, disjoint files; I build+gate centrally
to avoid concurrent-build races). NEXT (on agent completion): build+gate their PoCs,
then measure tab-switch view cost via InteractionProfileHarness, then implement perf
Fix#1 (view retention) behind the mount-count guard. CANNOT run `swift test` until
the writing agents finish (compile race). main @ d0c87da gate-green + reinstalled.
