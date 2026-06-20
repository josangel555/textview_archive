# Part 2 — Parity research: MS Paint (Windows XP) vs MS Paint (Windows 7)

The parity bar we are measuring against. Independently established via web
research (sources at the bottom). The two versions differ substantially: Win7
was a major redesign (ribbon UI, brush gallery, shape gallery, anti-aliasing,
deeper undo).

> A second, independent **unprimed** research pass (handed only the raw question,
> not this draft) cross-confirmed every figure below and added precision. Its
> full report is preserved verbatim in
> [`02b-parity-research-unprimed.md`](./02b-parity-research-unprimed.md). Key
> corroborated specifics folded in here: XP toolbox = **16 tools / 28-color
> palette**, default new canvas **400×300**, XP Brush = **12 styles** (round/
> square/slash × 3 sizes), **3-level undo** in XP (Vista bumped to 10, Win7 to
> 50), and the **GDI+ inflection in XP** that first gave Paint native PNG/TIFF
> read-write (plus JPEG/GIF) and TWAIN scanner/camera acquire. Win7's default
> save format changed from BMP → **PNG**, and XP's "Draw Opaque" toggle became
> Win7's "Transparent selection".

## A. The toolbox (drawing + selection tools)

### Windows XP Paint — 14 tools (the classic two-column toolbox)

1. **Free-Form Select** (lasso) — irregular selection.
2. **Select** — rectangular selection (marquee).
3. **Eraser / Color Eraser** — erases to background color; right-drag = color-
   eraser (replaces foreground color with background only).
4. **Fill With Color** (paint bucket) — flood fill a contiguous region.
5. **Pick Color** (eyedropper) — sample a pixel into the active color.
6. **Magnifier** — zoom tool (1x/2x/6x/8x), with a "show grid" + thumbnail at zoom.
7. **Pencil** — 1px free draw.
8. **Brush** — free draw with a tool-options size/shape selector (round/square/
   slash brush shapes at a few sizes).
9. **Airbrush** (spray can) — speckled spray, density by dwell time; 3 spray sizes.
10. **Text** — type text in a draggable text box, with a floating Fonts toolbar
    (font/size/bold/italic/underline), opaque or transparent background.
11. **Line** — straight line; tool-options line width (5 widths).
12. **Curve** — Bézier-ish line with one or two drag-adjusted arcs.
13. **Rectangle** — outline / filled / outline+filled (3 fill styles).
14. **Polygon** — multi-segment closed polygon (same 3 fill styles).
15. **Ellipse** — (counted within the rectangle/rounded family) outline/filled.
16. **Rounded Rectangle** — rounded-corner rectangle.

(XP toolbox is commonly enumerated as 16 buttons: the 14 above plus Rounded-Rect
and Ellipse. Each shape tool has the 3-way outline/fill style chooser, and Line/
Brush/Airbrush/Eraser have size choosers, in the tool-options well below the box.)

### Windows 7 Paint — ribbon "Tools" + "Brushes" + "Shapes" groups

Same conceptual tools, reorganized into the ribbon and **expanded**:

- **Tools group:** Pencil, Fill with color (bucket), Text, Eraser, Color picker
  (eyedropper), Magnifier. (Select + the brush/shape galleries moved to their own
  groups.)
- **Brushes gallery — 9 brushes, 7 new in Win7** (XP had only the single Brush):
  Brush (regular), Calligraphy brush 1, Calligraphy brush 2, Airbrush, Oil brush,
  Crayon, Marker (highlighter), Natural pencil, Watercolour brush. The "artistic"
  brushes use grayscale + partial transparency for a realistic look; oil and
  watercolour "run out of paint" after a short stroke until you re-click. A **Size**
  dropdown sets brush/line/eraser thickness.
- **Shapes gallery — 23 shapes, up from 4** (XP shapes were Line, Curve,
  Rectangle, Ellipse): Line, Curve, Oval, Rectangle, Rounded rectangle, Polygon,
  Triangle, Right triangle, Diamond, Pentagon, Hexagon, Right/Left/Up/Down arrows,
  Four-point star, Five-point star, Six-point star, Rounded rectangular callout,
  Oval callout, Cloud callout, Heart, Lightning. Each shape has an **Outline**
  style + **Fill** style chooser (No outline / Solid / and the brush textures:
  crayon, marker, oil, watercolour, natural pencil) and a **Size** (thickness).
- **Anti-aliased shapes:** shapes (and the brush gallery) render anti-aliased.
  A drawn shape stays **editable/resizable until rasterized** (committed when you
  pick another tool or click away) — XP shapes were hard-edged and committed
  immediately.
- **Select** group: Rectangular selection, Free-form selection, plus Select-all,
  Invert selection, Delete, and Transparent-selection toggle.

## B. Color handling

- **Two-color model (both versions):** a **Foreground (Color 1)** and
  **Background (Color 2)**. Left mouse button paints with Color 1, right button
  with Color 2 (and fills/eraser use Color 2 as background). This left/right
  two-color split is the defining MS Paint color interaction.
- **Palette / color box (both):** a strip of preset swatches; click sets Color 1,
  right-click sets Color 2. Win7 renders it in the ribbon's Colors group.
- **Edit Colors / custom color dialog (both):** "Edit Colors…" opens the standard
  Windows custom-color picker (basic colors grid + custom color matrix +
  hue/sat/lum + RGB fields + "Add to Custom Colors"). Win7 labels it the same.
- **Color picker tool (eyedropper)** sets the active color from a pixel.

## C. Canvas / image operations

- **Image → Attributes (XP)** / **Resize+canvas (Win7):** set the image
  **Width × Height** in pixels / inches / cm, and (XP) the color depth
  (Black & white vs Colors) and DPI/resolution readout. This is also the dialog
  that defines the canvas for a new image.
