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
- _(none yet — append here as they arise, with the default I chose so work continues)_

## LOG (per item: commit + what shipped + how validated)
- 2026-06-04 `6153c9b` terminal runtime-toggle fix (body greedy + clip + focus) — --diagnose verified, gate-green.
- 2026-06-04 `1625563` L1 LSP-diagnostics reclaim on close + MemoryReclaimOnCloseTests — gate-green.
- 2026-06-04 `49647fb` GitLogTab OOB crash fix + roadmap capture — gate-green.

## STATUS
Wave 0 in progress. NEXT: reinstall fixed build, then Wave 1 perf profiling. main @ 49647fb, gate-green.
