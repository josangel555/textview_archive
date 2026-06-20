# Part 2b — Independent unprimed parity research (verbatim)

This is the full report from a second research pass run as a deliberately
**unprimed / blank-slate** subagent: it was handed only the raw question ("catalog
the complete feature set of MS Paint XP vs Win7") with no access to the primary
draft (`02-parity-research-mspaint.md`), so it could surface angles the primed
pass might miss. Its figures cross-confirm the primary draft; preserved here
verbatim for the record.

---

# Microsoft Paint Feature Inventory: Windows XP (2001) vs Windows 7 (2009)

The Windows 7 release was the first ground-up redesign of Paint in roughly 15 years: the classic menu-bar + floating-toolbox UI was replaced by the Office-style **Scenic Ribbon**, and the tool/brush/shape sets were greatly expanded with anti-aliasing throughout. Below is the raw, complete inventory per category.

## 1. UI shell (the headline difference)

| | Windows XP | Windows 7 |
|---|---|---|
| Layout | Menu bar (File/Edit/View/Image/Colors/Help) + floating **Tool Box** (left) + **Color Box** (bottom) + status bar | **Scenic Ribbon** (an evolution of the Office 2007 ribbon, brought into the OS codebase). A **Paint button** (menu) replaces the File menu |
| Tabs | n/a | **Home** tab + **View** tab |
| Home groups | n/a | **Clipboard, Image, Tools, Brushes, Shapes, Size, Colors** |
| Quick Access Toolbar | No | Yes (Save / Undo / Redo, customizable) |

## 2. Toolbox / tool set

**Windows XP — 16 tools** (fixed 16-tool floating toolbox; confirmed "16 tools, 28 colors"):

1. Free-Form Select
2. Select (Rectangular select)
3. Eraser / Color Eraser (same tool — left button erases to background color; right-drag does selective "color eraser," replacing foreground with background only)
4. Fill With Color (paint bucket)
5. Pick Color (eyedropper / color picker)
6. Magnifier (zoom; offers 1x/2x/6x/8x presets)
7. Pencil (1px freehand)
8. Brush — **12 styles**: round, square, and diagonal/slash (calligraphic "italic pen-nib" strokes), each in **3 widths**
9. Airbrush / Spray can — **3 spray sizes**
10. Text (the "A" tool; Text Toolbar for font/size/bold/italic/underline)
11. Line (with a width selector: 5 thicknesses)
12. Curve (Bézier-style: draw a line, then drag up to two control points)
13. Rectangle
14. Polygon
15. Ellipse
16. Rounded Rectangle

Shape tools 13–16 each offer **3 fill modes** in the tool options: outline only, outline + fill, fill only (foreground outline / background fill).

**Windows 7 — Tools group (6) + galleries:**

- **Tools group:** Pencil, **Fill with color**, **Text**, **Eraser**, **Color picker**, **Magnifier** (zoom). Free-form select and rectangular select moved out of the toolbox into the **Image → Select** dropdown.
- Selection types under **Select:** Rectangular selection, Free-form selection, plus **Select all**, **Invert selection**, **Delete**, and **Transparent selection** toggle (background-color pixels become transparent when moving/pasting).
- A single **Size** group sets line/brush/shape thickness (replaces XP's per-tool width pickers).

**Net tool changes XP → Win7:** the pencil, fill, text, eraser, color-picker and magnifier survive as discrete tools; the single "Brush" expands into a **brush gallery** (below); the 4 shape tools expand into a **23-shape gallery** (below); airbrush moves into the brush gallery; the two selection tools move into the Select dropdown.

## 3. Brushes

**Windows XP:** one Brush tool, **12 styles** (round/square/slash × 3 sizes) + a separate Airbrush (3 sizes). All hard-edged, aliased.

**Windows 7 — Brushes gallery (9 brushes), most with realistic texture/transparency** (composed of varying gray shades + partial transparency):

1. Brush (standard)
2. Calligraphy brush 1
3. Calligraphy brush 2
4. Airbrush
5. Oil brush
6. Crayon
7. Marker
8. Natural pencil
9. Watercolour brush

Notable behavior: the **Oil** and **Watercolour** brushes "run out of paint" — they fade after a short stroke and require a re-click, simulating real media.

## 4. Shapes

**Windows XP — 4 shape tools:** Line, Curve, Rectangle, Rounded Rectangle, Ellipse, Polygon (effectively Line + Curve + the 4 closed shapes). All aliased/jagged.

**Windows 7 — Shapes gallery of 23 anti-aliased shapes** (= 6 basic + 6 polygon/star + 4 arrows + 3 callouts + 2 symbols):

- **Basic (6):** Line, Curve, Oval, Rectangle, Rounded rectangle, Polygon (free polygon)
- **Polygon/star (6):** Triangle, Right triangle, Diamond, Pentagon, Hexagon, plus star shapes (4-point / 5-point / 6-point stars are part of this/symbol group)
- **Arrows (4):** Right, Left, Up, Down arrow
- **Callouts (3):** Rectangular callout, Rounded-rectangular callout, Oval/cloud callout
- **Symbols (2):** Heart, Lightning

Win7 shapes are **anti-aliased** and stay **editable/re-sizable vectors** until you switch tools, at which point they rasterize. Each shape has:
- **Outline** style dropdown (Solid color, plus the brush-texture styles: crayon, marker, oil, watercolor, natural pencil — i.e., textured outlines) or **No outline**
- **Fill** style dropdown (same set) or **No fill**
- **Size** (thickness) from the Size group

## 5. Color handling

| | Windows XP | Windows 7 |
|---|---|---|
| Palette | **Color Box, 28 swatches** | Ribbon **Colors** group, ~20 default swatches + custom slots |
| Two-color model | Foreground + Background. **Left mouse = foreground, right mouse = background**. Left-click a swatch sets foreground; right-click sets background | Renamed **Color 1** (primary) and **Color 2** (secondary). Left = Color 1, right = Color 2. You explicitly click the Color 1 / Color 2 button then pick a swatch |
| Custom colors | Double-click a swatch → **Edit Colors** dialog → **Define Custom Colors** (RGB / Hue-Sat-Lum picker; 48 basic + 16 custom slots) | **Edit colors** button → same RGB/HSL "Define Custom Colors" dialog; chosen color added to the palette |
| Eyedropper | Pick Color tool | Color picker tool (sets Color 1, or Color 2 with right-click) |

## 6. Canvas / image operations

**Image → Attributes (XP)** / **Properties dialog (Win7):**
- Set **Width** and **Height**
- **Units:** Inches, Cm (centimeters), Pixels
- **Colors:** Black and white (monochrome) vs Colors
- Win7 Properties dialog also shows file size / resolution and adds **Units = inches/cm/pixels** plus a **Default** button.
- Default new-canvas size: **400 × 300 px** (XP).

**Other canvas ops:**
- **Resize handles:** drag the canvas's corner/edge handles to grow/shrink (both versions).
- **Crop:** XP has no one-click crop (you select a region, copy, and File → New / paste, or shrink attributes). **Win7 adds a dedicated Crop button** (Image group) that crops to the current selection.
- **Clear Image:** XP **Image → Clear Image** (Ctrl+Shift+N) fills canvas with background color. Win7: Select All → Delete, or there's no separate "Clear Image" command in the same place.
- **Draw Opaque:** XP **Image → Draw Opaque** toggle (controls whether the background color in a pasted/moved selection is transparent). In Win7 this becomes the **Transparent selection** toggle under Select.

## 7. Transforms

| Operation | Windows XP | Windows 7 |
|---|---|---|
| Flip | Image → **Flip/Rotate**: Flip horizontal, Flip vertical | **Rotate** dropdown: Flip horizontal, Flip vertical |
| Rotate by angle | Flip/Rotate dialog: rotate **90°, 180°, 270°** | Rotate dropdown: **rotate right 90°, rotate left 90°, rotate 180°** |
| Stretch | Image → **Stretch/Skew**: Stretch **horizontal % / vertical %** | Merged into **Resize and Skew** dialog (Ctrl+W): Resize by **Percentage or Pixels**, Horizontal/Vertical, **Maintain aspect ratio** checkbox |
| Skew | Stretch/Skew dialog: Skew **horizontal / vertical in degrees** | Resize and Skew dialog: **Skew (degrees)** Horizontal/Vertical (positive = right/down, negative = left/up) |
| Invert colors | Image → **Invert Colors** (Ctrl+I) | **Invert color** (right-click canvas → Invert color; not on the main ribbon face) |

Key Win7 change: **Stretch and Skew are unified into one "Resize and Skew" dialog**, and resize gains a true **Pixels** mode + **Maintain aspect ratio** (XP only had percentage stretch).

## 8. Image creation (New)

- Both: **File/Paint button → New** creates a blank canvas.
- XP: new canvas inherits the last Attributes (default 400×300, color). You set size via Image → Attributes after creating.
- Win7: New canvas via the Paint button; properties set in the **Properties** dialog (Ctrl+E). Default format for saving is now **PNG**.

## 9. Clipboard

| | Windows XP | Windows 7 |
|---|---|---|
| Cut / Copy / Paste | Edit menu (Ctrl+X / C / V) | Clipboard group on Home tab |
| **Paste From** (insert an image file into the canvas) | Edit → **Paste From…** | Paste dropdown → **Paste from** |
| **Copy To** (save the current selection as a file) | Edit → **Copy To…** | Copy dropdown → **Copy to** (present in Win7) |
| Select All / Clear Selection | Edit menu | Select dropdown (Select all, Invert selection, Delete) |

## 10. File formats

**Readable & writable in both (via GDI+, added in XP):** BMP, JPEG, GIF, TIFF, PNG.

**BMP sub-variants in the "Save as type" dropdown (both versions):**
- Monochrome bitmap (1-bit)
- 16-color bitmap (4-bit)
- 256-color bitmap (8-bit)
- 24-bit bitmap (full color)

**Version notes:**
- **XP was the inflection point:** earlier Paint (Win95/98/2000) needed graphics filters and primarily did BMP; XP switched Paint to **GDI+**, giving native **PNG and TIFF** read/write (plus JPEG/GIF) with no add-ons. XP also added **scanner/camera (TWAIN) acquire** (From Scanner or Camera).
- **Win7 default save format changed to PNG** (XP defaulted to 24-bit BMP). Win7 can **view/open** transparent PNGs and **ICO** files (it renders alpha transparency on load), though it still flattens transparency on edit/save in most paths.

## 11. Undo / Redo

- **Windows XP: 3 undo levels** (Ctrl+Z). Redo via Ctrl+Y / Edit → Repeat.
- (Vista bumped this to 10 — intermediate data point.)
- **Windows 7: 50 undo levels** (a large jump from 3). Redo Ctrl+Y.

## 12. Zoom / View

**Windows XP (View menu):**
- Toggle **Tool Box, Color Box, Status Bar, Text Toolbar**
- **Zoom** submenu: Normal Size (1x), Large Size (4x), **Custom** (100/200/400/600/800%), and the Magnifier tool presets (1x/2x/6x/8x)
- **Show Grid** (only at zoom ≥ 4x/400% — a per-pixel grid for pixel editing)
- **Show Thumbnail** (floating thumbnail of the full image while zoomed in)
- **View Bitmap** (full-screen preview of the image; click to exit)

**Windows 7 (View tab):**
- **Zoom group:** Zoom in, Zoom out, 100%; plus a **zoom slider** in the status bar (Ctrl+PageUp / Ctrl+PageDown)
- **Show or hide group:** **Rulers** (Ctrl+R — new in Win7), **Gridlines** (pixel grid, useful when zoomed in), **Status bar**
- **Display group:** **Full screen** (full-screen view of the artwork), **Thumbnail**

New in Win7's view layer: **on-canvas Rulers** (XP had none) and gridlines exposed as a simple checkbox.

## 13. Windows-7-specific additions over XP (consolidated)

- **Scenic Ribbon UI** replacing menus + floating toolbox; Paint-button app menu; Quick Access Toolbar.
- **Brush gallery** of 9 brushes incl. artistic media (Calligraphy 1/2, Oil, Crayon, Marker, Natural pencil, Watercolour) with grayscale-shaded, partially transparent, texture-realistic strokes and "paint runs out" behavior on Oil/Watercolour.
- **Shape gallery** expanded from 4 to **23 shapes**, all **anti-aliased**, remaining **editable/resizable until rasterized** on tool change.
- **Per-shape Outline style and Fill style** dropdowns (solid or any brush texture; or none), plus a unified **Size** thickness control.
- **Anti-aliasing** applied to shapes and artistic brushes (XP output was uniformly aliased/jagged).
- **Resize and Skew** unified dialog with **Pixels OR Percentage** resize and **Maintain aspect ratio** (XP only had percent stretch).
- **Dedicated Crop** button.
- **Undo levels: 50** (vs 3).
- **Rulers** added; gridlines/thumbnail/full-screen exposed cleanly on a View tab.
- **Color 1 / Color 2** naming; ribbon-integrated **Edit colors**.
- **PNG** as the default save format; viewing of transparent PNG/ICO.
- **Transparent selection** toggle (replacing XP's Draw Opaque concept).

## Confidence notes (from the unprimed pass)

The **9-brush** and **23-shape** counts, **3→50 undo**, **28-color XP palette /
16-tool toolbox**, GDI+/PNG/TIFF-in-XP, and the ribbon group layout are all
cross-confirmed across ≥2 sources and are solid. The exact membership of the
Win7 "6 polygon/star" vs "2 symbols" buckets varies slightly by source — the
**23 total** and the presence of triangle/right-triangle/diamond/pentagon/
hexagon/arrows×4/callouts×3/heart/lightning are reliable; the internal
categorization is the one piece to treat as approximate.

## Sources

- [Microsoft Paint — Wikipedia](https://en.wikipedia.org/wiki/Microsoft_Paint)
- [Microsoft Paint — Microsoft Wiki (Fandom)](https://microsoft.fandom.com/wiki/Microsoft_Paint)
- [Microsoft Paint — The Microsoft Windows XP Wiki (Fandom)](https://the-microsoft-windows-xp.fandom.com/wiki/Microsoft_Paint)
- [Paint — The VG Resource Wiki](https://wiki.vg-resource.com/Paint)
- [Paint — BetaWiki](https://betawiki.net/wiki/Paint)
- [Windows 7 Paint — Logo Creation Wiki (Fandom)](https://logocreation.fandom.com/wiki/Windows_7_Paint)
- [Windows 7 Feature Focus: Scenic Ribbon, Paint and WordPad — ITProToday](https://www.itprotoday.com/windows-7/windows-7-feature-focus-scenic-ribbon-paint-and-wordpad)
- [Paint — Windows XP in a Nutshell (O'Reilly)](https://www.oreilly.com/library/view/windows-xp-in/0596009003/re142.html)
- [Shape Tool in MS Paint — Vedantu](https://www.vedantu.com/computer-science/shape-tool-in-ms-paint)
- [Paint Brush in MS Paint — Vedantu](https://www.vedantu.com/computer-science/paint-brush-in-ms-paint)
- [How to Resize a Photo with Windows 7 Paint — groovyPost](https://www.groovypost.com/howto/howto/resize-image-photo-screenshot-with-windows-7-paint/)
- [Selection tools — Lakewood Public Library MS Paint class](https://lkwdpl.org/classes/MSPaint/tools/selection.html)
- [MS Paint Undo/Redo and Zoom — eStudy247](https://estudy247.com/courses/ms-paint/lessons/ms-paint-undo-redo-and-zoom/)
- [Full list of keyboard shortcuts for Microsoft Paint — Winaero](https://winaero.com/the-full-list-of-keyboard-shortcut-for-microsoft-paint/)
- [Use tools and make pictures with Windows Paint (XP)](https://fay.iniminimo.com/paint_xp.html)
- [MSPaint XP Palette — Lospec](https://lospec.com/palette-list/mspaint-xp)
