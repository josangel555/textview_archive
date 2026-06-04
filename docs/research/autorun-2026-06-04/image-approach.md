I have everything I need. Returning the architecture recommendation.

---

# In-App Image Editor Architecture — Native macOS (CoreGraphics/CoreImage/vImage/ImageIO)

## 1. Core data model: immutable op-list, **not** a layer stack (yet)

For P0 (resize/crop/recompress) a layer stack is over-engineered. Use an **immutable, append-only document model where the editing state is a value type and rendering is a pure function of `(source, ops)`**. This is the model that survives the later jump to layers/vector because the document becomes one *node* in a future graph.

```
ImageDocument (value type, Sendable)
├── source: SourceRef            // immutable handle to the loaded original
│   ├── url / data
│   ├── pixelSize: CGSize        // native, pre-orientation
│   ├── orientation: CGImagePropertyOrientation  // EXIF, applied lazily
│   ├── declaredUTType: UTType   // public.jpeg / .png / .heic
│   └── metadata: [CFString: Any] (snapshot for export)
├── ops: [EditOp]                // ordered, immutable op-list (the edit recipe)
└── exportSettings: ExportSpec   // format + quality, NOT an op
```

```swift
enum EditOp: Equatable, Codable, Sendable {
    case resize(to: PixelSize, fit: ResizeFit, resampler: Resampler)
    case crop(rect: PixelRect)                 // in source-pixel space, post-prior-ops
    case orient(CGImagePropertyOrientation)    // bake EXIF rotation into pixels
    // later: .brushStroke, .fill, .layerComposite … each is just another case
}
```

**Why op-list over a mutable "current CGImage":**
- **Non-destructive history + revert fall out for free.** History *is* `ops`. Undo = drop the tail (`ops.dropLast()`); revert = `ops = []`. No snapshot diffing, no command-pattern bookkeeping. The whole document is `Codable` → you get session persistence and `.editrecipe` sidecar files almost for nothing.
- **The source is never mutated.** Revert is always lossless back to the original bytes, even after a recompress — because recompress is an `exportSettings` choice, not a destructive pixel op.
- **Testability** (see §3): the render pipeline is `func render(_ doc) -> CGImage` — a pure function. No UI, no state.

### Crucial separation: render space vs export
Keep two distinct stages:

```
render(doc):  source CGImage  → apply ops in order → composited CGImage (RGBA, working colorspace)
export(img):  composited CGImage + ExportSpec → encoded Data (via ImageIO)
```

Recompress/quality is **export-only** and must *not* be an `EditOp` — otherwise "revert" can't get you back to lossless, and re-encoding would stack generational JPEG loss into history. Quality is a property of the output, not of the edit.

### Coordinate-space discipline (the thing that bites everyone)
Pick **one** canonical space and document it: *source pixels, orientation already normalized*. Bake EXIF orientation as the implicit first op (`orient`) so every subsequent `crop`/`resize` rect is in upright pixel coordinates. CoreGraphics is y-up, AppKit views are y-up, but `CGImage`/ImageIO rows are top-down — pick top-left origin for the model's `PixelRect` and convert at the CG boundary only. Most crop bugs are a flipped origin here.

### Why this scales to layers later
When layers arrive, `ImageDocument.source` generalizes to `nodes: [LayerNode]` and `EditOp` stays as a per-layer op-list. The composite step becomes a tree walk instead of a linear fold. The export stage is untouched. Vector later is just a `LayerNode` kind that rasterizes on demand. You don't repaint yourself into a corner by starting linear.

---

## 2. macOS APIs per P0 op

