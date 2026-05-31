# Triage — feat:image-viewer

I have everything I need. The four asks map cleanly: three are largely done by the merged branch, one (click-and-drag pan) is genuinely missing. Let me verify the one remaining technical claim — that NSScrollView doesn't pan on left-mouse drag by default — which is the crux of item 4. This is well-established AppKit behavior (NSScrollView pans only via scroll-wheel/trackpad gestures, not left-button drag), and there's no `mouseDown`/`mouseDragged` override anywhere in the image path. 

Here is the analysis.

---

## Summary

The recently merged `feat/image-scroll-zoom` branch (commit `4d0a9e2`) already implemented **three of the four asks**. The image preview path is `MediaPreviewView.ImagePreview` → `ImageScrollHost` (an `NSViewRepresentable` wrapping `ZoomableImageScrollView` + `CenteringClipView` + `CenteredImageView`), all in `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerUI/MediaPreviewView.swift`. Pure zoom math lives in `/Users/me/Documents/workspaces/claude/markdown_viewer/Sources/ViewerKit/ImageZoomState.swift` with host-runnable tests in `Tests/ViewerKitTests/ImageZoomStateTests.swift`.

Only **click-and-drag to pan** is genuinely missing. The other three are implemented; the relevant work is verification/edge-case hardening, not greenfield.

---

### Fit images to the view if larger than the window

**Status today** — Implemented. On image load, `ImagePreview` sets `didFit` and calls `fitToWindow()` exactly once (`MediaPreviewView.swift:84-86`). `fitToWindow()` sets `magnification = 0` (`:231-235`), which `ImageScrollHost.updateNSView` interprets as "fit" and routes to `applyFit` (`:359-361`). `applyFit` computes `fit = min(viewportW/imgW, viewportH/imgH, 1.0)` (`:390-392`) — the `1.0` cap means images *smaller* than the window are shown 1:1, never upscaled, while larger images are scaled down to fit. There are also `0`/`⌘0`/"Fit" controls (`:122`, `:162`).

**Root cause / gap** — No functional gap. Two latent edge cases:
- `applyFit` reads `scroll.contentView.bounds.size` (`:387`). During `makeNSView`/first layout the viewport bounds can be `.zero`, producing `fit = 0` → `clamped(0)` → `0.1` (`ImageZoomState.clamped` floors at `minMagnification`, `ImageZoomState.swift:30-33`). In practice the `onLoad`→`didFit`→`fitToWindow` path defers fit to a later `updateNSView` once bounds are real, so this rarely bites, but a zero-bounds first pass is theoretically reachable.
- Fit is computed once per load; it does **not** re-fit on window resize (no bounds-change observer). Resize after open leaves the old magnification. Minor, and arguably correct (don't fight the user's manual zoom), but worth a deliberate decision.

