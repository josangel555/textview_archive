<!-- CLAUDE-HANDOFF v1 -->
# Handoff — integration pass + agent-tooling + scroll impasse  (2026-06-20 ~18:00)

**Session:** claude-mdv (OWNER-DRIVEN interactive; the 5-min cron is STOPPED — `CronDelete d1fcac5b`).  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `e3bc6913` (verify `git log -1`).

## Mode
Hands-on, owner-driven. Do NOT resume autonomous cron-draining unless the owner re-arms it. Respond to the owner's asks. Spike+design auto-approved; merge work lands rebase+ff (no merge bubbles); commit only when asked; commit trailer ``.

## Current state — what's on main (gate-green, in the user's build)
`/Applications` was last a clean release build of `main` @ `e3bc6913` (then temporarily replaced by a scroll TEST build — see below). On main this session: split-view re-render fix (TSK-921/922), HTML warm-cache (TSK-1190), **save no-clobber + snapshot-on-save (TSK-768)** — the data-loss fix; plus earlier: 22-lang CM6 editor highlighting (TSK-1135), Files-only new sessions, subtler invisibles (`↵`), Focus Mode, ⇧⌘L View-Only, Edit▸Transformations, image-slider + hex-search debounce, session-switch warm cache.

## In flight RIGHT NOW
- **Scroll TEST build → `/Applications`** (bash `b1p24ba0k`, building) — the scroll worktree built to `/Applications` for the OWNER to judge editor scroll on-screen. **NOT merged to main** (main stays clean). If the owner says scroll works → merge `a7063b42`; if not → reinstall main's clean build: `bash scripts/build-app.sh release --install` from the repo root.

## Next actions (in priority order)
1. **When the owner reports on the scroll test build:** works → merge `worktree-agent-a7063b424c5af1b5d` (WIP `3968d987`) to main + rebuild; doesn't work → reinstall clean main + abandon the warm-cache approach (next idea: CM6-side scroll restore via CM6's own state, not WebView-keepalive). Scroll VM truth: rendered-session ✓, rendered-tab ✗, editor UNVERIFIABLE (the UAT can't drive CM6 scroll — owner's eyes are the only signal).
2. **Merge the LocalHistory cluster (owner agreed: inline, by me).** storage `worktree-agent-a917006c` @ `85a212b8` (optimal Myers-linear-space LineDiff + size-guard, gate-green) + viewer `worktree-agent-a3772e69` @ `402b1ba6` (gate-green). RESOLVE AT MERGE: (a) duplicate snapshot-on-save hook — keep ONE (A's `EditorCoordinator.saveEditor`, already on main, vs C's `DocumentModel.saveEditor`); (b) duplicate secret-exclusion — keep ONE (storage's `HistoryContentFilter` vs C's `LocalHistoryPolicy`); (c) merge the two `LocalHistoryStore` reworks. Re-gate, then rebuild.
3. **TSK-854** (owner-approved): kill the Swift tree-sitter twin (−16 MB; 11 `libTreeSitter*Lazy.dylib`). Spawn a refactor agent: drop `TreeSitterEngine` + SwiftTreeSitter dep + grammar targets, collapse `RustHighlightAdapter` to rust-only, update consumers + `Package.swift`. Host-gate.
4. **Owner decisions pending:** TSK-1189 (trust-local-HTML render mode — Weather Console partial render), TSK-1195 (render-verification approach).

## Worktrees (4 live)
- `agent-a917006c` (`85a212b8`) — storage/optimal LineDiff — READY to merge (cluster).
- `agent-a3772e69` (`402b1ba6`) — unified version/diff viewer + LocalHistory — READY to merge (cluster).
- `agent-a7063b424c5af1b5d` (`3968d987`) — scroll (warm cache + harness + tab-select) — owner-test-build source; merge only if owner confirms.
- `agent-a6e472b4` (`e25fc38f`) — OLDER scroll (superseded by a7063b42) — reapable.

## Gotchas / lessons (also in LESSONS.md 2026-06-20 PM)
- **phys_footprint, not VSZ/RSS** — read process memory with `top -o mem`/`footprint`; VSZ (415 GB) is meaningless. (memory `reference_macos_memory_metrics`.)
- **O(n×m) LCS = 77 GB machine-killer**; the fix landed in storage (Myers linear-space + size-guard). Tests have no memory ceiling (TSK-1194).
- **Worktrees isolate files, not semantic overlap** — parallel agents duplicated the snapshot hook (hence the cluster-merge dedup above).
- **Worktree dir = `agent-<id>`, branch = `worktree-agent-<id>`** (mismatch silently no-ops reaps).
- **Sub-agents stall on VM runs + die on transient rate-limits** — drive VM from the main loop; recover a rate-limited agent's uncommitted worktree work via WIP-commit.
- **Editor-scroll UAT can't establish its precondition** (can't scroll CM6 in-test) → owner-verify only.

## Tracker (tasked, agent `claude-mdv`)
This session filed: TSK-1048 (image-paint epic +42 children 1049-1090), TSK-956 reopened + AU children 1091-1097, TSK-1113/936/1116/986/1120/1050 (landed, fixed/review), TSK-1135 (merged), TSK-1038 (dropped wontdo), TSK-1042-47 (scroll/perf), TSK-1189/1190 (HTML), TSK-1192-1196 (agent-tooling MCPs), INT-120/121 (tracker bugs). Board-reconcile-v2 ran (open lanes) — 31 over-claims demoted + children filed. Docs: `docs/AGENT_PRODUCTIVITY_FEEDBACK_2026-06-20.md`, `docs/CURATED_TASKS_2026-06-20.md`.

## How to resume
1. `git -C /Users/me/Documents/workspaces/claude/markdown_viewer log -1` (expect `e3bc6913`).
2. Read `/tmp/scroll-testbuild.log` for the scroll build result; ask the owner if editor scroll holds on screen → follow Next-action #1.
3. Then #2 (LocalHistory cluster merge, resolving the 3 overlaps) → #3 (TSK-854) → owner decisions (#4).
4. Cron stays STOPPED unless the owner re-arms it. New skills live in `.claude/skills/` (diagnose-resources, run-tests, vm-ui-testing, verify-claim).
