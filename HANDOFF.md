<!-- CLAUDE-HANDOFF v1 -->
# Handoff — perf wins shipped; frontier is now VM-bound / owner-gated  (2026-06-14)

**Session:** claude-mdv (autonomous loop)  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch/SHA:** `main` @ recent (see `git log`)

## Mission
Autonomous loop draining `WORK_QUEUE.md` top-down + the board's groomed pools. Ship complete, host-validated work with the measure-don't-guess discipline; build [VM] features' models host-tested and leave render at `review`. Keep `main` headless-gate-green; commit per item.

## Current state (the important part)
- **Recent shipped + VALIDATED wins:** TSK-829 (parallel cross-file search, **4.7×**, `a3ca530`), TSK-842 (read files >4 MiB off-main, `a9103b3`), TSK-844 (CSV parse-into-arena), TSK-830a (highlight `Cow`), TSK-861 (UTF-16 BOM), TSK-855 (gate builds fresh mdv-serve), TSK-727 slices 1-2 (`GotoQueryParser` + palette `:` go-to-line). Earlier: 840/841/843.
- **The clean, host-shippable perf pool is DRAINED** (confirmed this firing). Remaining work:
  - **VM-bound perf:** TSK-838 (rendered-MD WebView reload storm — **implement-ready design on the ticket**: persistent page SHELL + incremental `evaluateJavaScript` innerHTML patch, +scroll-preserve/relative-image-rewrite/JS-toggle-reload; 5 slices. NO host model, CORE path → VM-develop/validate, do NOT build blind). TSK-839 (per-nav CA stall — Time-Profiler/VM first).
  - **VM-render features:** TSK-727 `@`/`#` slices (epic, 1-2 done), 524 image-editor UI, 668 CSV paging, 710/708/463 LSP (WebView bridges; the model/request already exists), 766 git-diff styling, 506 treemap (TreemapLayout exists → render-only).
  - **Triaged-defer (findings on the tickets):** 826 (generic-MsgPackReader refactor, poor ROI), 543 (cm_apply — gated-off `.cmEdit`, port-twin live path, migration prep), 830c (not-worth-it), 827 (port-twin).
  - **Owner-gated:** 847 (bench isolation A/B/C, parked), 343 (local-history default+retention), 358 (font-size × zoom).
  - **~16 `review` items** await VM validation → `done`.

## Next action
Highest-leverage needs an owner steer (re-surfaced in `docs/AUTONOMOUS_PROGRESS.md` top log):
1. **A VM session/pass** — validates the banked `review` items to `done` AND unblocks the VM-bound builds now designed-ready (838, 727 `@`/`#`).
2. Or an owner decision on 847 / 343 / 358 (each unblocks a clean host build).
3. Absent a steer, the cleanest *autonomous* options: spike/design more VM-bound items (838 done), or a careful VM-feature build-to-review (727 `#` in-file search or `@` symbol jump — mostly VM-UI, reuses existing find/outline).

## Key facts / gotchas (also in LESSONS.md)
- **Measure-don't-guess pays:** 847 (18 workers flakes wall-clock benches), 543 (gated-off path), 826 (negligible copy), 842 (warm decode fast → real risk is cold/iCloud reads) were all REFUTED/reframed by measurement before wasted effort. `[needs trace]` perf items genuinely need a profile.
- **TSK-855 fix** makes the headless gate build a fresh `mdv-serve`, so the loopback byte-equal test is a real net for rust-core/serve wire changes.
- Gate = `bash scripts/test-headless-gate.sh` (Swift, host-headless) / `bash scripts/rust-core-gate.sh` (rust-core). Heavy tiers self-skip on host.
- Env-gated benches: `CrossFileSearchParallelTests.testMeasure`, `TextFileLoaderBenchTests` — run with `MDV_RUN_BENCH=1` (not in the gate).

## Tracker
- `tasked` board (`:8787`, project `tasked`, agent `claude-mdv`). 829/842/844/830a/861 = validated; 855/727 = review/progress; 838 designed-ready; 847 parked; 543/826/830c/827 triaged-defer.

## How to resume
1. Read THIS, then `docs/AUTONOMOUS_PROGRESS.md` (top logs = strategic state + owner unblocks), then `WORK_QUEUE.md`.
2. `git -C <repo> log --oneline -8`; confirm tree clean (only `archive/Untitled.txt` + `untitled2.md` untracked — NOT ours).
3. If the owner answered 847/343/358 or did a VM pass → act on it. Else: prefer a careful VM-feature build-to-review (727 `#`/`@`) over re-escalating — the VM-bound-frontier signal is already surfaced.
