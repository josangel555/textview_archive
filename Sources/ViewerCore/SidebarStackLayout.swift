import Foundation
import CoreGraphics

/// Owner 2026-08-09 — the left-shoulder STRUCTURAL rework.
///
/// The old accordion stacked panels three different ways (fixed panels
/// inside a bounded scroll, the flex panel outside it, plugin sections as a
/// third case), which produced the reported class: phantom scrollbars
/// "encapsulating the first two tool windows", dead gaps, a missing divider
/// before plugins, resizes pushing other panels away, and a blanket
/// 50%-of-band ceiling that walled shrinking in a dual split.
///
/// New model — ONE rule for every panel:
///   * the visible panels form a single non-scrolling stack;
///   * every panel but the FLEX one renders at its stored height, floored;
///   * the FLEX panel (FILES when visible, else the LAST visible panel)
///     absorbs the remainder — including any arithmetic slack, so estimate
///     errors can never become scrollbars or chrome push;
///   * when the fixed heights don't fit, they are shrunk toward their
///     floors starting from the panel NEAREST the flex end (VSCode-like)
///     until the stack fits; a band smaller than everyone's floors clips
///     at the container (the pathological tiny-window case).
///
/// Pure and host-tested; the view layer feeds measured band height and
/// per-panel chrome, and renders exactly what this returns.
public enum SidebarStackLayout {

    public struct Resolution: Equatable, Sendable {
        /// Rendered body heights for the FIXED panels, in input order.
        public let fixed: [CGFloat]
        /// Rendered body height for the flex panel.
        public let flex: CGFloat
    }

    /// Resolve rendered body heights.
    /// - Parameters:
    ///   - storedFixed: stored (persisted) body heights of the fixed
    ///     panels, in on-screen order.
    ///   - floor: the minimum expanded body height (every panel shares it).
    ///   - flexFloor: the flex panel's minimum body height.
    ///   - available: the band height available to BODIES (the caller has
    ///     already subtracted headers and gutters). Non-finite/≤0 (the
    ///     pre-measurement pass) renders stored heights as-is with a
    ///     floor-height flex.
    public static func resolve(
        storedFixed: [CGFloat],
        floor: CGFloat,
        flexFloor: CGFloat,
        available: CGFloat
    ) -> Resolution {
        var fixed = storedFixed.map { max($0, floor) }
        guard available.isFinite, available > 0 else {
            return Resolution(fixed: fixed, flex: flexFloor)
        }
        let fixedTotal = fixed.reduce(0, +)
        if fixedTotal + flexFloor <= available {
            // Roomy: flex absorbs the remainder (and any slack).
            return Resolution(fixed: fixed, flex: available - fixedTotal)
        }
        // Crowded: shrink fixed panels toward the floor, starting from the
        // one nearest the flex end, until the stack fits.
        var over = fixedTotal + flexFloor - available
        for i in stride(from: fixed.count - 1, through: 0, by: -1) where over > 0 {
            let give = min(fixed[i] - floor, over)
            fixed[i] -= give
            over -= give
        }
        return Resolution(fixed: fixed, flex: flexFloor)
    }

    /// The most a drag may grow the fixed panel ABOVE the flex boundary:
    /// its current height plus everything the flex panel can give up
    /// before hitting its floor. Pair dividers between two fixed panels
    /// need NO ceiling (their redistribution is sum-preserving and floored
    /// on both sides) — the blanket 50% band ceiling that walled dual-split
    /// shrinking is gone.
    public static func boundaryMax(
        aboveRendered: CGFloat,
        flexRendered: CGFloat,
        flexFloor: CGFloat
    ) -> CGFloat {
        aboveRendered + max(0, flexRendered - flexFloor)
    }
}
