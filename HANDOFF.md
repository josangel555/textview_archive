<!-- CLAUDE-HANDOFF v1 -->
# Handoff — autonomous drain run (~66 user-facing features + foundations)  (2026-06-21)

**Session:** claude-mdv (AUTONOMOUS, cron ~5min).  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` @ `9970bed3` (verify `git log -1`).

## Mode — AUTONOMOUS DRAIN (cron ARMED)
Each tick: read `docs/TASK_WORKFLOW.md` + the CLAUDE.md SOP + the latest
`docs/CURATED_TASKS_*.md`, then drain toward done. **Working discipline that
works (keep it):**
- **Converge-fast:** ONE pick → ONE focused probe → build OR reconcile-and-move.
  Do NOT chain probes. Many board/curated items turn out already-done on a fresh
  read (the curated 06-20 list is significantly STALE) — reconcile those (`task_advance`/comment) and move.
- **Build → host-test the model → host-gate → commit per item.** Confirm the gate
  verdict (`==> headless gate PASSED`, 0 failed) in a SEPARATE step before committing.
  Run the gate in the background; the completion notification drives the commit.
- **Render-path = review ceiling.** Build render features too, host-test the model/seam,
  leave the on-screen behavior at `review` (owner/VM closes). Pure-logic + a teeth-test → self-`task_validate` to `validated`.
- Land rebase+ff. Commit trailer ``.
- Keep `CHANGELOG.md` current for USER-FACING changes only (skip foundations/infra).

## Proven patterns this run
- **View-wire:** built-but-unreachable engine → reachable hosted tab via
  `model.showX()` + `openHostedView` + a File-menu item; host-test = "opens a tab
  + returns count / no-op". Shipped: Dependency Graph, Folder Treemap (+from stats card),
  Annotations, Log Patterns, Package Dependencies, Local History.
- **Model-foundation:** extract/build a pure host-tested model; UI/integration deferred.
- **Re-verify-and-pin:** trace a "re-verify" bug end-to-end; if correct, pin the
  untested link with a teeth-test (e.g. Open-in-PWD → `effectiveSpawnDirectory`).

## Shipped this run (all gate-green on main; render at review)
- **Image-editor epic TSK-1048 — DELIVERED** (MS-Paint-class): paint/shapes/full
  selection/Image-menu transforms incl. **skew/canvas-size/invert/clear/resize**,
  **6 save formats + copy/paste-via-file + in-place Save**, **fg/bg + swap + palette + recent-swatches**,
  **airbrush**, decode-once + off-main-save perf. (Rollup on TSK-1048.) Remaining: 1049/1052/1055 (VM/architecture, filed).
- **Exports TSK-1144 (review):** Markdown → `.docx` (dep-free `DocxExporter`: CRC32 +
  store-ZIP + WordprocessingML), `.rtf`, `.rtfd` + **Copy as RTF**; File menu wired; legacy `.doc` = recommend WONT-DO.
- **Terminal:** command-history model (1176, progress), ANSI themes + pure `AnsiColorResolver` (1175, progress, color-preserving), Open-in-PWD re-verified+pinned (1178).
- **CSV:** rectangular select/copy/paste (1187, review) — `CSVRectSelection`/`CSVClipboard` + `EditableCSVModel.paste`.
- **FormulaEngine (1141):** +LEFT/RIGHT/MID, ROUNDUP/DOWN, CEILING/FLOOR, IFERROR (user-facing in CSV `=` cells).
- **Editor:** View ▸ Toggle Read-Only (936). **Local History** reachable (1103, review). Feeds: parser+`FeedFetcher`+OPML (1148✓validated/1150✓validated).
- **Test-infra (TSK-788 audit, host-level done):** coverage script `scripts/coverage.sh` (1131),
  Swift Testing pilot + CLAUDE.md convention (1130), G3 doc truth-fix (1133), G4 teeth-codify `MDVNegativeControl` (1134). **991** prune-cap validated.

## Deferred / blocked (do NOT blind-build)
- **TSK-1132** WebViewTestCase heavy-tier base — turnkey spec on the ticket; touches
  the gate observer the merge gate depends on → focused session + gate-verify, not a heartbeat tick.
- **Big-levers** TSK-1049 (off-main render), 1055 (undoable paint), 1052 (dirty-rect),
  the **TSK-590** perf cluster — VM/owner-gated (design notes on tickets).
- **TSK-1098** bundle-cap doc drift — ambiguous (needs real bundle size or owner intent on the cap).

## Current state of the vein
The clean **host-buildable USER-FACING** pool is essentially EXHAUSTED — probes now
consistently hit already-done / render / VM / owner-gated / rust-FFI-heavy. Remaining
clean autonomous work: validation-drain (move done-but-misparked pure-logic → validated),
reconcile (confirm stale-curated done), test-speed (1181 needs TSK-836 slow-class data;
847 worker-bump in progress). **The single biggest "→ done" lever is an owner / VM-UAT
pass** to close the large `review` backlog (~66 features + this run's view-wires) — that
is the agent's `review` ceiling for render-path and is owner/VM-only.

## How to resume
1. `git -C <cwd> log -1`; `bash scripts/test-headless-gate.sh` should be green.
2. Converge-fast: pick next curated/board item, ONE probe; if already-done → reconcile+move; if a clean host-testable seam → build+test+gate+commit; if render → build+leave at review.
3. Don't blind-build the Deferred items. Don't run T4/T5/WebView/dist on the host.
4. If genuinely no clean build: validation-drain (pure-logic+teeth → `task_validate`) or accurate reconcile. NEVER "no work" — but be honest the user-facing clean vein is thin; surface the owner/VM-UAT lever.
