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
}
