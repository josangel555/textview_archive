<!-- CLAUDE-HANDOFF v1 -->
# Handoff — autonomous run: full MS-Paint-class image editor shipped (~46 features)  (2026-06-21)

**Session:** claude-mdv (AUTONOMOUS).  ·  **cwd:** `/Users/me/Documents/workspaces/claude/markdown_viewer`  ·  **branch:** `main` (verify `git log -1`).

## Mode — AUTONOMOUS DRAIN (cron ARMED, every ~5 min)
Each tick: read `docs/TASK_WORKFLOW.md` + the CLAUDE.md SOP + the latest
`docs/CURATED_TASKS_*.md`, then drain. Working discipline (keep it):
**front-load ONE focused grep/read (what already exists) → build → host-test the
model → host-gate → commit per item; render/pixels left at review.** Confirm the
gate verdict in a SEPARATE step before committing (never in the gate's shell
compound). Land rebase+ff. Commit trailer
``.
Batch where ONE mechanism covers several tickets (e.g. the 3 write-formats).

## Shipped this run (~46 user-facing features, all gate-green on main)
EARLY cluster: reachable views (Dependency Graph 1100, Folder Treemap 506), Settings
toggles (Sessions 1105, Extensions 1112), find-bar 1207, tooltip 1209, New Image
1054, CSV cursor 1102, awaitUser UI 1115, Walkthroughs browser 1107/1211, gated
notebook viewer 717, sidebar cache eviction (591 cand.3), rust eviction registry (589
sl.1+2). Reconciled-as-already-done: 986/991/1113/1143.
**IMAGE-EDITOR EPIC (the bulk — an MS-Paint-class editor):**
- Paint: tap/drag gesture (1101), brush/pencil/eraser incl. round+square (1056/1057/1062), eyedropper + flood-fill.
- Shapes: rectangle/rounded-rect/ellipse/line/arrow + fill toggle (1058/1059/1060/1061), direction-preserving lines.
- Selection (FULL): marquee 1063 + lasso 1064 (polygon, mask-aware ops) + crop 1068 + move 1065 + delete/select-all/copy/cut/paste/invert 1066.
- Image menu: flip/rotate 1072, invert-colors 1075, clear 1077, resize dialog 1073.
- Formats: BMP/GIF/TIFF write 1078/1079/1080 (now png/jpeg/heic/bmp/gif/tiff).
- Perf: decode-once cache 1051, off-main non-blocking save 1053.

Key foundations to reuse: `RasterCanvas` (setPixel/fillRect/brushDab/brushStroke/
floodFill/blit/over/fill(_:in:)/from(cgImage)), `RasterSelection` (rect/polygon/
everythingExcept + contains + bounds), `SelectionGeometry`, `ShapeDragGeometry`,
`ImageResizeMath`, `EditOp` (+ Renderer.apply, commitGeometry, isGeometry/
isCommittable), `vm.selection`/`selectionImage`. Tests: `ImageEditorPaintTests`
(50, @MainActor, host pixel-sample via solidPNG+sample), `RasterCanvasTests`,
`RasterSelectionTests`, `SelectionGeometryTests`, `ImageResizeMathTests`.

## Filed / deferred (NOT clean host ticks — do NOT blind-build)
- **TSK-1049** off-main RENDER pipeline — breaks the synchronous `rendered` contract
  (~many tests) + crosses non-Sendable CGImage + timing cancellation → VM-warranted
  (full design on the ticket).
- **TSK-1055** undoable paint — paint is a separate destructive buffer; unify as a
  `.paintStroke` op or snapshot-undo (design on the ticket). Architecture slice.
- **TSK-1052** dirty-rect paint compositing — render-path perf.
- The owner-gated perf cluster **TSK-590** (591 hover-lag/592 jank/598 MD-open/601
  Swift-open) needs the owner's live re-feel / counter read.

## Remaining ACTIONABLE clean work (image-editor parity tail; non-image pool is drained/owner-gated)
Next curated/board image items, all clean: skew (1074, new affine EditOp+dialog),
canvas-attributes (1076, canvas pad/crop dialog), palette strip (1070), two-color
fg/bg model (1069 — also lets Clear use a real bg color), Edit-Colors dialog (1071),
in-place Save/Save-As (1081), airbrush (1082), paste-from-file/copy-to-file (1067).
The non-image clean pool has repeatedly turned up drained or already-done-on-reconcile
(986/991/1113), so the image-editor parity tail is the actionable vein.

## How to resume
1. `git -C <cwd> log -1`; confirm cron armed (`CronList`).
2. Pick the next clean image-parity item (skew 1074 or canvas-attributes 1076 next),
   front-load the existing op/helper, build, host-test the model, gate, commit.
3. The big-lever items (1049/1055/1052 + the 590 perf cluster) want a VM-validated /
   owner session — don't blind-build them.
4. ~20-item-plus review backlog (this run's render-path features at fixed/review)
   reaches validated/done via the owner on-screen OR a VM GUI/UAT pass
   (`scripts/test-in-vm.sh all` + run-uat) — the biggest "every task → done" lever.
