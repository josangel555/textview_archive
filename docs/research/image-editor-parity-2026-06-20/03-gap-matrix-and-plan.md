# Part 3 — Gap analysis + phased plan

Legend for "Present?": **Yes** (wired + reachable) · **Model-only** (tested code
exists, no UI) · **Stub** (placeholder UI, not the real tool) · **No** (absent).
Effort: S (≤1 slice), M (1–2 slices), L (multi-slice / needs design).

## Gap matrix — feature → present? → Paint XP / Win7 → effort

| Feature | Present today | Paint XP | Paint Win7 | Effort |
|---|---|---|---|---|
| **Pencil (1px)** | No | Yes | Yes | S |
| **Brush (free draw, sized)** | Yes (hard disc) | Yes | Yes (9 brushes) | S / L (gallery) |
| **Airbrush / spray** | No | Yes | Yes | M |
| **Eraser** (to bg color) | No | Yes | Yes | S |
| **Color eraser** (right-drag) | No | Yes | — | M |
| **Fill / paint bucket** | Yes | Yes | Yes | — |
| **Eyedropper / pick color** | Yes | Yes | Yes | — |
| **Magnifier / zoom tool** | Partial (preview zoom in MediaPreview, not in editor) | Yes | Yes | M |
| **Text tool** (real entry, font, drag box) | Stub (hard-coded "Text") | Yes | Yes | L |
| **Line** (click-drag, width) | Stub (fixed) | Yes | Yes | S |
| **Curve** (1–2 arcs) | No | Yes | Yes | M |
| **Rectangle** (drag, fill styles) | Stub (fixed centered) | Yes | Yes | M |
| **Rounded rectangle** | No | Yes | Yes | S |
| **Ellipse** (drag) | Model-only op | Yes | Yes | S |
| **Polygon** (multi-click) | No | Yes | Yes | M |
| **Extended shape gallery (23)** | No | — | Yes | L |
| **Rectangular select (marquee)** | Model-only (`RasterSelection`) | Yes | Yes | M |
| **Free-form select (lasso)** | Model-only (`RasterSelection`) | Yes | Yes | M |
| **Move / nudge selection** | No | Yes | Yes | M |
| **Two-color FG/BG model (L/R button)** | No (single color) | Yes | Yes | M |
| **Palette / swatch strip** | No (OS ColorPicker only) | Yes | Yes | S |
| **Edit Colors custom dialog** | Partial (OS picker) | Yes | Yes | S |
| **New blank image (size/bg)** | **No** | Yes | Yes | M |
| **Image attributes / canvas size** | No (model `resize` only) | Yes | Yes | M |
| **Canvas resize handles** | No | Yes | Yes | M |
| **Crop (to selection)** | Model-only (`EditOp.crop`) | (manual) | Yes | M |
| **Clear image** | Partial (Revert/Discard) | Yes | Yes | S |
| **Select all / invert / delete** | No | Yes | Yes | S |
| **Flip H / Flip V** | Model-only (verbs exist) | Yes | Yes | S |
| **Rotate 90 L / 90 R / 180** | Partial (only 90 R button) | Yes | Yes | S |
| **Stretch (resize by % / px)** | Model-only (`resize`/`aspectFit`) | Yes | Yes | M |
| **Skew (degrees)** | No | Yes | Yes | M |
| **Invert colors** | No | Yes | Yes | S |
| **Cut / copy / paste** | No | Yes | Yes | M |
| **Paste from file / copy to file** | No | Yes | Yes | M |
| **Undo / redo** | Yes (geom/draw only) | 3-level | 50-level | S (extend to paint) |
| **Undo for paint strokes** | **No** (buffer outside stack) | Yes | Yes | M |
| **Layers** | Model-only (`LayeredImageDocument`) | — | — | L (beyond parity) |
| **BMP write** | No | Yes | Yes | S |
| **GIF write** | No | Yes | Yes | S |
| **TIFF write** | No | Yes | Yes | S |
| **PNG / JPEG write** | Yes | Yes | Yes | — |
| **Save (in-place) + Save As** | No (Save-a-Copy only) | Yes | Yes | M |
| **Show grid (at zoom)** | No | Yes | Yes | S |
| **Rulers** | No | — | Yes | S |
| **Thumbnail / status coords** | No | Yes | Yes | S |
| **Anti-aliased editable shapes** | No | — | Yes | L |
| **Tonal sliders (brightness/etc.)** | Yes | — (beyond Paint) | — | — |
| **Vector annotation overlay** | Yes (stub placement) | — | — | — |

**Headline:** of the ~30 MS-Paint-defining capabilities, the app today truly has
~4 wired (brush, bucket, eyedropper, rotate-90 + tonal extras). ~8 more exist as
**tested model code with no UI** (rotate/flip verbs, crop, resize, rect/lasso
selection, layers, several draw ops) — cheap to surface. The rest (~18) are
missing, and **image creation + the two-color model + real click-drag tools +
off-main rendering** are the structural gaps that separate "slider panel" from
"paint program."

