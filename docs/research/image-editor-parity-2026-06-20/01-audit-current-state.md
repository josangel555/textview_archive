# Part 1 — Audit of the current Image Editing + Creation capabilities

Date: 2026-06-20. Read-only audit of the shipped image-editor code. All file:line
references are against the tree at audit time.

## TL;DR

- The editor is a **photo-adjustment PoC**, not a paint program. Its strongest
  surface is non-destructive *tonal* sliders (brightness/contrast/etc.) over a
  lossless op-list. The MS-Paint-style **drawing** affordances are stubs.
- There is a **substantial, well-tested raster/paint MODEL layer** in
  `ViewerCore/ImageEditing/` (canvas, flood fill, brush, selection, layers,
  blend modes, vector overlay) — but most of it **is not wired into any UI**.
  It's dead capability from the user's seat.
- **Image CREATION (new blank canvas) does not exist** at any layer — no model
  entry point, no menu, no `NewFileType` case.
- The owner's "lots of sync operations / clunky" complaint is **correct and
  substantiated**: there is literally **zero** `async`/`await`/`Task`/
  `DispatchQueue` anywhere in the image-editor UI or view-model. Every decode,
  full re-render, Core Image pass, histogram, encode, and file write runs
  **synchronously on `@MainActor`**, re-deriving the *entire* image from
  `source + ops` on every single slider tick.

---

## 1. Architecture (the seams the plan must target)

```
                         opens an existing image file only
  MediaPreviewView ──(editing=true overlay)──► ImageEditorView (SwiftUI, thin binding)
  (Sources/ViewerUI/                              │  @StateObject
   MediaPreviewView.swift:151)                    ▼
                                          ImageEditorViewModel  @MainActor, ObservableObject
                                          (Sources/ViewerUI/ImageEditorViewModel.swift)
                                                   │  holds:  base: ImageDocument
                                                   │          undoStack: EditUndoStack
                                                   │          live tonal slider state (7 Doubles)
                                                   │          paintCanvas: RasterCanvas?   (lazy, destructive)
                                                   │          overlay: VectorOverlay        (vector annotations)
                                                   ▼
                                          ViewerCore/ImageEditing/  (pure, headless, host-tested)
                                          ├─ ImageDocument        source(.url|.data) + [EditOp]   (lossless op-list)
                                          ├─ EditOp               crop/resize/orient + tonal + draw-shape/text ops
                                          ├─ Renderer             source → CGImage  (Core Graphics + Core Image)
                                          ├─ Exporter             CGImage → PNG/JPEG/HEIC bytes (ImageIO)
                                          ├─ Histogram            R/G/B/luma analysis
                                          ├─ RasterCanvas         owned RGBA8 buffer: brush/flood/pick   ◄── paint
                                          ├─ RasterSelection      rect/polygon region + selection-fill   ◄── NOT in UI
                                          ├─ LayeredImageDocument layers + blend modes + own JSON format ◄── NOT in UI
                                          ├─ EditOps+Orientation  rotate/flip verbs + D4 coalescing      ◄── NOT in UI
                                          └─ VectorOverlay        shapes-as-data drawn over the raster
```

**Two parallel, non-unified models of "what is the image":**

1. The **lossless op-list** (`ImageDocument` + `[EditOp]`): every render re-decodes
   the source and replays the full op list (`Renderer.render`,
   `Renderer.swift:33`). Tonal sliders are folded into one op each at render time
   (`ImageEditorViewModel.document`, `ImageEditorViewModel.swift:123`).
2. The **destructive paint buffer** (`RasterCanvas`): once any paint happens, the
   buffer "shadows" the op-list render entirely — paint cannot ride the op-list,
   so `render()` and export switch to the baked pixels
   (`ImageEditorViewModel.swift:155`, `:371`).

These two worlds don't compose: you cannot paint a brush stroke and then crop
losslessly; the moment you paint, the lossless history is frozen behind the
baked buffer. There is also a third, unused world (`LayeredImageDocument`).

