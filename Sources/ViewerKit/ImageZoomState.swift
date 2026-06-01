import CoreGraphics
import Foundation

/// Pure value type for image-preview zoom math. Lives in ViewerKit so
/// it's testable on host (no AppKit / NSApplication required).
///
/// Two pieces of math live here:
///   1. `clamped(_:)` — clamps a magnification factor into the allowed
///      `[minMagnification, maxMagnification]` band.
///   2. `scrollOffsetForZoom(...)` — given a focal point (e.g. cursor
///      location in the clip-view's bounds) and a zoom change, returns
///      the new scroll origin that keeps the image point under the
///      cursor stationary across the zoom.
///
/// The "keep point under cursor" formula:
///   docPoint = (clipOrigin + focal) / oldMag
///   newClipOrigin = docPoint * newMag - focal
/// Both sides are expressed in document coordinates and viewport
/// coordinates respectively; see `scrollOffsetForZoom`.
public struct ImageZoomState: Equatable, Sendable {

    /// Hard floor / ceiling for image zoom. Matches the NSScrollView
    /// `minMagnification` / `maxMagnification` we set in
    /// `MediaPreviewView.ImageScrollHost`. Kept here too so the value
    /// type is self-contained and testable in isolation.
    public static let minMagnification: CGFloat = 0.1
    public static let maxMagnification: CGFloat = 10.0

    /// Clamp `factor` into the supported magnification band.
    public static func clamped(_ factor: CGFloat) -> CGFloat {
        if factor.isNaN || !factor.isFinite { return 1.0 }
        return min(max(factor, minMagnification), maxMagnification)
    }

    /// New magnification after multiplying the previous one by `factor`,
    /// clamped to the legal range. Use for incremental zoom (scroll
    /// wheel tick, pinch delta).
    public static func nextMagnification(current: CGFloat,
                                         factor: CGFloat) -> CGFloat {
        clamped(current * factor)
    }

    /// Compute the new clip-view origin needed so that the image point
    /// currently under `focal` (a point in the clip view's bounds, NOT
    /// in document coordinates) remains under `focal` after changing
    /// the magnification from `oldMag` to `newMag`.
    ///
    /// All inputs/outputs are in clip-view-relative units (i.e. the
    /// `NSScrollView.contentView.bounds.origin` coordinate space). The
    /// caller is responsible for clamping the returned point to the
    /// scrollable bounds — that's a runtime concern that depends on
    /// the document frame, which this pure helper deliberately doesn't
    /// know about.
    ///
    /// Derivation:
    ///   - `docPoint = (clipOrigin + focal) / oldMag`
    ///     (the document-space point currently rendered at the focal
    ///     position inside the clip view).
    ///   - After re-magnifying, the same docPoint is at
    ///     `docPoint * newMag` in clip space. To keep that under the
    ///     focal screen position we need:
    ///     `newClipOrigin + focal = docPoint * newMag`
    ///     hence `newClipOrigin = docPoint * newMag - focal`.
    ///
    /// Multiplying through: the `oldMag` cancels in the ratio
    /// `newMag / oldMag`, which is what's actually used.
    public static func scrollOffsetForZoom(
        clipOrigin: CGPoint,
        focal: CGPoint,
        oldMag: CGFloat,
        newMag: CGFloat
    ) -> CGPoint {
        guard oldMag > 0, newMag > 0 else { return clipOrigin }
        let ratio = newMag / oldMag
        // Note: focal scales by `ratio` and then we subtract the
        // unscaled focal — that's the (newMag - oldMag)/oldMag * focal
        // term that does the "anchor under cursor" work.
        let x = clipOrigin.x * ratio + focal.x * (ratio - 1)
        let y = clipOrigin.y * ratio + focal.y * (ratio - 1)
        return CGPoint(x: x, y: y)
    }

    /// Scale-to-fit factor for an image inside a viewport.
    ///
    /// Returns the largest magnification at which the whole image fits
    /// inside `viewport` on both axes — i.e. `min(vw/iw, vh/ih)`. This
    /// is the default the viewer applies on load so a picture larger
    /// than the window is shrunk to fit rather than overflowing at 1:1.
    ///
    /// - Parameter allowUpscale: when `false` (the default the viewer
    ///   uses for its initial fit), the result is capped at `1.0` so a
    ///   *smaller-than-viewport* image is shown at its native pixel
    ///   size, centered, rather than blown up and blurry. When `true`
    ///   (e.g. an explicit "fill"/"fit" command), a small image is
    ///   scaled up to touch the viewport edges.
    ///
    /// Degenerate inputs (non-positive image or viewport dimensions)
    /// return `1.0` — there's nothing sensible to fit, so fall back to
    /// actual size. The result is run through `clamped(_:)` so it can
    /// never escape the legal magnification band.
    public static func fitScale(
        image: CGSize,
        viewport: CGSize,
        allowUpscale: Bool = false
    ) -> CGFloat {
        guard image.width > 0, image.height > 0,
              viewport.width > 0, viewport.height > 0 else { return 1.0 }
        var fit = min(viewport.width / image.width,
                      viewport.height / image.height)
        if !allowUpscale { fit = min(fit, 1.0) }
        return clamped(fit)
    }

    /// Clamp a desired clip-view origin to the legal scroll range for a
    /// magnified document, centering on whichever axis the scaled
    /// document is smaller than the viewport.
    ///
    /// Drag-to-pan computes a *raw* proposed origin (old origin minus
    /// the drag delta in document units); this function turns that raw
    /// value into a legal one so the user can't drag the image off into
    /// empty space. It's the runtime bounds concern that
    /// `scrollOffsetForZoom` deliberately leaves to the caller, made
    /// pure and host-testable here.
    ///
    /// Coordinates are clip-view-relative (the
    /// `NSScrollView.contentView.bounds.origin` space, in *document*
    /// units — i.e. the visible width is `viewport / magnification`).
    ///
    /// - For each axis:
    ///   - `visible = viewportDimension / magnification` — how much of
    ///     the document the clip view shows at this zoom.
    ///   - If the document is *larger* than the visible span, the origin
    ///     is clamped to `0 ... (docDimension - visible)` so the edges
    ///     can't pull past the image.
    ///   - Otherwise (document smaller than viewport on this axis) the
    ///     origin is pinned to the centering value
    ///     `(docDimension - visible) / 2` (negative), matching
    ///     `CenteringClipView`'s behavior, and the incoming proposed
    ///     value is ignored — you can't pan an axis that fully fits.
    public static func clampPan(
        proposedOrigin: CGPoint,
        viewport: CGSize,
        docFrame: CGSize,
        magnification: CGFloat
    ) -> CGPoint {
        guard magnification > 0 else { return proposedOrigin }
        return CGPoint(
            x: clampAxis(proposed: proposedOrigin.x,
                         viewport: viewport.width,
                         doc: docFrame.width,
                         magnification: magnification),
            y: clampAxis(proposed: proposedOrigin.y,
                         viewport: viewport.height,
                         doc: docFrame.height,
                         magnification: magnification))
    }

    private static func clampAxis(
        proposed: CGFloat,
        viewport: CGFloat,
        doc: CGFloat,
        magnification: CGFloat
    ) -> CGFloat {
        let visible = viewport / magnification
        if doc <= visible {
            // Document smaller than the viewport on this axis: pin to
            // the centering origin (negative), ignore the drag.
            return (doc - visible) / 2
        }
        let maxOrigin = doc - visible
        return min(max(proposed, 0), maxOrigin)
    }
}