| Op | API | Notes |
|---|---|---|
| **Load** | `ImageIO` — `CGImageSourceCreateWithURL` → `CGImageSourceCreateImageAtIndex`. Pull `kCGImagePropertyOrientation` + full metadata via `CGImageSourceCopyPropertiesAtIndex`. | Do **not** decode through `NSImage` — it loses control over orientation/colorspace and silently re-renders. Keep the raw `CGImage` + metadata dict. |
| **Resize** | `vImageScale_ARGB8888` (Accelerate). For HQ downscale use `kvImageHighQualityResampling`. | vImage gives the crispest result and is fastest/lowest-memory for the simple "scale to N×M" case (search consensus: sharper than CoreGraphics, less artificial than CoreImage). Path: `CGImage → vImage_Buffer` via `vImageBuffer_InitWithCGImage` → scale → `vImageCreateCGImageFromBuffer`. Pin the format to a known `vImage_CGImageFormat` (premultiplied RGBA8, sRGB) so input variety (gray, CMYK, 16-bit) normalizes. |
| | *Alternative:* `CILanczosScaleTransform`. | Better when you want resize fused with other CIFilters in one GPU pass (relevant once paint/effects land). For P0 standalone resize, vImage wins on simplicity + determinism (CI render can be GPU-nondeterministic across machines — bad for golden-image tests). |
| **Crop** | `CGImage.cropping(to: CGRect)`. | Zero-copy — returns a view into the same backing store, no re-encode, no resample. Clamp the rect to bounds first (out-of-bounds returns `nil`). Apply crop *before* resize when both present, so you don't resample pixels you're about to discard. |
| **Recompress / quality / format** | `ImageIO` — `CGImageDestinationCreateWithData(_, UTType.X.identifier as CFString, 1, nil)` → `CGImageDestinationAddImage(dest, img, opts)` → `CGImageDestinationFinalize`. | One code path for all three formats; format is just the destination UTI. (See §4.) |

**vImage format normalization is the unglamorous core.** Real-world inputs are gray, indexed, CMYK, 16-bit, P3/Adobe-RGB, alpha/no-alpha. Build one `vImageConverter` to a canonical working format at load. Every downstream op then assumes RGBA8 sRGB premultiplied. This single normalization step removes ~80% of "works on my image, crashes on yours" bugs.

---

## 3. Headless testability (the design constraint, not an afterthought)

Because render and export are **pure functions over a `Codable` value type**, the entire engine is testable with zero UI, zero window, zero GPU session — it runs in the plain `swift test` headless gate.

```
ViewerCore (engine, no AppKit/SwiftUI import)
  ├─ ImageDocument, EditOp, ExportSpec        // pure value model
  ├─ Renderer.render(_ doc) -> CGImage        // vImage + CG, deterministic
  └─ Exporter.encode(_ img, _ spec) -> Data   // ImageIO
ViewerUI (depends on ViewerCore)
  └─ NSImageView/SwiftUI canvas, history UI   // dumb, calls into core
```

Keep `ViewerCore` free of any `import AppKit/SwiftUI`. CoreGraphics/CoreImage/vImage/ImageIO are all headless-safe — no WindowServer, so these tests are **T1 headless tier**, not the heavy T4/T5 VM lanes. This matches the project's existing tier discipline in `CLAUDE.md`.

### Three assertion layers, cheap → strong

1. **Dimensions / structural** — fast, exact, no fuzz:
   ```swift
   let out = Renderer.render(doc)
   XCTAssertEqual(out.width, 800); XCTAssertEqual(out.height, 600)
   // crop+resize math, aspect-fit rounding, orientation swap (portrait EXIF flips W/H)
   ```

2. **Pixel samples** — read back specific pixels from the rendered `CGImage` into a `CGContext`-backed buffer and assert with a tolerance (resamplers differ by ±1 LSB across OS versions, so use `abs(Δ) <= ε`, not `==`):
   ```swift
   func sampleRGBA(_ img: CGImage, _ x: Int, _ y: Int) -> (UInt8,UInt8,UInt8,UInt8)
   // Synthetic fixtures with known colors: a 4-quadrant image →
   // crop to top-left quadrant → assert center pixel == that quadrant's color.
   // Solid-fill resize → assert corners unchanged (no edge-bleed).
   ```
   Synthetic, programmatically-drawn fixtures (draw a known pattern into a `CGContext`) beat shipping binary test images — they're diffable in git, self-documenting, and pin exact expected values.