---

## 2. Tool / operation inventory — what EXISTS today

### 2a. Wired into the UI (user can actually reach these)

| Capability | How exposed | Model |
|---|---|---|
| Tonal: brightness, contrast, saturation, exposure, shadows, highlights, sharpen | 7 sliders | `EditOp.colorControls/exposure/shadowHighlight/sharpen` (Core Image) |
| Rotate 90° CW | single "Rotate" button | `EditOp.orient(.right90)` |
| Undo / Redo | buttons | `EditUndoStack` (cap 1024) |
| Brush (hard-edged disc) | paint-tool picker + tap on preview | `RasterCanvas.brushDab/brushStroke` |
| Flood fill (paint bucket) | paint-tool picker | `RasterCanvas.floodFill` (4-connected, tolerance) |
| Color picker (eyedropper) | paint-tool picker | `RasterCanvas.pickColor` |
| Paint color | SwiftUI `ColorPicker` | `RGBAColor` |
| Brush size (0–32 radius) | slider | — |
| Fill tolerance (0–255) | slider | — |
| Draw "Box" (fixed centered 50% stroked rect) | button, **not** click-drag | `EditOp.strokeRect` |
| Draw "Text" (literal hard-coded string "Text" at 12,12) | button, **not** an entry field | `EditOp.drawText` |
| Vector annotations: add rect/ellipse/line/arrow (fixed centered), clear | buttons, **not** click-drag | `VectorOverlay` |
| Reset Tone / Revert All | buttons | — |
| Save a Copy (PNG/JPEG/HEIC) | `NSSavePanel` modal | `Exporter` |

The "Box"/"Text"/annotation buttons are explicitly **placeholders** — they commit
a *fixed, centered* shape; there is no drag-to-place, no size, no live entry. See
`ImageEditorView.swift:182` (`commitCenteredShape`) and `:191` (`commitSampleText`),
whose own comments call the real tool "the render-gated remainder."

### 2b. Exists in the MODEL but NOT wired to any UI (dead from the user's seat)

Confirmed by grep: no UI file references these symbols.

- **Rotate left, rotate 180°, flip horizontal, flip vertical** — full verb set
  with D4 op-coalescing exists (`EditOps+Orientation.swift:88-96`); the UI only
  surfaces a single right-90 button.
- **Crop** — `EditOp.crop` + `Renderer.crop` exist and are tested; **no crop UI**.
- **Resize / scale** — `EditOp.resize` + `EditOp.aspectFit` exist and are tested;
  **no resize UI / no attributes dialog**.
- **Rectangular + freeform (lasso) selection** — `RasterSelection` (rect/polygon,
  point-in-polygon) + `RasterCanvas.fill(_:in:)` exist and are tested; **no
  marquee/lasso UI**.
