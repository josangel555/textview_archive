# ViewerCore: Media & Terminal Learnings

**Batch:** ImageEditing (20 files), Terminal (16 files), Audio (14 files), Mermaid (1 file)  
**Total:** 55 Swift files, ~9,044 LOC  
**Date:** 2026-07-11  

---

## Per-File Inventory

### ImageEditing Module (20 files, ~3,095 LOC)

**Sources/ViewerCore/ImageEditing/Renderer.swift** (634 LOC) — Pure, headless image-edit renderer (decode → normalize → replay ops → export). Stateless enum with static methods. Takes `ImageDocument` (source + ops array) → `CGImage`.
- notable: Normalization strategy (premultiplied RGBA8, sRGB) done once at start, all ops replay on canonical format. Shared `CIContext` (TSK-1049) to avoid re-allocating GPU resources per filter. `paintStroke` re-uses the same `RasterCanvas` brush as the live preview (pixel-identical). Coordinate convention centralized in `draw(on:_:)` (top-left origin, pre-flipped context).
- carry: **KEEP** — architecture is clean (pure functions, canonical normalization, lazy base decode). Port to Rust would benefit from the same discipline: normalize once, op-list replay, separate encoding spec from ops.

**Sources/ViewerCore/ImageEditing/ImageDocument.swift** (369 LOC) — Lossless, serializable image-edit document: immutable source + ordered op array. Value type, `Codable`, `Sendable`, `Equatable`. History *is* `ops`; undo = pop, revert = clear.
- notable: `EditOp` enum covers all edits (crop, resize, canvas-size, skew, orient, tonal, paint, shapes, text, curves). Smart `aspectFit` rounding (never collapses to zero, guards non-finite inputs vs `fptosi` runtime traps). `DrawColor` is value type (not `CGColor`) so ops stay `Codable`. Export `ExportSpec` kept separate from ops to avoid lossy quality metadata in the lossless history.
- carry: **KEEP** — elegant separation of lossless (ops) from lossy (export spec). The value-typed, fully-Sendable model enables clean persistence + equality testing. Rebuild should preserve: immutable source, replayable op-list, deterministic render.

**Sources/ViewerCore/ImageEditing/LayeredImageDocument.swift** (348 LOC) — Multi-layer document: ordered stack of `ImageLayer`s, each wrapping a lossless `ImageDocument`. Layer has name, opacity, visibility, blend mode. Own JSON format with version + magic.
- notable: Layers index from bottom ([0]) to top ([last]); blend-mode enum maps to `CGBlendMode`. Each layer re-derives its pixels from its own `source + ops`, so no "baked raster" per layer — the stack composites on render. Visibility/opacity/blend are pure metadata, never contaminate the lossless op-list. `compositingLayers` filter skips hidden/zero-opacity.
- carry: **KEEP** — layer model is clean. Rebuild should apply same: each layer is a full `ImageDocument` (lossless history), metadata (opacity/visibility) separate from pixels.

**Sources/ViewerCore/ImageEditing/RasterCanvas.swift** (444 LOC) — Owned mutable straight-RGBA8 pixel buffer. Top-left origin, row-major, `width·height·4` bytes flat (no row padding). Implements flood-fill, brush dab/stroke, blit, color-pick.
- notable: Straight (un-premultiplied) RGBA internally; premultiply only at `CGImage` boundary. Flood-fill is iterative stack (no recursion) to avoid blowing call stack on large fills. Per-channel tolerance match. Brush dab + swept stroke. Blending uses straight-alpha "source-over" math. Bounds checks are "out-of-bounds is silent no-op" so edge math is simplified.
- carry: **KEEP** — paint engine design is solid. Straight-RGBA + separate premultiply boundary is correct. Iterative flood-fill, tolerance-based matching, source-over blending are standard patterns. Pure pixel math, no graphics framework needed (CGImage bridge only at boundaries).

**Sources/ViewerCore/ImageEditing/VectorOverlay.swift** (398 LOC) — Rendering engine for vector shapes (rect, ellipse, polygon, line, curve) drawn onto a `RasterCanvas`. Handles dashed lines, line joins, stroke width, anti-aliasing. Separate from raster paint (flood fill, brush).
- notable: Geometry to pixel translation (bresenham-style for lines, scanline-fill for polygons). Distinguishes filled vs stroked. Dashed-line phase tracking across segments. Handles degenerate cases (zero-length lines, point sets). Clipping to canvas bounds.
- carry: **KEEP** — solid vector rasterization. The separation from paint (destructive pixel mutations) is clean. Could be ported to Rust or kept as fallback.

