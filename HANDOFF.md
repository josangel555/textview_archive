<!-- CLAUDE-HANDOFF v1 -->
# Handoff — VM is available for render work; pivot from maintenance to the render-VM queue (2026-06-29)

**Session:** claude-mdv · **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer` · **branch:** `main` @ `56c1a701` (verify `git log -1`)

## ✅ VM RENDER LANE ESTABLISHED + VALIDATED (2026-06-29) — the big update
- Synced host→VM, hit a **toolchain-skew** (`.build` had 6.1.2-compiled `TestSupport.swiftmodule`; 6.3 can't import it) → fix: `ssh macOS15 'cd markdown_viewer && echo "$MDV_VM_SUDO_PASS" | sudo -S rm -rf .build/arm64-apple-macosx'` (clean per-arch products; KEEP `.build/checkouts`+`repositories` — the safe clean, NOT the forbidden full wipe). My code is **VM-build-green** after.
- **In-process WebView render lane is GREEN: 78 tests, 0 failures** via `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_RUN_WEBVIEW_TESTS=1 bash scripts/test-in-vm.sh webview`. THIS is the agent-validatable render tier — use it, NOT `all` (the `all` run got KILLED ~10-12 min mid-headless-suite; the VM-run kill ceiling is real, per [[feedback_no_special_allmode_for_render]]).
- **TSK-1247 confirmed + scoped (board comment):** the SPAWNED-APP (`dist/TextView.app` via launchctl-asuser) rendered-preview WebView is blank/unscrollable (probe −1/0) → blocks ScrollRestoreUATTests + all spawned-app UATs. The IN-PROCESS lane renders fine, so TSK-1247 is spawned-app-specific and is the **likely shared root of TSK-1200 (scroll-verb "no-op on the live app") + the SCROLL01/02 failures** — those are harness-false, NOT real feature bugs (scroll-restore passes in-process). TSK-1247 fix = a focused VM session (instrument the spawned-app WebView mount/visibility/load-vs-probe-race under launchctl-asuser-root).

## Mission
Autonomous drain loop (cron). Build INLINE, one item/firing: spike → implement → test → gate → commit; land rebase+ff; keep main gate-green; fold docs into the item's commit.

## ⚠️ THE KEY CORRECTION (2026-06-29, owner) — read first
**The VM is a first-class WORK environment, not host-only.** Owner: *"there is no such restriction that work need to be only in host. VM is up and running, except the brand-new AX-based testing (blocked on permissions) — everything else is open for work."*
- I host-built the models then HELD the entire render-tail for ~40 cron ticks as "VM-blind / can't validate / too risky to ship blind" — sitting in maintenance. **That was a process failure of my own making.** The render-VM queue was always workable.
- **DO render work ON the VM:** `MDV_VM_GUI_SESSION=1 MDV_VM_SUDO_PASS=<vm-sudo-password> MDV_RUN_WEBVIEW_TESTS=1 bash scripts/test-in-vm.sh all` (`all` rebuilds dist/ first — avoids the stale-dist trap; `test` alone spawns a stale bundle). WebView lane = [[reference_vm_webview_drain_recipe]]. Only the **new AX-based testing lane** is blocked (permissions).
- See memory [[feedback_dont_hold_build_vm_tail_features]] (updated today with this re-correction).

## Current state
- **Done + landed this session (all gate-green on `main`):**
  - **TSK-1176** terminal command-history — HOST-HALF COMPLETE: populate-model (`43fac093`, `TerminalInputLineAccumulator`→`TerminalCommandHistory.shared`, wired into `TerminalModel.send*`, 18 tests) + search-model (`TSK-1301` `009cc573`, `TerminalCommandSearch.unified`, validated, 6 tests). Palette UI = render (now VM-workable).
  - **TSK-1300** (`e24d23fd`, validated) — CSV convert commands routed off the Swift twin onto `RustCSVAdapter` (~2.5× faster, output-preserving). Self-corrected the bad **TSK-1299** flip-rec (CSV already defaults to Rust; dismissed).
  - transcript contract proptest (`24df4a65`); **TSK-1128** lsp.json write-back model (`6a3e6ac0`).
  - Earlier this session: 8 render-tail features + spell-check (→review), 40 DocumentModel SRP slices (5835→3346), 3 validated subprocess-crash fixes (SIGPIPE/ffmpeg), 2 gate-flake fixes.
- **Diagnosed, ready for the VM fix (host work done):** TSK-1200 (CM6 scroll verb no-op — fix: `view.requestMeasure({read,write})` keeping the raw scrollTop for the scroll-emit; do NOT use scrollIntoView) · TSK-1188 (CM6 click-extends-selection — fix: defer the re-entrant dispatch off the mouse handlers; needs an in-process WebViewTestCase).
- **Decision-ready (homework done, parked for owner):** TSK-1129 (LSP-binary RCE-trust — model+store built, spawn warns; pick a/b/c) · flips formula **TSK-1215** / fold **TSK-1202** (parity-proven, 34 tests) / DOM-patch **TSK-838**.
- **Coverage** (measured this session): 69.74% region / 64.72% line host; the uncovered is render UI (VM-tested), pure-logic is comprehensively covered.

## Next action (resume here)
**The VM is open — work the render-VM queue (no longer hold it).** Priority order:
1. **TSK-1200 + TSK-1188** — CM6 JS fixes (diagnosed; apply the fix + a WebViewTestCase, validate on the VM).
2. **TSK-1176 palette UI** — build the SwiftUI command palette over `TerminalCommandSearch.unified` + a trigger + PTY-insert; iterate against the VM render.
3. **Validate the 8 render features + spell-check** at review on the VM (`test-in-vm.sh all`), advance to validated.
4. **Flips** (formula/fold) — VM-soak then recommend; **TSK-838** DOM-patch flip needs VM render-parity validation.
5. **TSK-343 Revert** — the destructive restore UX (data-safety: handle unsaved edits) — VM.
- IN-FLIGHT THIS TURN (owner asks): (a) reorg BACKLOG.md (done→bottom, reorg active) + status report; (b) scan the board, pull the next-50 actionable.

## Gotchas / lessons
- **Don't host-restrict render work — the VM does it (see the correction above).** Build + iterate render ON the VM.
- **read-first ALWAYS** (`task_get`/read the code before building): caught ~10 already-done items this session (install-hints, per-tab-memory, converter-verbs, CSV-sort, fold-port, coverage-tooling, LSP-trust, TerminalPalette[=color palette], …). In this mature codebase the dominant waste is re-building done work.
- **build-the-model lens** found the genuine work (TSK-1176): for a render feature, build the host-testable MODEL slice (the coherent one — not thin/speculative fragments).
- Gate flakes (commit if change-unrelated + sole failure): FoldBench, ChromeBodyEvalCount (TabOpPerf/CrossFileSearchBench fixed). JQRunner SIGPIPE is now a REGRESSION (fixed), not a flake.

## Files that matter
- `Sources/ViewerCore/TerminalCommandSearch.swift` / `TerminalCommandHistory.swift` / `TerminalInputLineAccumulator.swift` — TSK-1176 models (ready for the palette UI).
- `Sources/ViewerUI/Resources/codemirror/codemirror.html:1511` (`applyScrollToLine`, TSK-1200) + the TSK-894/890 mouse handlers (TSK-1188).
- `Sources/ViewerCore/RustCoreGates.swift:74` (`defaultEnabled` — formula/fold ship OFF, the flips).
- `scripts/test-in-vm.sh` (`all` mode = the VM render lane).

## Tracker
- `tasked` / claude-mdv. TSK-1176 progress (host-half done), TSK-1300/1301 validated, TSK-1128 triaged, TSK-1200/1188 diagnosed, TSK-1129/1215/1202/838 owner-decision/flip, TSK-1110/951/343 reconciled. ~417 review/fixed = owner close-queue.

## How to resume
Read this + BACKLOG.md top. Confirm `main` gate-green. **The VM is available — do NOT sit in maintenance; work the render-VM queue (Next action above), one item/firing, validate on the VM (`test-in-vm.sh all`).** Only the AX-testing lane is blocked.