- **Layers** — `LayeredImageDocument`, `ImageLayer` (name/opacity/visibility/
  blend mode), 7 blend modes, add/remove/reorder/move, and a versioned own JSON
  format all exist and are tested; **no layers panel, and the renderer has no
  layer-compositing path** (the model comment even admits compositing is "the
  render-gated remainder", `LayeredImageDocument.swift:12`).
- **Filled rect, filled/stroked ellipse, stroked line** draw ops exist in
  `EditOp` + `Renderer` but the UI only wires the one stroked box.

### 2c. Color model

- **Single** paint color (`RGBAColor`), via SwiftUI `ColorPicker`.
- **No** two-color foreground/background model (the MS Paint left/right-button
  staple). **No** palette / swatch strip wired (TSK-404 "color picker + swatches"
  is at `review` but no swatch UI is present in `ImageEditorView`). **No**
  "Edit Colors" custom-color dialog beyond the OS `ColorPicker`.

### 2d. Export / formats

- Write: **PNG, JPEG, HEIC** only (`ExportSpec.Format`, `ImageDocument.swift:295`).
- **No BMP, no GIF, no TIFF** write (the MS Paint formats).
- Read: anything ImageIO decodes (broad), index 0 only (no multi-frame).
- Save is **"Save a Copy"** only — there is **no in-place Save** of the opened
  file, and **no Save As format negotiation** beyond the 3 types.

### 2e. Undo

- `EditUndoStack`: snapshot-per-commit, FIFO cap 1024, has redo. Solid.
- BUT tonal slider changes are **not** individually undoable (they ride live
  state, folded to one op at render). And the destructive paint buffer is
  **outside** the undo stack — a brush stroke / flood fill is **not undoable at
  all** (only "Discard Paint" wholesale). This is a correctness gap, not just a
  parity gap.

---

## 3. Image CREATION (new blank canvas) — VERDICT: ABSENT

- `RasterCanvas.init(width:height:fill:)` can make a blank buffer
  (`RasterCanvas.swift:60`) and `LayeredImageDocument(canvasSize:)` can make an
  empty document — but **nothing calls them to create a new image**.
- `ImageDocument` has **no** "blank canvas of size W×H, DPI, background color"
  initializer — its only sources are `.url(existing file)` and `.data(bytes)`.
- `NewFileType` (`Sources/ViewerCore/NewFileCreator.swift:116`) has cases
  `text / markdown / csv / json` — **no image case**.
- `ImageEditorView.init(url:onClose:)` requires an existing URL
  (`ImageEditorView.swift:20`); the editor is reachable **only** via
  `MediaPreviewView` after opening an image file (`MediaPreviewView.swift:151`).

**There is no File → New Image, no size/DPI/background dialog, no blank-canvas
round-trip.** This is the owner's "image creation seems absent" — confirmed.

---

## 4. The "sync operations / clunky" smells — WITH file:line evidence

The owner's specific complaint. Substantiated: **the entire pipeline is
synchronous on the main thread**, and the op-list architecture re-derives the
whole image from scratch on every interaction. Grep for
`Task|DispatchQueue|async|await|@MainActor|actor` across the image-editor UI +
VM + engine returns **only the `@MainActor` annotation and doc-comment prose** —
no actual off-main work anywhere.

### Offender 1 — full re-decode + full op replay on EVERY slider tick (main thread)

`Sources/ViewerUI/ImageEditorView.swift:275`

```swift
set: { vm[keyPath: keyPath] = $0; vm.render() }   // every drag delta
```

`render()` (`ImageEditorViewModel.swift:150`) calls `Renderer.render(document)`,
which (`Renderer.swift:33`):
1. `decode(doc.source)` — re-reads/re-decodes the **source image from disk/Data
   every time** (`Renderer.swift:46`, `CGImageSourceCreateWithURL`).
2. `normalized(...)` — redraws the whole raster into a fresh CGContext.
3. replays **all** ops, each tonal op spinning up a **fresh `CIContext`**
   (`Renderer.swift:348`, `:369`, `:390`, `:409` — a new `CIContext` per op, per
   render; `CIContext` creation is expensive and is happening on the main thread
   inside a slider drag).
4. then `Renderer.histogram(image)` — a full O(W·H) per-pixel loop
   (`Renderer.swift:430`) on the main thread, **every render**.

There is **no debounce/throttle** (the doc-comment at
`ImageEditorViewModel.swift:148` claims "the view debounces" — it does not; the
slider setter calls `render()` directly with no `Task`, `Combine` debounce, or
coalescing). On a large image, every pixel of a slider drag = decode + redraw +
N CIContexts + full histogram, all blocking the UI.

### Offender 2 — synchronous decode + render in the view initializer

`Sources/ViewerUI/ImageEditorView.swift:21`

```swift
_vm = StateObject(wrappedValue: ImageEditorViewModel(ImageDocument(contentsOf: url)))
```

`ImageEditorViewModel.init` calls `render()` **synchronously** in the initializer
(`ImageEditorViewModel.swift:110`) → decode + normalize + histogram on the main
thread as the editor view is constructed. Opening the editor on a large image
janks the open.

### Offender 3 — blocking modal save panel + main-thread encode + sync write

`Sources/ViewerUI/ImageEditorView.swift:319-342` (`saveCopy`)

- `panel.runModal()` (`:323`) — **synchronous, blocking** modal.
- `vm.saveCopy(...)` → `export(...)` → `exportData(...)` → `Exporter.export`
  (`ImageEditorViewModel.swift:369-379`): renders again (full pipeline) **then**
  `CGImageDestinationFinalize` encode (`Exporter.swift:42`), **then**
  `Data.write(to: url, options: .atomic)` (`ImageEditorViewModel.swift:379`) —
  **encode + disk write on the main thread**, no `Task`/off-main hop. A large
  PNG encode + atomic write blocks the UI.

### Offender 4 — every paint op re-renders the whole canvas to a CGImage

`ImageEditorViewModel.swift:264, :278, :290` — `brushDab`/`brushStroke`/
`floodFill` each call `render()`, which calls `paintCanvas.cgImage()`
(`RasterCanvas.swift:295`) to rebuild a **full-canvas** `CGImage` from the entire
pixel buffer on **every dab** — no dirty-rect, no incremental tile update. Drag a
brush across a 4000×4000 image and each mouse-move rebuilds the entire image.

### Offender 5 — no dirty-rect / incremental rendering anywhere

The renderer's contract is "(source, ops) → whole CGImage". There is no notion of
a damaged region, tile, or partial update. Every visible change repaints
everything. This is the structural root of the "clunky" feel.

### Offender 6 — `RasterCanvas.from` un-premultiply loop on the main thread

`RasterCanvas.swift:326-360` — baking a paint session walks every pixel to
un-premultiply, synchronously, the first time you touch a paint tool.

### Secondary smells

- `CIContext` is re-allocated per tonal op per render (no shared/cached context)
  — `Renderer.swift:348/369/390/409`. A cached `CIContext` is the standard fix.
- Histogram recomputed on every render even when only geometry changed
  (`ImageEditorViewModel.swift:166`); it's best-effort but still O(W·H) on main.
- Resize uses Core Graphics high-quality draw with an explicit TODO that
  `vImageScale_ARGB8888` is the fast path (`Renderer.swift:243` note) — not yet
  taken.
- Histogram has the same un-taken `vImageHistogramCalculation_ARGB8888` note
  (`Renderer.swift:427`).

---

## 5. Test coverage (informs what's safe to refactor)

Strong **model** coverage exists (host-testable, pure logic):
`ImageEditingTests`, `ImageOrientationTests`, `ImageDrawOpsTests`,
`RasterCanvasTests`, `RasterSelectionTests`, `LayeredImageDocumentTests`,
`ImageEditorViewModelTests`, `ImageEditorPaintTests`,
`ImageEditorVisualRegressionTests`. The render *path* (pixels on screen) is
VM-gated per the repo's testing rules.

Implication: the Phase 0 perf refactor (off-main render, dirty-rect, image
creation) can be driven hard on host tests at the model/VM layer; the on-screen
interaction tools need VM UI validation.

---

## 6. Bottom line for the plan

- The **model layer is far ahead of the UI**. A lot of "parity" is really
  *exposing existing, tested model code* (rotate/flip verbs, crop, resize,
  selection, layers) behind real UI — cheaper than it looks.
- The **architecture is the problem the owner feels**: synchronous, full-image,
  no-dirty-rect, no off-main. Phase 0 must fix that *before* piling on tools, or
  every new tool inherits the clunk.
- **Image creation and the two-color model + real click-drag tools + a tool
  palette** are the genuinely missing primitives that make it "a paint program"
  rather than "a slider panel."