3. **Encoded-bytes / round-trip** — for export:
   - **Header/structural:** re-open exported `Data` with `CGImageSourceCreateWithData`, assert `CGImageSourceGetType` == expected UTI, assert pixel dims survived, assert orientation tag written, assert chosen metadata preserved/stripped.
   - **Quality monotonicity:** encode same image at q=0.3, 0.6, 0.9 → assert `bytes(0.3) < bytes(0.6) < bytes(0.9)`. Robust across OS versions without hardcoding exact byte counts (which drift with codec updates).
   - **PNG determinism:** PNG is lossless → assert decode(encode(img)) == img exactly (no tolerance). Good canary for colorspace drift.
   - **Avoid** asserting exact JPEG/HEIC byte counts or hashes — codec versions change them. Assert *properties* (size ordering, decoded-pixel similarity within PSNR/ε), not byte identity.

### Test the model laws, not just outputs
- **Undo/redo invariant:** `render(doc.appending(op).droppingLast()) ≡ render(doc)` (pixel-equal).
- **Revert:** `doc.reverted().ops.isEmpty` and `render` equals the orientation-normalized source.
- **Codable round-trip:** `decode(encode(doc)) == doc` — protects session persistence.
- **Op commutativity/ordering:** crop-then-resize vs resize-then-crop produce *documented* different results; pin the chosen order with a test so a refactor can't silently swap it.

---

## 4. Export / encoding

Single ImageIO path for all three formats — format is the destination UTI, quality is one option key:

```swift
struct ExportSpec: Codable, Sendable {
    enum Format: Codable { case jpeg, png, heic }
    var format: Format
    var quality: Double          // 0…1; ignored for PNG
    var stripMetadata: Bool
    var embedColorProfile: Bool
}

func encode(_ image: CGImage, _ spec: ExportSpec, sourceMeta: [CFString: Any]) throws -> Data {
    let uti: UTType = switch spec.format {
        case .jpeg: .jpeg; case .png: .png; case .heic: .heic
    }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, uti.identifier as CFString, 1, nil)
    else { throw ExportError.destinationCreate }

    var opts: [CFString: Any] = [:]
    if spec.format != .png {                       // PNG ignores it; JPEG+HEIC honor it
        opts[kCGImageDestinationLossyCompressionQuality] = spec.quality   // 0.1 max-compress … 1.0 lossless-if-supported, default ~0.76
    }
    if let o = sourceMeta[kCGImagePropertyOrientation] {
        opts[kCGImageDestinationOrientation] = o   // write tag, don't double-rotate pixels
    }
    // metadata: pass kCGImageDestinationMetadata to carry/merge EXIF/XMP; omit to strip.

    CGImageDestinationAddImage(dest, image, opts as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw ExportError.finalize }
    return data as Data
}
```

Key facts that shape the code:
- **HEIC** is a first-class ImageIO destination on macOS (`public.heic`); same `kCGImageDestinationLossyCompressionQuality` key as JPEG. Encoding is notably slower than JPEG — do it off the main thread and show progress for large images.
- **PNG** ignores lossy quality; it's always lossless. So `quality` in the UI should disable/grey-out for PNG. Don't fake a "PNG quality" slider.
- **Orientation:** if you baked orientation into pixels (the `orient` op), write orientation = `.up` and don't also copy the source's rotation tag, or you'll double-rotate. Pick one strategy; the cleaner one for an *editor* is **bake into pixels** (upright canvas) so crop/paint coordinates are sane, then export with orientation `.up`.
- **Metadata-only fast path (later optimization):** `CGImageDestinationCopyImageSource` copies original bytes and rewrites only metadata — lets a "change EXIF / no pixel edits" save avoid a generational re-encode entirely. Worth wiring once you notice users re-saving unedited files.
- **Color profile:** decide explicitly whether to embed the working sRGB profile. For fidelity, embed; for smallest files, strip and assume sRGB. Make it an `ExportSpec` flag, defaulted to embed.

---

