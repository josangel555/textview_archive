<!-- CLAUDE-HANDOFF v1 -->
# Handoff — autonomous run: AX/eval foundation + orphaned-cores drain  (2026-06-26)

**Session:** claude-mdv  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `b8df8b84` (verify `git log -1`).

## Mission
Autonomous cron drain (every 5 min, session-only `beafb39c`) per the BACKLOG **🎯 OWNER PRIORITY ORDER (2026-06-26)**: P0a (eval/AX self-driving + agent-drivable interfaces) and P0b (battle-test the fixed/review pile + reclaim) — CO-EQUAL, interleaved — then P1 (NEXT WAVE 12). Owner directive (2026-06-26): **when you find a gap, ensure it has a board ticket; if not, file one.**

## Current state — what this run shipped (all on main, headless-gate-green per item)
- **Prod-build packaging fix (TSK-1257, review):** `Bundle.resolveResourceBundle` + `--verify-resources` gate; fixed dist vended to `mvd_dist` + installed. (Owner: M5-Pro retest = the close.)
- **Gate repair (TSK-1258) + vim steady caret (TSK-1259, VM-validated) + folder-treemap drain (TSK-506) + rust-highlight drain (TSK-660)** — all review.
- **AX/eval host foundation (TSK-1254 epic, progress) — the headline P0a, host-complete:**
  - `AXDriverCore` (ViewerCore/Automation) — find-by-`mdv.*`-id + press-action resolution over an abstract `AXNode` (slice 1, `0bec4882`, validated via TSK-1262).
  - `AXIdentifierCatalog` (TSK-1262, **validated**) — curated agent-drivable addressing contract + source drift guard (`cb0110f1`).
  - `AXUIElementNode` (TSK-1260, review) — the real macOS AXUIElement adapter (`711c8b65`); live traversal AX-TCC-gated.
  - `ElementRef` (TSK-1256 slice 1, progress) — shareable `mdv://` reference model bridging native AX / WebView / file / tab (`beef2213`).
  - **Pyramid doc** `docs/TEST_PYRAMID.md` (TSK-1255, review, `df13e11e`) — the canonical tier map.
  - VM-tail subtasks filed: TSK-1260/1261/1263 (AX driver), TSK-1264-1267 (ElementRef resolver/UI/picker/CDP).
- **LSP security (TSK-1129, parked):** `LSPTrustStore` + spawn-site warn-wire (`12c88b7f`) — the RCE-guard vector is now visible; the BLOCK + confirm-prompt is **parked** for the owner (block-vs-prompt UX).
- **Orphaned-cores audit (TSK-1268, triaged):** ~30 ViewerCore cores are built+tested but have ZERO consumers (feature inactive). Triaged: delete-candidates / wire-now / wire-when-UI. **Wired this run:** `InFileCompletion` → `handleCompletionRequest` no-LSP branch (TSK-1127, review, `b8df8b84`; popup display = TSK-463 render slice). **Tracked:** `ExternalEditReconciler` auto-merge (TSK-1269).
- **VM cross-validation:** the 6-commit batch (incl. the AX C-API) compiles + passes on Swift 6.3.

## Key decisions
- **Cron = inline, one item/tick, host-test the model + leave render/VM at review.** Each item: spike → implement → test → teeth → `test-headless-gate.sh` → commit → board.
- **Orphan-wiring is P0b-class** (activating built features). Clean wires fill an existing empty branch (InFileCompletion); deep ones (auto-merge apply) get a scoped ticket, not a rushed tick.
- **AX driver is out-of-process** (in-process AX tree is empty); live traversal needs AX TCC (owner-grant, like the T5 pixel lane).

## Gotchas / lessons (also LESSONS.md)
- **Gate cadence:** each `test-headless-gate.sh` recompiles into `.build-gate` (~few min) — run it in the background, confirm `WRAPPER_EXIT=0` + `headless gate PASSED` before the next item.
- **#NNN / stale-lease:** several picked tickets were at `reported`/`progress` with expired leases — walk them forward (`task_advance`/`task_record`), `task_get` before acting.
- **task_record can't do reported→fixed** — walk via `task_advance` to progress first.
- **Verify-before-build:** orphan/“open” items need `grep main` + `task_get`; most fixed/review items are render → owner-close.

## How to resume
1. `git log -1` (expect `b8df8b84`); read BACKLOG 🎯 block + this file. The cron `beafb39c` drains every 5 min.
2. Next code drain: a clean orphan-wire from TSK-1268's **wire-now** set (prefer ones that fill an existing empty branch, like InFileCompletion did) OR a validation-drain (re-run a fixed item's named suite fresh → review). Interleave P0a/P0b.
3. Owner-pending: M5-Pro retest (TSK-1257), block-vs-prompt decision (TSK-1129), the parked rust flips (TSK-1215/1202), wave-12 groom.
4. Host gate: `bash scripts/test-headless-gate.sh`. VM: `ssh macOS15` + `scripts/test-in-vm.sh` (creds: vm-tester / sudo <vm-sudo-password>). NEVER `killall MarkdownViewer`; UI/live tiers VM-only.
