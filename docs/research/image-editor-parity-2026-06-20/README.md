# Image Editor → MS Paint parity — audit, research, and plan (2026-06-20)

Audit of the app's current Image Editing + Image Creation capabilities, a parity
study against **MS Paint (Windows XP)** and **MS Paint (Windows 7)**, a gap
matrix, and a phased implementation plan. Filed as a tracked epic on the `tasked`
board.

This was AUDIT + RESEARCH + PLANNING + TRACKER-FILING only — no app code was
changed, the app was not run, and no UI/VM tests were executed.

## Index

| File | Contents |
|---|---|
| [`01-audit-current-state.md`](./01-audit-current-state.md) | **Part 1** — what exists today, with file:line evidence: architecture, tool/op inventory (wired vs model-only vs stub), the "sync ops / clunky" offenders, the absent image-creation flow, test coverage. |
| [`02-parity-research-mspaint.md`](./02-parity-research-mspaint.md) | **Part 2** — the parity bar: full MS Paint XP vs Win7 feature inventory (toolbox, color, canvas, transforms, creation, clipboard, formats, undo, zoom, the Win7 delta). |
| [`02b-parity-research-unprimed.md`](./02b-parity-research-unprimed.md) | **Part 2b** — an independent **unprimed** second research pass (verbatim), cross-confirming the figures and adding precision (16 tools / 28 colors / 12 brush styles / 400×300 default / 3→10→50 undo / GDI+ inflection in XP / Draw-Opaque↔Transparent-selection). |
| [`03-gap-matrix-and-plan.md`](./03-gap-matrix-and-plan.md) | **Part 3** — feature → present? → XP/Win7 → effort gap matrix, and the phased plan (Phase 0 perf foundation + creation, do-first → Phase 6 layers). |

## Headline findings

- The shipped editor is a **photo-adjustment PoC** (7 tonal sliders + rotate-90),
  not a paint program. Only ~4 MS-Paint-style capabilities are truly wired
  (brush, flood fill, eyedropper, rotate-90).
- A large, **host-tested raster/paint MODEL layer** exists in
  `Sources/ViewerCore/ImageEditing/` (rotate/flip verbs, crop, resize, rect+lasso
  selection, layers + blend modes, several draw ops) — but most of it is **not
  wired to any UI**. Much "parity" is really *surfacing existing tested code*.
- **Image creation (new blank canvas) is entirely absent** — no model entry
  point, no `File→New Image`, no `NewFileType` image case.
- The owner's "lots of sync operations / clunky" is **confirmed**: there is
  **zero** `async`/`await`/`Task`/`DispatchQueue` in the image-editor UI/VM/
  engine. Every slider tick re-decodes the source from disk, replays all ops,
  allocates a fresh `CIContext` per tonal op, and recomputes a full O(W·H)
  histogram — synchronously on `@MainActor`, with no debounce and no dirty-rect.
  Save uses a blocking modal + main-thread encode + sync write.

### Worst sync/clunk offenders (file:line)

- `Sources/ViewerUI/ImageEditorView.swift:275` — slider setter calls `vm.render()`
  on every drag delta, no debounce (despite a doc-comment claiming one exists).
- `Sources/ViewerCore/ImageEditing/Renderer.swift:33` / `:46` — `render()`
  re-decodes the source file every call; `:348/:369/:390/:409` allocate a fresh
  `CIContext` per tonal op per render.
- `Sources/ViewerUI/ImageEditorViewModel.swift:110` — synchronous render in the
  view-model initializer (janks editor open).
- `Sources/ViewerUI/ImageEditorView.swift:319-342` — `saveCopy` uses blocking
  `runModal()` + main-thread encode + `Data.write(to:atomic)`.
- `Sources/ViewerUI/ImageEditorViewModel.swift:264/278/290` →
  `RasterCanvas.swift:295` — every paint dab rebuilds a full-canvas `CGImage`
  (no dirty-rect).

## Filed work (tasked board)

- **EPIC `TSK-1048`** — `[EPIC] Image Editor → MS Paint (XP + Win7) parity +
  perf-foundation overhaul`.
- **42 child tickets `TSK-1049 … TSK-1090`**, ordered by phase:
  - **Phase 0 (perf foundation + creation, do-first):** `TSK-1049` off-main
    render + cached CIContext, `TSK-1050` debounce slider renders, `TSK-1051`
    decode-once cache, `TSK-1052` dirty-rect paint, `TSK-1053` off-main save,
    `TSK-1054` new-blank-image creation flow, `TSK-1055` undoable paint + unify
    with op-list.
  - **Phase 1 (core tools):** `TSK-1056` pencil, `TSK-1057` eraser, `TSK-1058`
    line, `TSK-1059` rectangle, `TSK-1060` ellipse, `TSK-1061` rounded-rect,
    `TSK-1062` brush size/shape.
  - **Phase 2 (selection + clipboard):** `TSK-1063` rect marquee, `TSK-1064`
    lasso, `TSK-1065` move selection, `TSK-1066` cut/copy/paste + select-all/
    invert, `TSK-1067` paste-from/copy-to file, `TSK-1068` crop to selection.
  - **Phase 3 (color + canvas + transforms):** `TSK-1069` two-color FG/BG,
    `TSK-1070` palette strip, `TSK-1071` Edit Colors dialog, `TSK-1072` flip/
    rotate verbs, `TSK-1073` resize/stretch %·px, `TSK-1074` skew, `TSK-1075`
    invert colors, `TSK-1076` attributes/canvas-size + handles, `TSK-1077` clear
    image.
  - **Phase 4 (formats + save model):** `TSK-1078` BMP, `TSK-1079` GIF,
    `TSK-1080` TIFF, `TSK-1081` Save + Save As.
  - **Phase 5 (Win7 niceties):** `TSK-1082` airbrush, `TSK-1083` curve,
    `TSK-1084` polygon, `TSK-1085` 23-shape gallery, `TSK-1086` anti-aliased
    editable shapes, `TSK-1087` 9-brush gallery, `TSK-1088` zoom/grid/rulers/
    status bar, `TSK-1089` real text tool.
  - **Phase 6 (beyond parity):** `TSK-1090` layers panel + compositing path.
- The pre-existing loose paint tickets (`TSK-110`, `TSK-285`, `TSK-380`,
  `TSK-403/404/405/406`) are now subsumed by this epic; `TSK-380` (the old
  "Mini Paint" umbrella) was commented to point at `TSK-1048`.