**Fix/build sketch** — Mostly done. If re-fit-on-resize is wanted: observe `NSView.frameDidChangeNotification` on the clip view (or override `layout()` in a scroll-view subclass) and re-run `applyFit` *only while still in fit mode* (track a `didUserZoom` flag so resize doesn't clobber an explicit zoom). Guard `applyFit` early-return when `viewportSize` is zero.

**Size** — **S** (already shipped). Re-fit-on-resize hardening is a small **S** add.

**Dependencies** — None; landed.

**Risk/one-way-door note** — None.

---

### Always center-align images

**Status today** — Implemented via the canonical AppKit pattern. `CenteringClipView` (`MediaPreviewView.swift:487-500`) overrides `constrainBoundsRect` to shift the bounds origin negative when the document is smaller than the viewport on either axis, centering it (`:492-498`). It replaces the stock clip view at `:318-320`. `CenteredImageView` (`:467-474`) overrides `adjustScroll` to prevent snap-back-to-origin, and uses `imageScaling = .scaleProportionallyUpOrDown` + `imageAlignment = .alignCenter` (`:323-324`). `applyFit` additionally centers the scroll position for the larger-than-viewport case (`:395-399`). The SwiftUI host wraps it in a `ZStack` over `Palette.windowBackground` with an outer `.frame(maxWidth/maxHeight: .infinity)` (`MediaPreviewView.swift:53`, `ContentView.swift:323`) so the representable gets the full content rect rather than collapsing to intrinsic size bottom-left.

**Root cause / gap** — No gap. This is the correct fix; the code comments (`:476-486`) correctly note that resizing the documentView or overriding `adjustScroll` alone does *not* center across both fit and pinch-zoom-out, which is why the clip-view override is used.

**Fix/build sketch** — N/A, complete.

**Size** — **S** (already shipped).

**Dependencies** — None.

**Risk/one-way-door note** — None. `isFlipped: false` on `CenteredImageView` (`:468`) means a non-flipped coordinate space; any future drag-pan code must account for this (bottom-left origin) — see the pan item.

---

### Cmd+Scroll should zoom in/out

**Status today** — Implemented. `ZoomableImageScrollView.scrollWheel` (`MediaPreviewView.swift:431-461`) intercepts only when `.command` is held (`:435`), otherwise calls `super` so plain wheel still pans a zoomed image (`:436-438`). It derives a per-tick factor `max(0.1, 1 + delta * 0.0025)` (`:443-448`), clamps the new magnification via `ImageZoomState.nextMagnification` (`:449`), and anchors at the cursor using `setMagnification(_:centeredAt:)` with the cursor converted to clip-view coords (`:456-458`) — the "point under cursor stays put" behavior. It then posts `wheelZoomDidChangeNotification` (`:459-460`), which the coordinator observes (`:345-349`, `:292-295`) to mirror the new magnification back into SwiftUI `@State` so the % HUD stays in sync and the next `updateNSView` doesn't snap back. Trackpad pinch is handled free by `allowsMagnification = true` (`:305`, `:327-329`), with `didEndLiveMagnifyNotification` syncing state (`:284-287`, `:340-344`). Bounds match `ImageZoomState.{min,max}Magnification` (0.1×–10×) on both the scroll view (`:308-309`) and the value type (`ImageZoomState.swift:26-27`).

**Root cause / gap** — Functionally complete. Notes:
- The pure helper `ImageZoomState.scrollOffsetForZoom` (`ImageZoomState.swift:67-81`) is *tested* but **not actually used** by the wheel path — the runtime relies on AppKit's `setMagnification(_:centeredAt:)` for anchoring instead. So the focal-point tests validate a formula the production path doesn't call. Not a bug, but the test coverage is somewhat illusory for the real anchoring behavior (which is untested and UI-only).
- `wheelZoomGain = 0.0025` is a hand-tuned constant (`:429`); fine, but pixel-precise trackpad scroll vs. notched-mouse wheel will feel different — only verifiable on the VM/device.

**Fix/build sketch** — N/A for the feature. Optional cleanup: either wire `scrollOffsetForZoom` into a manual-anchoring path (if you ever drop reliance on `setMagnification(_:centeredAt:)`), or annotate the tests as covering the math primitive, not the live path.

**Size** — **S** (already shipped).

**Dependencies** — None.

**Risk/one-way-door note** — None. Cmd+scroll intercept is scoped to `allowsMagnification` images only; doesn't affect other previews.

---

### Click-and-drag to pan

**Status today** — **Not implemented.** This is the one genuine gap. There is no `mouseDown`/`mouseDragged`/`mouseUp` override anywhere in the image path — `ZoomableImageScrollView` only overrides `scrollWheel` (`MediaPreviewView.swift:431`), and `CenteredImageView` only overrides `isFlipped` and `adjustScroll` (`:467-474`). The only `mouseDown` in the codebase is in `HexView.swift:732`, unrelated. By default `NSScrollView` pans **only** via scroll wheel / two-finger trackpad — a left-button click-drag does nothing. So today a zoomed-in image can be panned with the wheel/trackpad but **not** by grabbing and dragging it.

**Root cause / gap** — No mouse-drag → scroll translation exists. NSScrollView has no built-in "hand tool" drag-pan; it must be added by hand.

**Fix/build sketch** — Add drag handling to a view in the responder chain that has access to the scroll/clip view. Cleanest place is `CenteredImageView` (the document view), or a thin gesture layer:

```swift
// In CenteredImageView (documentView):
private var dragLast: NSPoint?

override func mouseDown(with e: NSEvent) {
    dragLast = e.locationInWindow
    NSCursor.closedHand.set()
}
override func mouseDragged(with e: NSEvent) {
    guard let last = dragLast,
          let clip = enclosingScrollView?.contentView else { return }
    let now = e.locationInWindow
    // Drag content with the cursor: move bounds origin opposite to
    // the cursor delta. NOTE: CenteredImageView.isFlipped == false,
    // so +y is up — sign of dy must match that convention.
    var o = clip.bounds.origin
    o.x -= (now.x - last.x)
    o.y -= (now.y - last.y)
    clip.scroll(to: o)                       // CenteringClipView will
    enclosingScrollView?.reflectScrolledClipView(clip)  // re-clamp/center
    dragLast = now
}
override func mouseUp(with e: NSEvent) {
    dragLast = nil
    NSCursor.arrow.set()
}
```

Considerations that make this M not S:
- **Coordinate convention.** `CenteredImageView.isFlipped == false` (`:468`), so the y-axis sign in the drag delta and the existing `CenteringClipView.constrainBoundsRect` math (`:488-498`) must agree, or vertical pan inverts. Needs on-device verification (host UI tests are barred per `CLAUDE.md`).
- **Interaction with centering.** When the image is *smaller* than the viewport, `CenteringClipView` forces the origin to center — drag should be a no-op there (nothing to pan). When larger, drag should move and the clip view's `constrainBoundsRect`/`super.constrainBoundsRect` clamps to document edges. The existing override only centers on the axis where doc < viewport, so per-axis behavior should fall out correctly, but needs testing.
- **Cursor affordance.** Open-hand on hover / closed-hand on drag (à la Preview.app) is expected polish; `NSTrackingArea` + `cursorUpdate` or `resetCursorRects`.
- **Gesture conflict.** Must not break double-click, future selection, or the existing wheel-pan. A left-drag-only handler is isolated from `scrollWheel`, so low conflict risk.
- **Pure-logic extraction.** The delta→new-origin math (with clamping) can be pulled into `ImageZoomState` (a `panOffset(clipOrigin:delta:isFlipped:)` style helper) so it's host-testable like the existing zoom math — recommended to keep parity with the existing test strategy, since the drag itself can only be exercised on the VM.

**Size** — **M.** ~30-60 lines of AppKit plus cursor affordance, but the y-flip/centering interaction and the no-host-UI-testing constraint (must validate on the UTM macOS15 VM per `CLAUDE.md`) push it past trivial. Pure-math extraction + tests add a little but de-risk it.

**Dependencies** — Builds directly on the merged scroll/clip/zoom infrastructure (`CenteringClipView`, `ZoomableImageScrollView`). Nothing else required first.

**Risk/one-way-door note** — Low / fully reversible. Localized to `MediaPreviewView.swift`'s private AppKit classes; no API or persistence surface, no state-machine impact. The only real trap is the `isFlipped == false` y-sign — get it wrong and pan inverts vertically, but that's a one-line fix, not a one-way door. Verification requires the VM (`ssh macOS15` / `scripts/vm-smoke.sh`), not host.