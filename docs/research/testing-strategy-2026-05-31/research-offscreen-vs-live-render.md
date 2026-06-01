This is a research question about macOS rendering internals — no code task, no repo investigation needed. The user wants a thorough, first-principles answer. Let me think carefully and write it directly. I won't fabricate tool calls or research files; this is domain knowledge I can answer directly, and I'll be candid about limits.

# Off-Screen Rendering vs. Live Compositor on macOS: Where the Boundary Actually Is

## TL;DR

The boundary is not "pixels vs. no pixels." It's **which subsystem produces the pixels and under what timing/state model**. Off-screen rendering exercises your *content production* path — layout, drawing, layer tree composition, Core Animation's render server math — up to and including a real GPU composite in many cases. The live on-screen path additionally exercises **WindowServer-owned state**: surface backing-store negotiation, occlusion/visibility, display-link cadence, IOSurface sharing, color/HDR pipeline at the scanout stage, and a pile of AppKit behavior that is *gated on being key/visible/in a real window hierarchy*.

So the real fault line runs through three layers:

```
┌─────────────────────────────────────────────────────────────┐
│  A. CONTENT PRODUCTION   (app process)                        │
│     layout → drawRect/CALayer.draw → Auto Layout →            │
│     CATransaction commit → layer tree                         │
│     ── fully reproducible off-screen ──                       │
├─────────────────────────────────────────────────────────────┤
│  B. RENDER-SERVER COMPOSITE  (Core Animation render server,   │
│     a.k.a. backboardd-era logic / WindowServer-side compositor│
│     on macOS it's WindowServer)                               │
│     GPU composite of layer tree → IOSurface                   │
│     ── PARTIALLY reproducible off-screen, with caveats ──     │
├─────────────────────────────────────────────────────────────┤
│  C. SCANOUT / DISPLAY  (WindowServer + display engine)        │
│     window stacking, occlusion, vsync, HDR EDR mapping,       │
│     subpixel AA decisions, display color sync, ProMotion      │
│     ── NOT reproducible off-screen ──                         │
└─────────────────────────────────────────────────────────────┘
```

Most "off-screen vs. on-screen" confusion comes from people treating B as if it were entirely in A (it isn't — some off-screen APIs *skip* the render server) or entirely in C (it isn't — you can drive a real GPU composite headless).

---

## First-principles: what each off-screen technique actually executes

This matters more than the on/off-screen dichotomy, because the off-screen APIs are *not equivalent to each other*. They tap the pipeline at different depths. This is the single most under-appreciated point.

| Technique | What runs | What's bypassed | Fidelity to on-screen |
|---|---|---|---|
| `-[NSView dataWithPDF(InsideRect:)]` / `dataWithEPS` | View's `drawRect:` into a PDF/PS context (vector) | Entire CALayer compositing, GPU, rasterization, AA | Low — vector capture of drawing code only |
| `-[NSView bitmapImageRepForCachingDisplayInRect:]` + `cacheDisplayInRect:to:` | View hierarchy `drawRect:` into a CG bitmap context (CPU raster) | CALayer compositing, GPU, layer-backed content, filters | Low–medium — captures drawing, not layer composite |
| `-[CALayer renderInContext:]` | Layer's *model* drawing replayed into a CGContext (CPU) | Render-server compositing, many filters, `shouldRasterize`, masks-as-composited, GPU transforms, sublayer transforms in some cases | Medium, with notorious gaps |
| `NSView`/`CALayer` → `CGBitmapContext` via manual `render:` | CPU rasterization of your draw code | GPU compositing entirely | Low–medium |
| **`NSBitmapImageRep` from `NSImage` lockFocus drawing** | `NSGraphicsContext` CPU/GPU-backed draw | Window-level state | Medium |
| **`CARenderer` rendering a layer tree into a Metal/IOSurface texture** | **Real Core Animation render-server compositing path, GPU** | Window/WindowServer, scanout, display sync | **High for composite, no display semantics** |
| **`NSHostingController`/`NSHostingView` rendered off-screen** (SwiftUI) | Full SwiftUI graph → AppKit/CALayer realization → then one of the above capture paths | Whatever the capture path bypasses | Inherits the capture path's gaps |
| **`ImageRenderer`** (SwiftUI, macOS 13+) | SwiftUI render to `CGImage`/`NSImage`/PDF | Live timing, async content, UIKit/AppKit interop quirks | Medium–high for static content |
| **Off-screen `CAMetalLayer` / headless `MTLDevice` render** | Your own Metal pipeline | App's view tree entirely (you're rendering raw) | N/A — tests *your* GPU code, not AppKit |
| **Window rendered into off-screen but real (`orderOut` / zero-alpha / off-screen origin)** | *Almost everything*, including real WindowServer surface | Only true scanout/visibility | **Very high** — this is the underused trick |

