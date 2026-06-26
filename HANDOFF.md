<!-- CLAUDE-HANDOFF v1 -->
# Handoff — autonomous run: AX foundation + validation-drain wave  (2026-06-26)

**Session:** claude-mdv  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `193080bf` (verify `git log -1`).

## Mission
Autonomous cron drain (every 5 min) per BACKLOG **🎯 OWNER PRIORITY ORDER (2026-06-26)**: P0a (eval/AX self-driving + agent-drivable interfaces) and P0b (battle-test the ~215 fixed/review pile to VALIDATED with teeth) — CO-EQUAL, interleaved — then P1 (NEXT WAVE 12). Gaps→tickets: when a gap is found, ensure it has a board ticket.

## Current state — what this run shipped (all on main, headless-gate-green)
- **AX/eval HOST FOUNDATION — COMPLETE (TSK-1254, progress):** `AXDriverCore` (find + resolvePress + `resolve(plan:in:)→ResolvedDriveOp` executor brain), `AXIdentifierCatalog` (validated TSK-1262), `AXUIElementNode` adapter (review), `ElementRef`, `AXDrivePlan` (agent-drive command grammar). All host-tested. Remaining = the out-of-process EXECUTOR + agent-entry (TSK-1261/1263) — **AX-TCC-gated (owner grant), VM-tail, NOT host-validatable.**
- **2 orphaned cores wired into user features:** `InFileCompletion` → completion no-LSP branch (TSK-1127); `ClipboardTableExtractor` → New-Tab-from-Clipboard opens a pasted TSV table in the CSV viewer (TSK-958, user-visible, `55c69382`).
- **VALIDATION-DRAIN WAVE — ~28 review→VALIDATED this session** (each = an automated behavior test that catches regression; removes the item from the owner's close-queue):
  - Image file-I/O + encoders: TSK-1078/1079/1080 (BMP/GIF/TIFF write), 1067 (copy-to-file/paste), 1081 (in-place save / save-as).
  - `[PAINT]` engines: TSK-403 (brush stroke), 404 (color picker + RecentColors), 405 (flood fill), 406 (selection).
  - Text-transform/tool family: TSK-862 (line endings), 863 (whitespace + doc stats), 864 (indentation), 865 (TOC), 866 (HTML export), 867 (check links), 868 (minify JSON), 869 (markdown lint), 870 (CSV→MD/JSON), 871 (inline-image HTML), 882 (heading shift), 883/884 (line ops), 925 (CSV sort), 926 (CLI launch args).
  - Other: TSK-1258 (gate drift-test), 1207 (find-text draft restore), 806 (split-pane source feed — data-correctness bug).
- **~35 features fixed→REVIEW** (model host-verified, render/pixel = owner/VM close): the whole IMG editor (TSK-1048 + ~17 tool tickets, ~166 tests), audio (TSK-529), terminal (456/457/368), placement (495), dep-graph (280), fuzzy (282/666), CSV windowed (668), ClaudeMonitor (111), etc.
- **Owner-wishlist + BACKLOG "no ticket" gaps fully triaged:** 6 stale entries marked done (verified in code), 4 real gaps filed — TSK-1270/1271 (rendered-find bugs, render-tier/VM), TSK-1272 (Cmd+F sidebar routing), TSK-1273 (terminal header). `OwnerWishlist.md` is an untracked TextEdit autosave (Jun-20).
- **DECISIONS NEEDED refreshed** in `docs/AUTONOMOUS_PROGRESS.md` (the owner bottleneck: M5-Pro retest TSK-1257, LSP block-vs-prompt TSK-1129, rust flips TSK-1215/1202, spike ratifications TSK-787/779/788/775, delete-candidates TSK-1268, the review pile).

## Key decisions / method
- **Validatable (review→validated) = pure-logic / file-I/O / encoder / transform / parser / model / data-correctness behavior with a teeth test** (the file/bytes/text/data is the deliverable, host-checkable). **Render / WebView / AX-pixel / on-screen visual = REVIEW** (owner/VM close). The **`[PAINT]` ENGINE tickets are validatable; their TOOL/UI siblings are review** — same split for most features (model validatable, render at review).
- **Cron = inline, one item/tick** (often a small coherent batch of the same pattern). Re-verify the named suite FRESH before validating/advancing.
- Most "open" board items are ALREADY DONE — `grep main` + run the suite before working anything; the bottleneck is owner-side close, not agent work.

## Gotchas / lessons (also LESSONS.md)
- `task_record` can't do reported→fixed; leases expire across ticks → re-walk (`task_advance`/`task_restate`). `task_get` quiet doesn't show understanding/comments.
- `task_validate` classifier was briefly unavailable mid-run (retry succeeds).
- Don't ship a false fix: TSK-1270 (rendered-find highlights) — both the Swift wiring AND `__mdvFindClear` JS are correct host-side → likely stale; needs VM repro (reverted a redundant gate-fix).

## How to resume
1. `git log -1` (expect `193080bf`); read BACKLOG 🎯 block + this file.
2. Continue P0b: scan `task_list state=review`/`fixed` for pure-logic items, re-run their named suite fresh, `task_validate`. Render items → leave at review. Remaining validatable veins: more INTAKE/parity items, rust-core A/B, model state-machines.
3. P0a host work is DONE; the AX executor is owner-AX-TCC-gated (don't burn ticks building unvalidatable glue).
4. Host gate: `bash scripts/test-headless-gate.sh`. VM: `ssh macOS15` + `scripts/test-in-vm.sh` (vm-tester / sudo <vm-sudo-password>). NEVER `killall MarkdownViewer`; UI/live tiers VM-only.