**Sources/ViewerCore/ImageEditing/EditUndoStack.swift** (119 LOC) — Helper for undo/redo state management. Tracks a "current" doc + past/future ops arrays.
- notable: Symmetrical push/pop for undo/redo. Clears future on a new edit (standard undo-tree UX). No persistence here (that's the view layer).
- carry: **REDO** — this is thin wrapper logic. Rebuild can absorb into the model or keep as-is if view layer is separated. Not critical to port.

**Sources/ViewerCore/ImageEditing/ImageViewport.swift** (151 LOC) — Geometric state for the canvas viewport (zoom, pan, scroll bounds). Handles viewport-to-canvas coordinate transforms, zoom limits.
- notable: Scroll clamping so the view doesn't pan past the edge. Aspect-ratio-preserving zoom. Zoom center point tracking (so zoom happens under the cursor, not corners).
- carry: **KEEP** — standard viewport math. Port as-is or reimplement if the rebuild uses a different graphics stack.

**Sources/ViewerCore/ImageEditing/GalleryShape.swift** (131 LOC) — Helper for the shape-tool UI: path building, closed-path detection, centroid calculation.
- notable: Tracks points, detects closure (when last point is near the first), computes the weighted centroid for polygon fill center.
- carry: **REDO** — this is UI-adjacent geometry. Rebuild likely has its own shape-tool model; not worth porting as-is.

**Sources/ViewerCore/ImageEditing/DirtyRegion.swift** (71 LOC) — Bounding-box tracking for efficient re-render culling. Tracks a "dirty rect" that encompasses changed pixels.
- notable: Union accumulation (expand the rect to encompass new changes). Reset on resets.
- carry: **REDO** — perf optimization; worth reconsidering for the rebuild depending on whether screen re-render is a bottleneck. May be obsolete if the render engine is Rust-side.

**Sources/ViewerCore/ImageEditing/PaintCoordinateMapping.swift** (32 LOC) — Converts between screen/viewport coordinates and canvas pixel coordinates. Simple transform math.
- carry: **KEEP** — straightforward; rebuild will need this. Depends on viewport state.

**Sources/ViewerCore/ImageEditing/RasterSelection.swift** (104 LOC) — Selection model: boundary path, hit-testing, marching-ants animation. Separate from the canvas — selections are overlays.
- notable: Path is a `[CGPoint]` boundary, closed path. Hit-test uses winding number (point-in-polygon). Animation state (frame index for marching-ants).
- carry: **REDO** — selection is a UI feature. Rebuild likely has its own selection model; not critical to port the swift version.

**Sources/ViewerCore/ImageEditing/SelectionGeometry.swift** (73 LOC) — Geometric queries on a selection: bounding box, resize handles, rotation angle.
- carry: **REDO** — UI-adjacent, rebuild will have its own.

**Sources/ViewerCore/ImageEditing/ShapeDragGeometry.swift** (112 LOC) — Drag-to-build geometry for shapes (rect, circle, line, polygon). Tracks start/current point, computes geometry in real-time.
- carry: **REDO** — UI gesture handling, rebuild will have its own.

**Sources/ViewerCore/ImageEditing/Histogram.swift** (54 LOC) — Histogram computation for tone analysis. Bucket RGB(A) into frequency bins.
- notable: Per-channel histograms. Can be used for exposure analysis UI.
- carry: **KEEP** — pure calculation. Useful for tone tools. Small, easy to port.

**Sources/ViewerCore/ImageEditing/EditOps+Orientation.swift** (97 LOC) — EXIF orientation math. Rotations/flips to bake orientation into pixels.
- notable: Eight cases (EXIF standard), swapAxes flag for 90°/270° cases.
- carry: **KEEP** — correct EXIF math. Useful reference for image metadata handling in the rebuild.

**Sources/ViewerCore/ImageEditing/ImageResizeMath.swift** (32 LOC) — Math for canvas resize operations: aspect-fit, fit-to-box, fill-with-color.
- carry: **KEEP** — straightforward calculations, reusable.

**Sources/ViewerCore/ImageEditing/ImageEditState.swift** (39 LOC) — UI state enum (idle, drawing, selecting, etc.). Tool-mode tracking.
- carry: **REDO** — UI state, rebuild will have its own state machine.

**Sources/ViewerCore/ImageEditing/Exporter.swift** (71 LOC) — Wrapper for `Renderer.render()` + export to file. Handles format detection, error handling.
- carry: **KEEP** — thin glue layer. Rebuild will need something similar.

**Sources/ViewerCore/ImageEditing/BlankImageCreator.swift** (34 LOC) — Create a blank image (fill color, dimensions).
- carry: **KEEP** — trivial utility.

**Sources/ViewerCore/ImageEditing/StandardPalette.swift** (27 LOC) — Predefined color palette.
- carry: **REDO** — rebuild can use its own palette.

**Sources/ViewerCore/ImageEditing/RecentColors.swift** (21 LOC) — LRU list of recently-used colors. No persistence.
- carry: **REDO** — UI state, rebuild can track its own history.

### Terminal Module (16 files, ~3,515 LOC)

**Sources/ViewerCore/Terminal/TerminalScreen.swift** (499 LOC) — Fixed-size character grid with cursor. Pure data structure, `Sendable`, `Equatable`. Coordinate system 0-based (internally).
- notable: Supports scrollback history (bounded, with slack for batch trimming). Alternate screen buffer (for `top`/`vim`/`less`). Pen attributes (SGR). Wide-char (CJK/emoji) support with `isWideTrailer` placeholders. DECSTBM scroll region margins. `plainText()` for accessibility.
- carry: **KEEP** — canonical terminal model. Pure, no I/O, fully testable. Port as-is or re-implement in Rust if the terminal is remote. The scrollback + alt-screen logic is valuable reference.

**Sources/ViewerCore/Terminal/ANSIParser.swift** (490 LOC) — Minimal VT100 escape-sequence parser. Stateful, buffers UTF-8 partial sequences and CSI params. Drives `TerminalScreen` mutations.
- notable: Handles C0 controls (LF, CR, BS, HT), CSI cursor/erase/scroll, SGR (colors, attributes), OSC-7 (cwd), DEC private modes (alt-screen). Buffers split sequences across chunk boundaries. UTF-8 incremental decode with fallback to U+FFFD. Defensive bounds on CSI/OSC buffers. Parses-then-ignores unrecognized sequences (no-op, never crashes).
- carry: **KEEP** — solid parser. V1 scope is well-bounded (intentionally no wide-char width accounting, no mouse input, no DA/DA2 responses). Pure state machine, entirely headless-testable. Port to Rust for remote terminal or keep Swift if local. Good reference for terminal protocol compliance.

**Sources/ViewerCore/Terminal/TmuxControllerCore.swift** (426 LOC) — Pure host-logic core of tmux control-mode (`tmux -CC`) controller. Demuxes `%output` bytes to per-pane `ANSIParser`s, correlates command replies via FIFO, computes routing targets, emits `Effects`.
- notable: Lazy pane-parser allocation (on first output). Reply frame assembly + out-of-order resolution (surfaces dropped commands). Anomaly tracking (frame mismatches, orphan closes, re-opens). No PTY, no AppKit, no dispatch — all edge injection.
- carry: **KEEP** — demux architecture is clean. Inject test events, assert correct parser gets bytes, verify reply correlation. The separation of "PTY spawn + live pump" (VM-tail) from "protocol logic" (host core) is exactly what a rebuild should preserve. Pure, testable, production-grade.

**Sources/ViewerCore/Terminal/TmuxSession.swift** (266 LOC) — Topology model for tmux session: ordered windows, active window/pane, session metadata. State machine driven by `ControlModeEvent`.
- notable: Windows indexed in tab-strip order. `activePaneID` on windows (never bare `Int`). Pane layout tree stored per window. Idempotent `apply(_:)` (re-applying same event is safe).
- carry: **KEEP** — topology is canonical, fully tested. No I/O, pure state machine. Rebuild should preserve exactly this model and testing discipline.

**Sources/ViewerCore/Terminal/TmuxControlParser.swift** (398 LOC) — Parser for tmux control-mode output. Stateful, buffers incomplete lines. Emits typed `ControlModeEvent`s.
- notable: Line-buffered (reads until `\n`). Parses `%output`, `%begin`/`%end`/`%error`, topology events. Handles escaped bytes in output. Defensive against malformed input.
- carry: **KEEP** — parser is solid. Pure state machine. Reference for tmux protocol parsing.

**Sources/ViewerCore/Terminal/TerminalPaneTree.swift** (199 LOC) — Pane layout tree model (recursive, left/right/top/bottom splits). Parsing + flattening queries.
- notable: `PaneNode` is recursive binary tree (leaf = pane, node = split). Flatten to list in document order (L→R, T→B). Geometry calculations (column width, row height).
- carry: **KEEP** — tree model is clean. Geometry calculations are straightforward. Port as-is.

**Sources/ViewerCore/Terminal/TmuxLayoutParser.swift** (247 LOC) — Parser for tmux layout strings (the cryptic `e89e,120x30,0,0[120x15,0,0{60x15,0,0,0,60x15,61,0,1}...` format).
- notable: Recursive descent parser for the split spec. Produces a `PaneNode` tree.
- carry: **KEEP** — parser is the canonical reference for tmux layout syntax. Necessary to preserve if you're using tmux; could be replaced with a simpler custom layout format if you control the protocol.

**Sources/ViewerCore/Terminal/TerminalTabSet.swift** (238 LOC) — Tab stops + wrapping behavior. VT100-style 8-column tabs.
- notable: Default 8-column stops, configurable via CSI sequences.
- carry: **KEEP** — trivial, standard. Keep.

**Sources/ViewerCore/Terminal/TerminalPaneLayout.swift** (189 LOC) — Computed geometry for a pane within its split layout. Pixel dimensions, scroll indicators.
- carry: **KEEP** — straightforward coordinate transforms. Rebuild will need.

**Sources/ViewerCore/Terminal/TerminalSelection.swift** (140 LOC) — Text selection model (anchor, extent, selection rect). Hit-testing within a pane.
- carry: **KEEP** — pure data structure. Port as-is.

**Sources/ViewerCore/Terminal/TerminalCell.swift** (125 LOC) — One cell of the terminal grid. Char + SGR attributes (bold, underline, colors, wide-char flag).
- notable: Attributes are a bitmask (fg/bg color, bold, underline, inverse, wide-trailer flag). `isWideTrailer` for CJK/emoji trailing column.
- carry: **KEEP** — simple value type, essential to the grid model.

**Sources/ViewerCore/Terminal/AnsiColorResolver.swift** (86 LOC) — Maps ANSI color codes (0-7, 16-255, truecolor) to NSColor. Caches resolved colors.
- notable: Predefined ANSI palette, 256-color cube computation, truecolor passthrough.
- carry: **KEEP** — color mapping is reusable. Rebuild will need similar logic.

**Sources/ViewerCore/Terminal/TerminalKeyEncoder.swift** (102 LOC) — Encodes keyboard input (modifier combinations + keys) to VT100/xterm escape sequences. e.g. Ctrl+A → `\x01`.
- notable: Handles modifiers (shift, option, control, cmd). Maps special keys (arrows, function keys, home/end) to escape sequences. Terminal app expects these.
- carry: **KEEP** — protocol encoding. Essential for PTY interaction. Good reference.

**Sources/ViewerCore/Terminal/TerminalOSC7.swift** (106 LOC) — Parser for OSC-7 sequences (the modern `file://…` current-working-directory report). Extracts URL, decodes to `URL`.
- carry: **KEEP** — straightforward URI parsing. Useful for session restoration (TSK-341: restore tab in the directory the user left off in).

**Sources/ViewerCore/Terminal/TerminalScrollbar.swift** (38 LOC) — Scrollbar state (thumb position, size) for a terminal pane with scrollback.
- carry: **KEEP** — simple geometry.

**Sources/ViewerCore/Terminal/FrameThrottle.swift** (64 LOC) — Throttle render calls. Allows updates up to ~60 Hz (on a 16 ms interval).
- carry: **REDO** — perf tuning. Rebuild may use different throttle strategy (e.g., debounce vs frame rate). Depends on rendering infrastructure.

**Sources/ViewerCore/Terminal/TmuxCommand.swift** (379 LOC) — Tmux command model + FIFO queue for correlating replies. Serializable command format.
- notable: Wraps command string + metadata. Queue is a FIFO with command numbering (monotonic, starting at 0).
- carry: **KEEP** — command correlation is essential for tmux protocol. Keep the FIFO discipline.

### Audio Module (14 files, ~1,600 LOC)

**Sources/ViewerCore/Audio/AudioExporter.swift** (274 LOC) — Encode `AudioPCMBuffer` to file (WAV/AIFF/CAF/AAC/MP3). Native AVFoundation for PCM/AAC, external `ffmpeg` for MP3.
- notable: Separation of lossless PCM vs lossy format (quality knob separate from edit ops). MP3 encoded via best-effort host ffmpeg lookup (never bundled). Error cases: empty buffer, ffmpeg not found, ffmpeg failed. Intermediate WAV for MP3 transcode.
- carry: **KEEP** — export architecture is clean. Separation of format (export-only) from edits (ops-only) mirrors image module. MP3 via external tool is pragmatic. Error handling is complete.

**Sources/ViewerCore/Audio/AudioDocument.swift** (149 LOC) — Audio edit document: source (URL or Data) + replayable edit ops. Mirrors `ImageDocument` design.
- notable: Immutable source, mutable ops array. History = ops. Undo via pop, revert via clear.
- carry: **KEEP** — same value-typed, Sendable, Codable discipline as ImageDocument. Port design as-is.

**Sources/ViewerCore/Audio/AudioDecoder.swift** (69 LOC) — Decode audio file to `AudioPCMBuffer`. Uses AVAudioFile.
- carry: **KEEP** — straightforward. Keep.

**Sources/ViewerCore/Audio/AudioPCMBuffer.swift** (89 LOC) — Owned float32 PCM buffer (channels + sample rate). Interleaved or split-channel access.
- notable: Multi-channel, float32 (the working format). Bridging layer between AVAudioFile and edit ops.
- carry: **KEEP** — essential data structure. Port as-is.

**Sources/ViewerCore/Audio/AudioWaveform.swift** (151 LOC) — Compute a visual waveform from PCM (peak/RMS per bin for zoom levels). Used by the waveform display.
- notable: Multi-scale (binned for different zoom levels). Peak + RMS per bin. Caching strategy (computed once, stored).
- carry: **KEEP** — useful for UI rendering. Pure computation. Keep.

**Sources/ViewerCore/Audio/SpectrumAnalyzer.swift** (104 LOC) — Compute frequency-domain spectrum via FFT. Used by the spectrum view.
- notable: VDSP-based FFT. Power spectrum computation.
- carry: **KEEP** — solid signal processing. Useful reference.

**Sources/ViewerCore/Audio/AudioTrimFade.swift** (70 LOC) — Edit ops for trim + fade-in/fade-out. Time-based frame ranges.
- carry: **KEEP** — simple edits, reusable.

**Sources/ViewerCore/Audio/AudioExportSettings.swift** (103 LOC) — Export format + quality spec. Mirrors `ExportSpec` pattern from images.
- carry: **KEEP** — straightforward. Keep the separation of export from ops.

**Sources/ViewerCore/Audio/FFmpegLocator.swift** (87 LOC) — Best-effort locate host `ffmpeg` executable. Searches PATH, respects override (Settings).
- notable: No bundling or vendoring — external tool only. Graceful fallback (MP3 disabled if not found).
- carry: **KEEP** — pragmatic, minimal-dependency approach. Rebuild should adopt same philosophy for optional external tools.

**Sources/ViewerCore/Audio/FFmpegGuidance.swift** (35 LOC) — Helper documentation (not used runtime) for ffmpeg args.
- carry: **REDO** — just docs/comments. Rebuild can add its own.

**Sources/ViewerCore/Audio/AudioUnitDescriptor.swift** (160 LOC) — Metadata for AU plug-ins (name, in/out ports, properties). Reflection layer for the AU SDK.
- carry: **REDO** — AU-specific. Rebuild may use a different plugin architecture or omit plugins entirely.

**Sources/ViewerCore/Audio/AudioUnitInventory.swift** (98 LOC) — Enumeration of available AU plugins on the system.
- carry: **REDO** — AU-specific infrastructure. Rebuild may omit.

**Sources/ViewerCore/Audio/MIDISourceInventory.swift** (119 LOC) — Enumeration of MIDI sources + monitoring for connect/disconnect. Used by MIDI input tools.
- carry: **REDO** — MIDI-specific. Rebuild may omit if not shipping MIDI support.

**Sources/ViewerCore/Audio/WaveformReducer.swift** (75 LOC) — Downsample waveform data for efficient rendering at different zoom levels.
- carry: **KEEP** — useful for UI perf. Pure calculation.

### Mermaid Module (1 file, ~108 LOC)

**Sources/ViewerCore/Mermaid/MermaidSourceParser.swift** (108 LOC) — Parse mermaid-source directive comments (`%% @id <slug>`, `%% @step N`). Produces JSON metadata for the JS shim.
- notable: Pure parsing. Deterministic `sortedKeys` JSON encoding. SHA-256 short-hash fallback for diagram IDs. Integration with walkthrough drivers (stable `data-mdv-id` targeting).
- carry: **KEEP** — small, clean, useful for interactive diagram features. Keep as-is.

---

## Module Summary

### What This Slice Does

**ImageEditing:** Lossless, replayable image edit engine. One immutable source + ordered op-array. Renderer pipeline: decode → normalize (premultiplied RGBA8, sRGB) → apply ops sequentially. Separate raster paint (flood fill, brush) from vector shapes (polygons, lines, curves). Export format separate from ops (no lossy metadata in history). Multi-layer support.

**Terminal:** Pure host-logic terminal emulator. VT100-compatible screen buffer (character grid + cursor + SGR attributes + scrollback + alt-screen). ANSI parser (handles printables, C0 controls, CSI, OSC-7, DEC private modes). Tmux control-mode protocol: demux output to panes, correlate command replies, topology state machine. Pane layout tree parsing. Selection, key encoding, OSC-7 cwd tracking.

**Audio:** Lossless audio edit engine (mirrors image module design). Source + edit ops. Decoding via AVAudioFile, float32 PCM working format. Export to WAV/AIFF/CAF/AAC (native) or MP3 (via external ffmpeg). Waveform computation for UI. Spectrum analysis (FFT). Trim/fade edits. Optional AU plugin + MIDI support.

**Mermaid:** Minimal parser for diagram metadata directives. Produces stable JSON for JS integration.

### Architectural Patterns Worth Porting

1. **Immutable Source + Replayable Ops**
   - `ImageDocument(source, ops)`, `AudioDocument(source, ops)`. History *is* ops.
   - Undo/redo/revert are trivial (pop/clear).
   - Render is pure function of `(source, ops)` — deterministic, testable, resumable.
   - **Port this pattern to any rebuild dealing with media.**

2. **Canonical Normalization (Image)**
   - Decode source to arbitrary format → normalize once to known format (premultiplied RGBA8, sRGB) → all ops operate on canonical raster.
   - Eliminates downstream code that has to reason about exotic formats.
   - **Strong pattern; apply to other media types.**

3. **Separate Encoding Spec from Ops**
   - `EditOp` = lossless geometry/samples; `ExportSpec` = lossy encoding (quality, container).
   - No quality metadata in history; re-render is always pixel-deterministic.
   - **Essential for lossless edit histories; apply broadly.**

4. **Pure State Machines with Typed Events**
   - `ANSIParser`, `TmuxControlParser`, `TmuxSession.apply(ControlModeEvent)`.
   - Immutable state, `Sendable`, Equatable, fully host-testable.
   - **Excellent pattern for any protocol or choreography logic.**

5. **Lazy Allocation + Snapshot Discipline**
   - `TmuxControllerCore` allocates `ANSIParser` per pane on first output.
   - View reads snapshot under a lock; no live mutations.
   - **Reusable for any producer/consumer with bursty I/O.**

6. **Demux + Correlation via FIFO**
   - Tmux protocol: command reply frames can arrive out of order. FIFO queue keeps commands + replies aligned.
   - Surfaces anomalies (dropped, mismatched, orphan frames) explicitly.
   - **General-purpose pattern for any request/response protocol.**

7. **Defensive Bounds + Graceful Degradation**
   - CSI/OSC buffers capped; overrun is bounded, not infinite.
   - Out-of-bounds pixel access is silent no-op (not crash).
   - Malformed UTF-8 → U+FFFD fallback.
   - **Quality signal; apply to all input parsing.**

8. **Value Types + Codable Serialization**
   - `ImageDocument`, `AudioDocument`, `LayeredImageDocument` are value types, `Sendable`, `Codable`, `Equatable`.
   - Full round-trip to JSON with version + magic discriminator.
   - **Essential for persistence + multi-process safety.**

9. **Stateful Parser Boundary Handling**
   - `ANSIParser` buffers UTF-8 and CSI params across chunk boundaries.
   - No corruption on arbitrary split points.
   - **Necessary for any streaming protocol.**

10. **Wide-Character Support (Terminal)**
    - CJK/emoji 2-column glyphs tracked via `isWideTrailer` placeholders.
    - `displayWidth()` conservative lookup.
    - Rebuild should preserve; correctness for non-ASCII is a surprise win.

### Anti-Patterns / Regrets

1. **Image Editing as Swift-Only**
   - The renderer (Renderer, RasterCanvas, VectorOverlay) are pure computation — should have been Rust from day one (WASM-portable, faster, FFI-ready).
   - Rebuild: move pixel-math to Rust core; Swift layer is just I/O + view bindings.

2. **AU + MIDI Plugins (Audio)**
   - AU enumeration + MIDI source enumeration are macOS-specific, add complexity.
   - Audio edits themselves (trim, fade) are portable; the plugin infrastructure is a special case.
   - Rebuild: separate core audio ops (portable) from plugin system (optional, platform-specific).

3. **Terminal as macOS-Only**
   - ANSIParser + TerminalScreen are pure logic but live in a Swift app only.
   - Rebuild: move to Rust core so it's reusable for WebUI/TUI/remote (TSK-1018 intent).

4. **OSC-7 Parsing Incomplete**
   - Current parser extracts URL; doesn't validate or fully deserialize.
   - Rebuild: make OSC-7 cwd restoration more robust (TSK-341 future work).

5. **No Signal Processing Abstractions (Audio)**
   - Waveform + spectrum are one-off computations, not part of a reusable signal pipeline.
   - Rebuild: if audio editing grows, consider a more general signal-flow model.

6. **DirtyRegion Culling (Image)**
   - Bounding-box re-render optimization added but never fully integrated.
   - Rebuild: either fully instrument or omit (depends on whether render becomes a bottleneck on Rust).

7. **TextDrawing Coords (Image)**
   - Text rendering uses different coordinate conventions than shapes/paint in places.
   - Rebuild: enforce single top-left-origin convention everywhere; no exceptions.

### Gotchas & Surprises

1. **CGContext Premultiply Convention**
   - CGContext is happiest drawing into premultiplied BGRA little-endian (on Apple silicon).
   - Mismatch = silent wrong results (not crashes). Normalize once, all ops replay on canonical format (correct pattern).

2. **UTF-8 Across Chunk Boundaries**
   - A 4-byte UTF-8 char can split across two feed() calls.
   - ANSIParser carries `utf8Pending`; loses or corrupts without it.

3. **Image Aspect-Fit NaN Trap**
   - `Int(NaN)` is a hard LLVM fptosi overflow trap (signal 11).
   - `aspectFit` guards with `isFinite` before conversion (correct).
   - Rebuild: centralize all CGFloat→Int conversions; defend against NaN/Inf always.

4. **Tmux Reply Frames Out-of-Order**
   - A later command's reply can arrive before an earlier one.
   - FIFO-based correlation necessary; naive indexing-based pairing fails silently.
   - Rebuild: if using any request/response protocol, assume out-of-order arrivals.

5. **Terminal Scrollback Memory Pressure**
   - Unbounded scrollback kills the app on long-running sessions.
   - TSK-735 adds scrollbackSlack batch-trim strategy (defer trimming to batch boundaries).
   - Rebuild: apply same batching; don't trim after every scrolled line.

6. **Flood-Fill Recursion Stack**
   - Naive recursive flood fill blows call stack on ~4000×4000 uniform regions (~16M deep).
   - RasterCanvas uses iterative stack (correct, proven).

7. **Wide-Char Alignment**
   - A 2-column emoji's second column is a placeholder (`isWideTrailer`).
   - Copy/paste/selection that doesn't skip trailers produces garbled text.
   - TerminalScreen.plainText() and accessibility paths must filter trailers.

8. **CIContext Thread-Safety Assertion**
   - CIContext is documented thread-safe but not `Sendable` (Swift 6).
   - Renderer uses `nonisolated(unsafe)` to work around; VM 6.3 stricter than host 6.1.2.

9. **Export Format & Bit Depth**
   - JPEG/HEIC are lossy (quality applies); PNG/BMP/GIF/TIFF lossless (quality ignored).
   - ExportSpec correctly distinguishes via `isLossy`; easy to get wrong.

10. **Pane Geometry via Split Syntax**
    - Tmux's layout string is cryptic (`e89e,120x30,0,0{...}`).
    - TmuxLayoutParser correctly decodes; rebuild needs equivalent or custom simpler format.

### Rebuild Notes

#### If Building a Fresh Image Editor

1. **Start with the op-list discipline.** Immutable source, replayable ops, separate export spec. This buys you lossless history + deterministic renders + easy undo.
2. **Move pixel-math to Rust.** Renderer, RasterCanvas, VectorOverlay should be Rust (WASM-portable, ~5-10x faster for big images). Swift layer: I/O + SwiftUI view bindings only.
3. **Normalize once.** Premultiplied RGBA8, sRGB. All ops replay on canonical format.
4. **Lazy base decode** (TSK-1051): decode source once, cache, reuse across renders.
5. **Shared CIContext** (TSK-1049): one context for all filter ops, not per-op.
6. **Paint ops separate from geometry ops.** Paint is destructive (rewriting pixels), not replayable. Keep it outside the op-list; live preview uses RasterCanvas, committed stroke becomes an EditOp.
7. **Layer model:** Each layer is its own `ImageDocument`; layer metadata (opacity, blend mode, visibility) is pure UI state, never contaminates history.
8. **Color precision:** DrawColor is a value type (not CGColor) so ops stay Codable. Premultiply only at boundaries.

#### If Building a Terminal / Tmux UI

1. **Pure state machine for protocol logic.** ANSIParser, TmuxControlParser, TmuxSession are all `Sendable`, testable, independent of I/O.
2. **Move to Rust** if the terminal needs to be remote (WebUI, TUI, non-macOS). This project proved the architecture works host-side; Rust version would be portable + faster.
3. **Pane layout tree:** Don't assume a simpler layout format. Tmux's `{|, -, @}` syntax is compact; if you control the protocol, design carefully (custom format can be simpler).
4. **Scrollback batching:** Don't trim after every scrolled line. Batch accumulate + trim at boundaries (FrameThrottle + scrollbackSlack pattern).
5. **UTF-8 state machine:** Buffer incomplete multibyte sequences across boundaries.
6. **Command correlation:** If you have a request/response protocol, assume replies arrive out of order. FIFO queue + explicit anomaly tracking.
7. **ANSI compliance:** The scope (C0, CSI, SGR, DEC private modes, OSC-7) is good; anything beyond is a follow-up. Don't extend indefinitely; bound it.
8. **Wide-char support:** Optional but worth it for non-ASCII users. `displayWidth()` lookup + `isWideTrailer` placeholders.

#### If Building Audio Editor

1. **Same op-list discipline as images.** Source + edits = lossless history.
2. **Float32 working format.** AVAudioFile normalizes to float32 (the golden mean between precision + perf).
3. **Export spec separate from ops.** MP3 quality / WAV bit depth / AAC bitrate = export-only, not part of edit history.
4. **Waveform for UI:** Compute once, cache, offer multiple zoom levels (bin sizes).
5. **Optional external tools gracefully.** MP3 via ffmpeg lookup (not bundled). If not found, feature disabled (no crash).
6. **Avoid AU plugin complexity unless shipping it.** Core audio edits (trim, fade, basic EQ) are simpler without plugin infrastructure.

#### If Building Mermaid Integration

1. **Parser is trivial.** `%% @id` and `%% @step` directives are optional metadata; diagram itself runs without them.
2. **Stable diagram IDs:** Needed for walkthrough drivers to target specific diagrams across re-renders.
3. **Step annotations:** Useful for progressive reveal / tutorial walkthroughs.
4. **JSON determinism:** Sorted keys ensure reproducible output (good for tests + diffs).

---

## File-Level Carry Decision Summary

### KEEP (Port as-is or adapt)
- **Image Core:** Renderer, ImageDocument, LayeredImageDocument, RasterCanvas, VectorOverlay, Histogram, EditOps+Orientation, ImageResizeMath, PaintCoordinateMapping, Exporter, BlankImageCreator
- **Terminal Core:** TerminalScreen, ANSIParser, TmuxControllerCore, TmuxSession, TmuxControlParser, TerminalPaneTree, TmuxLayoutParser, TerminalTabSet, TerminalPaneLayout, TerminalSelection, TerminalCell, AnsiColorResolver, TerminalKeyEncoder, TerminalOSC7, TerminalScrollbar, TmuxCommand
- **Audio Core:** AudioExporter, AudioDocument, AudioDecoder, AudioPCMBuffer, AudioWaveform, SpectrumAnalyzer, AudioTrimFade, AudioExportSettings, FFmpegLocator, WaveformReducer
- **Mermaid:** MermaidSourceParser

### REDO (Rebuild-specific, not worth porting as-is)
- **Image UI State:** ImageEditState, GalleryShape, DirtyRegion, RasterSelection, SelectionGeometry, ShapeDragGeometry, StandardPalette, RecentColors, EditUndoStack, ImageViewport
- **Terminal Perf:** FrameThrottle
- **Audio Plugins:** AudioUnitDescriptor, AudioUnitInventory, MIDISourceInventory
- **Docs:** FFmpegGuidance

---

**Total KEEP:** 38 files (~6,000 LOC)  
**Total REDO:** 17 files (~3,000 LOC)

The rebuild should port the KEEP slice wholesale (or adapt minimally to a different graphics/audio stack), and author new REDO implementations tailored to the new UI framework + product decisions.
