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
    ///
    /// Owner 2026-08-12, refined the same day: opening 4–5 panels must
    /// leave EVERY panel in view — so when the stored heights over-fill
    /// the band, all fixed panels scale down PROPORTIONALLY (each keeps
    /// its share of the above-floor space) until they fit. Proportional
    /// and order-independent — never the old from-the-flex-end collapse.
    /// The "only grow in the direction you drag" rule is preserved by the
    /// DRAG layer, not here: drags are sum-preserving in rendered space
    /// (the frozen session), so a drag never changes the total and never
    /// triggers a refit — third panels stay put under the pointer. A
    /// refit happens exactly when the panel SET or the band changes.
    /// Scroll engages only in the pathological case: floors alone don't
    /// fit.
    ///
    /// - Parameters:
    ///   - storedFixed: stored (persisted) body heights of the fixed
    ///     panels, in on-screen order.
    ///   - floor: the minimum expanded body height (every panel shares it).
    ///   - flexFloor: the flex panel's minimum body height (same floor —
    ///     no per-panel special cases).
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
        let fixed = storedFixed.map { max($0, floor) }
        guard available.isFinite, available > 0 else {
            return Resolution(fixed: fixed, flex: flexFloor)
        }
        let fixedTotal = fixed.reduce(0, +)
        if fixedTotal + flexFloor <= available {
            // Roomy: flex absorbs the remainder (and any slack).
            return Resolution(fixed: fixed, flex: available - fixedTotal)
        }
        // Over-full: scale every panel's ABOVE-FLOOR portion by one shared
        // factor so the stack fits exactly (each keeps its proportional
        // share; floors are hard). Below-all-floors ⇒ factor 0 ⇒ everyone
        // at floor and the outer scroll engages.
        let floorTotal = floor * CGFloat(fixed.count)
        let target = available - flexFloor
        let stretch = fixedTotal - floorTotal
        let factor = stretch > 0
            ? min(1, max(0, (target - floorTotal) / stretch))
            : 0
        let scaled = fixed.map { floor + ($0 - floor) * factor }
        return Resolution(fixed: scaled, flex: flexFloor)
    }

    // (`boundaryMax` was deleted 2026-08-12: the flex-adjacent divider's
    // growth bound now lives in `DividerDragSession` — the origin-frozen
    // slack — so the view no longer computes a live ceiling.)
}