## 5. Smallest valuable first slice + automated validation

**First slice = the engine spine end-to-end, narrowest possible op set, zero UI:**

> **Load a JPEG → apply `[crop, resize]` → export as JPEG at chosen quality → bytes back to disk.**

Concretely the v0 deliverable is `ViewerCore` with:
1. `ImageDocument` value model + `EditOp.crop` + `EditOp.resize` + `ExportSpec`.
2. `Renderer.render` (crop via `cropping(to:)` → resize via `vImageScale_ARGB8888`), with the format-normalization converter.
3. `Exporter.encode` (ImageIO, JPEG path first).
4. Append/undo/revert as pure `ImageDocument` transforms.

This is "smallest valuable" because it exercises **every architectural seam** — immutable model, pure render, ImageIO export, history — on the simplest ops. PNG/HEIC are then a one-line UTI addition each; paint/layers slot into `EditOp`/`LayerNode` without touching the spine.

### Automated validation gate for v0 (all T1 headless)
```
✓ resize(800×600 → 400×300) ⇒ rendered CGImage is exactly 400×300
✓ aspect-fit resize of 1000×500 into 400×400 box ⇒ 400×200 (rounding pinned)
✓ portrait-EXIF source normalizes ⇒ rendered W/H swapped vs raw pixel W/H
✓ crop top-left quadrant of a 4-color synthetic ⇒ center sample == that color (±ε)
✓ solid-fill resize ⇒ corner samples unchanged (no bleed) (±ε)
✓ export JPEG @ {0.3,0.6,0.9} ⇒ byte sizes strictly increasing
✓ export PNG ⇒ decode(encode(img)) == img exactly (lossless canary)
✓ re-open exported data ⇒ CGImageSourceGetType == expected UTI, dims preserved
✓ undo law: render(doc+op−op) == render(doc)
✓ revert: ops empty, render == orientation-normalized source
✓ Codable round-trip: decode(encode(doc)) == doc
```

These run in the existing `bash scripts/test-headless-gate.sh` host gate — no window, no GPU session, no VM. Fixtures are programmatically drawn, so no binary blobs in the repo.

---

### Two flags worth surfacing now (cheap to design in, expensive to retrofit)
- **Memory for large images.** A 50 MP RGBA8 buffer is ~200 MB; resize + crop holding multiple intermediates multiplies that. vImage lets you scale into a pre-sized destination buffer (one alloc) and `cropping(to:)` is zero-copy — lean on both. Render lazily on a background queue with a downscaled *preview* proxy for the live canvas, full-res only on export. Don't hold every history step's rendered bitmap — history is the cheap `[EditOp]` recipe; re-render on demand (and memoize only the *current* result).
- **Determinism for golden tests.** Prefer vImage/CoreGraphics over CoreImage on the *tested* paths — CI GPU rendering can vary across hardware. If/when CoreImage enters the pipeline (paint, filters), force the CPU software renderer (`CIContext(options: [.useSoftwareRenderer: true])`) in tests for reproducible pixels, and keep tolerances on sampled assertions.

---

Sources:
- [vImageScale_ARGB8888 — Apple Developer Documentation](https://developer.apple.com/documentation/accelerate/1509266-vimagescale_argb8888)
- [vImage Image scaling — Apple Developer Documentation](https://developer.apple.com/documentation/accelerate/vimage/vimage_operations/image_scaling)
- [Image Resizing Techniques — NSHipster](https://nshipster.com/image-resizing/)
- [CGImageDestination — Apple Developer Documentation](https://developer.apple.com/documentation/imageio/cgimagedestination)
- [QA1895: Modifying Image Metadata Without Recompressing Image — Apple](https://developer.apple.com/library/archive/qa/qa1895/_index.html)
- [Working with Image Destinations — Apple ImageIO Guide](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/ImageIOGuide/ikpg_dest/ikpg_dest.html)
- [TestAppleHEICEncoding — ImageIO HEIC/HEIF encoding test](https://github.com/dreampiggy/TestAppleHEICEncoding)