- **Canvas resize handles:** drag the bottom/right/corner handles to grow or crop
  the canvas (background-filled on grow, truncated on shrink) — both versions.
- **Clear Image** (Image menu, XP; Ctrl+Shift+N era) — fill the whole canvas with
  the background color.
- **Crop (Win7):** crop to the current selection (a dedicated Crop command). XP
  had no one-click crop (you'd select → copy → new image).
- **Select All / Invert Selection / Delete selection** — both.

## D. Transforms

- **Flip horizontal / Flip vertical** — both versions (XP: Image → Flip/Rotate).
- **Rotate by angle:** XP "Flip/Rotate" offered 90° / 180° / 270°. Win7's Rotate
  dropdown: Rotate right 90°, Rotate left 90°, Rotate 180°, Flip vertical, Flip
  horizontal.
- **Stretch / Skew (XP "Stretch and Skew"; Win7 "Resize and Skew"):**
  - **Stretch** by **percentage** horizontal/vertical (and Win7 also by absolute
    pixels, with a "maintain aspect ratio" checkbox).
  - **Skew** by **degrees** horizontal/vertical (−89…89).
- **Invert Colors** (Image → Invert Colors, Ctrl+Shift+I in Win7) — photo-negative.
- Transforms apply to the **selection** if one is active, else the whole image —
  both versions.

## E. Image creation (new blank image)

- **File → New (Ctrl+N):** both versions create a new blank canvas. XP defaults to
  the previous image's size (or a default); you set the real size via Image →
  Attributes. Win7 creates a default-sized white canvas you then Resize. The new
  canvas is filled with the **background color** (white by default). Prompts to
  save unsaved changes first.

## F. Clipboard

- **Cut / Copy / Paste / Delete / Select All** — both.
- **Paste From… (file):** paste an image file as a floating selection — both
  (Edit → Paste From in XP; ribbon Paste → Paste from in Win7).
- **Copy To… (file):** save the current selection out to a file — both.
- Paste lands a floating, movable selection at the top-left; Transparent-selection
  toggle controls whether Color 2 pastes as transparent.

## G. File formats

- **XP read/write:** BMP (Monochrome, 16-color, 256-color, 24-bit sub-variants),
  JPEG, GIF, TIFF, PNG. (PNG/TIFF/JPEG support is present in XP-era Paint.)
- **Win7 read/write:** BMP (sub-variants), PNG (default), JPEG, GIF, TIFF, plus a
  "Set as desktop background" and "Send in email". Win7's default save format is
  **PNG** (XP defaulted to BMP).

## H. Undo depth

- **XP: 3 levels of undo** (the infamous 3-undo limit), no redo originally
  (Ctrl+Z; redo arrived as Ctrl+Y in some builds).
- **Win7: up to 50 undo levels**, with redo.

## I. Zoom / view

- **Zoom:** XP magnifier 1x/2x/6x/8x; Win7 ribbon View tab with Zoom in/out,
  100%, and a zoom slider on the status bar.
- **Show Grid** (gridlines) at high zoom — both (View → Zoom → Show Grid in XP;
  View tab Gridlines in Win7).
- **Thumbnail** overview while zoomed — XP (View → Zoom → Show Thumbnail); Win7
  has Thumbnail too.
- **Rulers** — Win7 View tab adds Rulers (XP did not have rulers).
- **Full Screen** preview (View → View Bitmap, Ctrl+F in XP; View tab Full screen
  in Win7).
- **Status bar:** cursor coordinates + selection size readout — both.

## J. Windows-7-only additions over XP (the delta)

1. The **Scenic Ribbon** UI (replaces the menu bar + toolbox) with live-preview
   Style Galleries.
2. **9-brush artistic brush gallery** (7 new) with transparency/grayscale realism.
3. **23-shape gallery** (up from 4) with outline+fill style choosers and brush
   textures as fills.
4. **Anti-aliasing** on shapes and brushes; shapes stay **editable/resizable
   until rasterized**.
5. **Resize dialog by percentage OR pixels** with maintain-aspect-ratio.
6. **One-click Crop** to selection.
7. **50-level undo** (vs 3).
8. **Rulers**, a status-bar **zoom slider**, and a cleaner View tab.
9. PNG as the **default** save format.
10. "Set as desktop background", "Send in email", and a redesigned color picker
    in the ribbon Colors group.

## Sources

- [Microsoft Paint — Microsoft Wiki (Fandom)](https://microsoft.fandom.com/wiki/Microsoft_Paint)
- [Microsoft Paint — Microsoft Windows XP Wiki (Fandom)](https://the-microsoft-windows-xp.fandom.com/wiki/Microsoft_Paint)
- [Windows 7 Feature Focus: Scenic Ribbon, Paint and WordPad — ITPro Today](https://www.itprotoday.com/windows-7/windows-7-feature-focus-scenic-ribbon-paint-and-wordpad)
- [Microsoft Paint — Ultimate Pop Culture Wiki (Fandom)](https://ultimatepopculture.fandom.com/wiki/Microsoft_Paint)
- [MS Painting Tools Functions — Techwalla](https://www.techwalla.com/articles/ms-painting-tools-functions)
- [A Guide to Microsoft Paint XP (Scribd)](https://www.scribd.com/document/150330668/A-Guide-to-Microsoft-Paint-XP)
- [MS Paint Resize and Skew — eStudy247](https://estudy247.com/courses/ms-paint/lessons/ms-paint-resize-and-skew/)
- [Use tools and make pictures with Windows Paint (XP) — iniminimo](https://fay.iniminimo.com/paint_xp.html)