The last row is the counterintuitive one and I'll come back to it.

---

## What ONLY off-screen reliably catches (yes — there's a direction people forget)

People frame this as "on-screen catches more." Often false. Off-screen capture catches a real class of bugs *better* than eyeballing a live window, because it freezes a deterministic frame and lets you diff pixels:

- **Sub-pixel layout drift / 1px seams / rounding bugs.** A hairline gap between two adjacent layers from non-integral frames is trivial to detect by diffing an off-screen bitmap against a golden; nearly invisible to a human watching a live window, especially on a Retina display where the seam is half a backing pixel.
- **drawRect correctness independent of compositor noise.** Off-screen removes vsync tearing, cursor overlays, and animation-in-progress nondeterminism, so a golden-image diff is stable. The live compositor is a *worse* oracle for "is my drawing code correct" because it adds confounds.
- **Color-space / gamma handling in your draw code.** Whether you blend in linear vs. sRGB, premultiplied-alpha mistakes, incorrect `CGColorSpace` on a bitmap context — these surface cleanly off-screen and are *easy to misjudge on-screen* because the display profile masks them.
- **Content that's clipped/occluded on-screen but present in the model.** Off-screen render of the full layer/view bounds reveals content drawn outside the visible window or under another view — useful for catching "we're drawing 4× too much" overdraw bugs.
- **Determinism for regression testing.** This is the whole basis of golden-image / snapshot testing. The live compositor's nondeterminism (timing, GPU driver AA variance, display profile) is exactly what you *want to exclude* for CI stability.

The non-obvious corollary: **for pure drawing/layout correctness, the live compositor is the inferior oracle.** Reach for off-screen first, not as a fallback.

---

## What off-screen MISSES — and *why*, mechanism by mechanism

This is where the candor matters. Each miss has a specific cause; "it just looks different" is not an answer.

### 1. Backing-store format & surface negotiation (WindowServer-owned)
A real on-screen window gets its backing IOSurface(s) from WindowServer with a negotiated pixel format, color space, and possibly **EDR (extended dynamic range)** headroom. Off-screen bitmaps you allocate yourself have whatever format *you* picked. Bugs that only appear when WindowServer hands you a wide-gamut or EDR surface — e.g., content that's correct in sRGB8 but clips or banding in a P3/`RGBA16Float` surface — won't show off-screen unless you deliberately replicate the format. **Mechanism:** the surface format is chosen at window-realization time by WindowServer based on the display, not by your draw code.

### 2. Subpixel text antialiasing & font smoothing
macOS dropped LCD subpixel AA for the most part since Mojave, but **font smoothing / grayscale AA decisions still depend on context type and destination.** `CALayer.renderInContext:` and CPU bitmap contexts frequently render text with different AA/hinting than the GPU compositor does on a real window — because the rasterizer path and the destination's `allowsAntialiasing`/smoothing flags differ. Text-heavy snapshots taken off-screen can mismatch the live render by a few pixels of AA on glyph edges. **Mechanism:** CoreText rasterization parameters are sensitive to context flags and backing scale that the off-screen context may not match.

### 3. Filters, blend modes, masks, `shouldRasterize`, `backgroundFilters`
`CALayer.renderInContext:` is the famous offender: it replays the *model* layer drawing, and **does not honor** a large set of compositor-only features — `backgroundFilters` (the live blur behind a layer), `filters`, certain `compositingFilter` modes, `mask` interactions, `shouldRasterize` rasterization-scale effects, and group-opacity composited correctly. **Mechanism:** these are evaluated by the render server during composite (layer B above), and `renderInContext:` runs in the app process (layer A) without the render server. → *This is precisely why `CARenderer` exists and is the right tool.*

### 4. `NSVisualEffectView` / vibrancy / desktop-tinting blur
Vibrancy samples **what's behind the window** — desktop wallpaper, other windows — via a WindowServer-side backdrop. Off-screen, there is no backdrop; you get a flat or transparent fill, never the real frosted blur. **Mechanism:** the backdrop content lives in the compositor's scene graph, not in your window's layer tree. This is *fundamentally* unobservable off-screen. Same applies to `.underWindowBackground`, sidebar materials, titlebar blending.

### 5. Window-server-composited shadows, corner masking, and the title bar
Window drop shadows, the rounded-corner mask on the window itself, full-size-content-view title bar blending, and toolbar/traffic-light positioning are **applied by WindowServer to the window surface**, not by your view tree. An off-screen render of your content view will not include the window chrome or its shadow. **Mechanism:** chrome composite happens at C.