---

## Phased plan

Each phase ships independently. **Phase 0 fixes the architecture the owner feels
("clunky / sync") BEFORE adding tools** — otherwise every new tool inherits the
synchronous, full-repaint clunk. Phases 1+ then lean heavily on the
already-tested model layer.

### Phase 0 — Foundation: kill the clunk, add creation (DO FIRST)

Goal: every interaction is responsive; rendering is incremental and off-main; you
can make a new image. No new *tools* yet — just make the existing surface fast +
creatable.

- **0.1 Off-main render pipeline.** Move `Renderer.render` / `histogram` / encode
  off `@MainActor` (async `Task` with a serial render queue; publish results back
  on main). Cache a single `CIContext`. Cancel in-flight renders on new input.
- **0.2 Debounce + coalesce slider re-renders.** Replace the per-delta
  `vm.render()` with a coalesced trailing-edge render (the doc-comment already
  *claims* this exists — make it real).
- **0.3 Decode-once / cached normalized base.** Stop re-decoding the source file
  on every render; decode once, cache the normalized CGImage, replay ops from
  the cached base.
- **0.4 Dirty-rect / incremental paint compositing.** Paint ops update only the
  damaged region of a backing layer instead of rebuilding a full-canvas CGImage
  per dab.
- **0.5 Off-main save + non-blocking save flow.** Encode + write on a background
  task; drop the blocking `runModal()` pattern for the async panel API.
- **0.6 New blank image (creation flow).** `ImageDocument`/canvas "blank W×H,
  background color" entry point + a File→New Image menu + a size/background
  dialog; reach the editor without an existing file. (Owner: "creation seems
  absent.")
- **0.7 Paint strokes become undoable.** Fold the destructive paint buffer into
  the undo stack (snapshot or tile-diff) so brush/fill are Ctrl-Z-able, and unify
  paint with the op-list so you can paint then crop.

### Phase 1 — Core paint tools (XP parity, the daily drivers)

- **1.1 Pencil** (1px). **1.2 Eraser** (to background color). **1.3 Real
  click-drag Line** (width). **1.4 Real click-drag Rectangle** (outline/fill/
  both). **1.5 Ellipse** (drag). **1.6 Rounded rectangle.** **1.7 Brush sizes +
  shapes** (round/square). All map to existing `EditOp`/`RasterCanvas` ops; the
  work is the **drag gesture → live preview → commit** UI.

### Phase 2 — Selection + clipboard + move

- **2.1 Rectangular marquee** (wire `RasterSelection.rect`). **2.2 Free-form
  lasso** (wire `RasterSelection.polygon`). **2.3 Move/nudge selection.**
  **2.4 Cut/Copy/Paste/Delete + Select All/Invert.** **2.5 Paste-from-file /
  copy-to-file.** **2.6 Crop to selection** (wire `EditOp.crop`).

### Phase 3 — Color model + canvas/transforms

- **3.1 Two-color FG/BG** (left/right button). **3.2 Palette/swatch strip.**
  **3.3 Edit Colors custom dialog.** **3.4 Flip H/V + Rotate L/180** (wire the
  existing verbs). **3.5 Resize/Stretch by %/px dialog** (wire `resize`).
  **3.6 Skew by degrees.** **3.7 Invert colors.** **3.8 Image Attributes / canvas
  size + resize handles.** **3.9 Clear image.**

### Phase 4 — File formats + save model

- **4.1 BMP write.** **4.2 GIF write.** **4.3 TIFF write.** **4.4 In-place Save +
  Save As** with format negotiation. (PNG/JPEG already present.)

### Phase 5 — Win7 niceties + view

- **5.1 Airbrush/spray.** **5.2 Curve tool.** **5.3 Polygon tool.** **5.4 Extended
  shape gallery (23).** **5.5 Anti-aliased editable-until-rasterized shapes.**
  **5.6 Brush gallery (9 artistic brushes).** **5.7 Zoom tool + show grid + rulers
  + status-bar coords/selection size.** **5.8 Text tool** (real entry box, font,
  drag — promote the stub).

### Phase 6 — Beyond-parity (already-built, optional to surface)

- **6.1 Layers panel + layer compositing render path** (`LayeredImageDocument`
  exists, model-only; the renderer has no compositing path yet). Beyond MS Paint
  parity; surfaces existing tested model.

---

## Sequencing rationale

1. Phase 0 is non-negotiably first: it's the owner's stated pain, and it changes
   the seams every later tool plugs into (off-main render, dirty-rect, unified
   paint+op-list undo). Adding tools first would mean re-doing them after the
   refactor.
2. Phases 1–3 are mostly **UI-over-existing-model** — high value per unit effort,
   because the engine (ops, canvas, selection, orientation) is already tested.
3. Phase 4 (formats) is small and isolated — one encoder path each.
4. Phase 5 is the Win7 delta — the genuinely new engine work (artistic brushes,
   anti-aliased editable shapes, 23-shape gallery).
5. Phase 6 is optional upside that monetizes already-built layer code.
