<!-- CLAUDE-HANDOFF v1 -->
# Handoff — Section-A velocity run + perf lane drained + tasked-MCP flux  (2026-06-14)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ `f76eb47`

## Mission
Autonomous 10-min loop (cron `846245af`) draining `WORK_QUEUE.md` TOP-DOWN. Owner wants VELOCITY: **batch 2-3 independent items per firing, gate ONCE, commit per-item.** USER-FACING first; [VM] menu/UI items → build + host-test the model, leave appearance at `review`.

## Current state
- **Done + validated this session (perf lane, all on `main`):** TSK-846 (index-store gate scratch dir, `703a9bb`), TSK-848 (rust-`.a` relink-skip, `5e6c11a`), TSK-840 (parallel grammar-warm, `64d4c3d`), TSK-843 (gate `getenv` fast-path, `9c4eb01`), TSK-841 (positional highlight wire, `e99ca14`), TSK-720 (⇧⌘P palette, `b4c4c20`).
- **Done → `review` (Section A, VM/owner glance pending):** TSK-755 (Session→Tab Operations, `25b732a`), TSK-756 (palette toolbar button, `e31bc99`), TSK-753 (View→Language Mode, `192211b`), TSK-762 (bottom-bar toggle buttons, `a1dadb5`), TSK-355 (Open in Default App, sidebar+tab menus, `c84e8bf`).
- **Also:** bundle analysis + caps bumped 72→80 / 52→60 (`759835c`); Agent B build/test-speed doc (`37d5374`); WORK_QUEUE-first SOP governance (`800e951`); filed TSK-846..852 (build) + 853 (fixed) + 854/855 (reported); spiked TSK-844/845 (triaged); 2 `/Applications` builds (debug then **release**, 71/51 MB).
- **In flight:** NOTHING half-coded. Working tree CLEAN (except pre-existing untracked `archive/Untitled.txt`, `untitled*.md` — NOT mine, leave them). `main` headless-gate-green.
- **Next action:** cron fires → take the next UNCHECKED Section-A items, BATCH them, gate once. Concrete candidates: **TSK-747** (new-tab other types), **TSK-718** (hot exit), **TSK-726** (project-wide replace). **TSK-707 (double-Shift palette) DEFERRED** — a naive shift-tap monitor false-fires on capital-letter typing; needs an "intervening-key resets the gate" guard + a host-tested DoubleTapGate(window:) struct (design in the git log). SKIP the ambiguous ones (751/709/746).

## Key decisions & rationale
- **WORK_QUEUE.md is the priority SELECTOR** (drain top-down); the tasked board stays the lifecycle SYSTEM OF RECORD. Encoded in TASK_WORKFLOW.md §3 rule-0, CLAUDE.md SOP, and the cron message (owner directive 2026-06-14).
- **Batch + gate once** (the gate is the ~2-3 min bottleneck) — owner velocity ask. Memory `feedback_batch_items_gate_once`.
- **⌘P stays Print** (Mac HIG) — only ⇧⌘P bound for VS Code parity (TSK-720). CommandDescriptor = 1 shortcut/command.
- **TSK-844/845 DEFERRED** (not stalling): 844 rewires a security-hardened CSV parser + must re-derive the TSK-557 heap cap (landmine); 845 is a likely no-op (utf8.count O(1) on native Strings). Both spiked on the board.

## Gotchas / lessons (also in LESSONS.md 2026-06-14)
- **Build-thrash:** gate `--disable-index-store` vs interactive index-on = 63s rebuild/switch → fixed with `.build-gate` scratch (846). `build-rust-core.sh` relinked the world every run via `restage_core_header`'s always-touch → gated on `cmp` (848).
- **Stale `mdv-serve`:** the loopback test spawns `/private/tmp/mdv-rust-target/debug/mdv-serve` which NOTHING in the gate rebuilds → a wire change false-fails. `cargo build -p mdvcore-serve` before trusting it. `runs_wire` is shared by FFI + mdv-serve (TSK-855).
- **NEVER bundle `git commit` with the gate-verdict grep** in one Bash call — I committed TSK-841 prematurely; main briefly red on the stale-serve false fail. Confirm green in a SEPARATE step, then commit.
- **[VM] menu/UI = `review`:** the executable's menus aren't a test-target dep; a toggleStyle/button render needs the VM. Host-test the wired MODEL action; `#selector` refs are compile-guarded.

## Open questions / blockers
- **AMBIGUOUS Section-A — need an owner UX decision, don't guess:** TSK-751 (which menu reorg?), TSK-709 (unify ⌘K/⌘G — ⌘G is the standard Find-Next chord), TSK-746 (recents in the Open dialog — NSOpenPanel can't host custom recents; Open Recent menu already exists). TSK-355 mostly DONE (Reveal-in-Finder exists `SidebarView.swift:1088`; only "Open in external app" may be missing).
- **Owner-gated:** TSK-854 (delete Swift highlight twin = the bundle-cap reclaim; fold path has no Rust equiv yet), TSK-851/852 (ccache / CI cache).

## Tracker
- `tasked` board (`http://localhost:8787/mcp`) — **reconciled PER-ITEM this session** (each ticket advanced as it shipped). The board's MCP tools were briefly DOWN then up-but-not-re-registered in this session; the server is back. Residual: review-lane TSK-755/756/753/762 await the owner's VM/render glance → `done`. Validated: 846/848/840/843/841/720. Filed/spiked: 844/845/853/854/855/851/852.

## How to resume
1. Read THIS file, then `docs/TASK_WORKFLOW.md` (the SOP), then `WORK_QUEUE.md` (Section A — next unchecked).
2. `git -C /Users/me/Documents/workspaces/claude/markdown_viewer log --oneline -3` (HEAD ≥ `f099daa`); confirm tree clean.
3. **BATCH** 2-3 independent Section-A items (e.g. 747 + 718, or 726), implement, run `bash scripts/test-headless-gate.sh` ONCE, confirm `==> headless gate PASSED` (gate flake = FoldBench/GrandchildPipe, re-run isolated), THEN commit each separately, check off `[x]` in WORK_QUEUE.md with the SHA, advance each ticket on the board, log `docs/AUTONOMOUS_PROGRESS.md`, CHANGELOG for user-facing.
4. The cron (`846245af`, 10-min) drives this automatically; each firing is no-op if work is already in flight.