### 6. Live-state-gated AppKit behavior
A huge, underappreciated category. Lots of AppKit code paths only execute when the view is **in a window, the window is on-screen, and/or the app is active/key**:
- `viewDidMoveToWindow`, `viewDidMoveToSuperview`, `viewDidChangeBackingProperties` (backing scale changes)
- First-responder / focus ring drawing (`drawFocusRingMask`) — focus rings often don't draw off-screen because nothing is first responder
- `NSTrackingArea` / hover / cursor-rect behavior
- `wantsLayer` / layer-backing promotion timing — a view may be *non*-layer-backed off-screen and layer-backed on-screen, changing drawing entirely
- Appearance resolution (`effectiveAppearance`, dark mode, accent color, increase-contrast) — resolved against the *window's* appearance; an orphan view may resolve to a default
- `NSStackView`/Auto Layout passes that are deferred until the view is in a window
**Mechanism:** AppKit gates work on the window/active state to avoid doing it for views that'll never be seen. Off-screen, you're in that "never seen" state, so the work is skipped — and bugs in that work are invisible.

### 7. Display-linked timing, animation cadence, ProMotion
Anything tied to `CADisplayLink`/`CVDisplayLink`, the **120 Hz ProMotion variable refresh**, frame pacing, dropped frames, animation interpolation under real vsync — none of it is exercised by a single off-screen snapshot. Jank, stutter, beam-racing tears, and "animation completes at the wrong time" are scanout-domain (C) and require the live compositor. **Mechanism:** the display link is driven by the actual display's refresh, which doesn't exist off-screen.

### 8. HDR / EDR tone mapping at scanout
EDR headroom and how SDR content is mapped relative to HDR content is computed by WindowServer against the connected display's capabilities and current global EDR headroom. Off-screen you can render `RGBAFloat16` values >1.0, but **the tone-mapping-to-display step doesn't run**, so "does my HDR content blow out / does SDR get dimmed correctly" is unobservable. **Mechanism:** EDR mapping is a scanout-stage operation parameterized by live display state.

### 9. Occlusion-driven behavior
`NSWindowOcclusionState` / `occlusionState`, `NSApp` occlusion notifications, and the optimizations apps build on them (pausing rendering when occluded) are WindowServer-computed from the *actual* window stacking. Off-screen, nothing is occluded or occluding. **Mechanism:** occlusion is a property of the live scene graph.

### 10. Multi-window / multi-display / mixed-DPI interactions
Dragging a window between a Retina and non-Retina display triggers `backingScaleFactor` changes and re-rasterization; mixed-DPI seams, wrong-scale asset selection, and blurry-on-secondary-display bugs need real displays. **Mechanism:** backing scale is a window↔display property.

---

## The render-server composite (layer B): the misunderstood middle

The crux. Most "off-screen can't catch compositor bugs" advice conflates B and C. But you *can* run the real Core Animation render-server composite off-screen, and almost nobody does:

- **`CARenderer`** renders an arbitrary `CALayer` tree into a Metal texture (or, historically, an OpenGL/IOSurface target) **using the real CA render-server compositing math** — GPU, real layer compositing, transforms, opacity, many filters. This closes most of the gap from item #3 above without a window. It's the correct tool for "snapshot what the compositor would actually composite," and it's drastically underused because `renderInContext:` is the first hit in every search.
  - Limits: still no WindowServer-supplied backdrop (#4), no chrome (#5), no scanout (#7/#8), and you must feed it a correctly-configured IOSurface/texture with the right color space to match a real window — get the color space wrong and you've reintroduced #1.

- **`SCStream` / ScreenCaptureKit against an off-screen-but-real window** captures *post-compositor* pixels including vibrancy and chrome — but the window has to be real and composited. (See next section.)

- **`CGWindowListCreateImage` / window-list capture** likewise reads the composited surface — works even for windows not frontmost, but the window must exist in the WindowServer's list.

So the practical ladder of fidelity is:

```
renderInContext: (CPU model replay)        ← lowest, most gaps
   ↓
cacheDisplayInRect: (CPU view raster)
   ↓
ImageRenderer / dataWithPDF (SwiftUI/vector)
   ↓
CARenderer → IOSurface (real GPU composite, no WindowServer)  ← big jump
   ↓
real window + CGWindowListCreateImage / SCStream capture       ← near-full
   ↓
real on-screen window + screen capture / camera-of-display     ← full, incl. scanout
```

---

## The underused, counterintuitive techniques

1. **Render a *real* window off-screen instead of faking it.** Create an actual `NSWindow`, but position it at a coordinate far off the visible screen area, or set it `alphaValue = 0` / on a non-active space, then capture via `CGWindowListCreateImage`/`SCStream`. You now exercise the **entire** pipeline through B and most of C (real backing store, real compositor, real vibrancy backdrop if any, real chrome) while it's never *seen*. This is the closest you get to on-screen fidelity without a visible window — and it sidesteps almost all of the live-state-gated AppKit misses (#6) because the view *is* genuinely in a real, realized window. The catch: it consumes a WindowServer connection, so it needs a logged-in GUI session (a launchd-agent/CI-bot context with a real `loginwindow` session, not a pure ssh/headless box).

2. **Two-oracle differential testing.** Render the same content through `CARenderer` *and* via `renderInContext:`. **Disagreement localizes the bug to a compositor-only feature** (filters, masks, group opacity) — i.e., the diff itself tells you the failure is in layer B, not in your drawing code. Almost nobody uses the *delta between off-screen methods* as a diagnostic signal.

3. **Force the live-state paths deliberately.** Before an off-screen snapshot, push the view into a transient real window, make it first responder, set its `effectiveAppearance`, run a layout pass, then snapshot. You recover focus rings, appearance resolution, and deferred layout (#6) without a visible window — but you must do it explicitly; the framework won't.

4. **Match the surface, not just the size.** When you *do* go off-screen, replicate the *format* WindowServer would give you: backing scale, color space (Display P3 / sRGB), and bit depth. Most off-screen/on-screen pixel mismatches that get blamed on "the compositor" are actually item #1 — a sRGB8 off-screen buffer vs. a P3 window surface. Fixing the buffer format closes more of the gap than people expect.

5. **Snapshot the IOSurface a real window is already backed by.** Rather than re-rendering, you can read back the window's actual backing surface. That's literally the bits the compositor will scan out — zero re-render divergence.

---

## Honest limits and traps

- **`CARenderer` is fiddly and partially under-documented**; color-space and premultiplication mistakes are easy and will make it diverge from a real window in ways that *look* like compositor bugs but are your setup. Validate it against a real-window capture once before trusting it.
- **A truly headless box (no GUI login session) can't do B or C at all.** No WindowServer connection ⇒ no GPU compositor surfaces from CA, vibrancy, chrome, or capture. You're limited to CPU paths (`renderInContext:`, bitmap contexts, `ImageRenderer`, PDF). This is the hard floor on CI runners without a real console session — and it's why your project's rule to run UI tests on the **UTM VM with a real session** rather than a headless host is correct, not just cautious.
- **Off-screen never validates timing.** No amount of clever capture reproduces jank, frame drops, vsync tearing, or ProMotion behavior. Those are C-domain and require a real display (or at least a real display link), full stop.
- **Vibrancy/EDR/occlusion are categorically unobservable off-screen** even with `CARenderer`, because their *inputs* (backdrop scene, display headroom, stacking) live outside your process. No technique recovers them short of a real composited window.
- **"Looks right off-screen" can hide layer-backing divergence (#6).** A view that's non-layer-backed off-screen but layer-backed live can render *differently* — and the off-screen pass is the lying one. Always force `wantsLayer` to the state the real window will use before snapshotting.

---

## Practical mapping for a snapshot-test strategy

| Defect class | Off-screen CPU (`renderInContext`/bitmap) | `CARenderer`/`ImageRenderer` | Real off-screen window + capture | Needs visible display |
|---|---|---|---|---|
| Layout / frame / 1px seam | ✅ best | ✅ | ✅ | — |
| drawRect color/gamma/alpha | ✅ (match buffer fmt) | ✅ | ✅ | — |
| Compositor filters/masks/group opacity | ❌ | ✅ | ✅ | — |
| Vibrancy / `NSVisualEffectView` | ❌ | ❌ | ✅ | — |
| Window chrome / shadow / corners | ❌ | ❌ | ✅ | — |
| Appearance / focus ring / live-state AppKit | ⚠️ only if forced | ⚠️ if forced | ✅ | — |
| Wide-gamut / EDR surface clipping | ⚠️ if you replicate fmt | ⚠️ | ✅ | partly |
| HDR tone-map to display | ❌ | ❌ | ❌ | ✅ |
| Animation cadence / jank / tearing | ❌ | ❌ | ❌ | ✅ |
| Occlusion-driven behavior | ❌ | ❌ | ⚠️ partial | ✅ |
| Multi-display / DPI transitions | ❌ | ❌ | ⚠️ partial | ✅ |

**Bottom line:** the boundary isn't pixels-vs-no-pixels. It's *who owns the state the defect depends on*. If the defect lives in your **content production** (A), off-screen is not just sufficient but *superior* (deterministic). If it lives in the **render-server composite** (B), `CARenderer`/a real off-screen window reaches it — `renderInContext:` does not. If it depends on **WindowServer-owned scene/scanout state** (C: backdrop, chrome, occlusion, EDR mapping, display timing), only a real composited window — visible for the timing-domain subset — will ever show it.