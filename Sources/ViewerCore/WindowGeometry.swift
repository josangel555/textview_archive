import Foundation
import CoreGraphics

/// TSK-358 — pure, host-testable window-geometry model.
///
/// The "remember my window size/position across launches" behaviour used to
/// live as inline AppKit in `MarkdownViewer/main.swift`: it read the frame
/// AppKit restored (via `setFrameAutosaveName`), then ad-hoc clamped it to a
/// minimum content size and re-centered when the saved frame had drifted onto
/// a now-disconnected display. That logic was untestable on the host (it
/// touched a live `NSWindow` / `NSScreen`).
///
/// This type extracts the DECISION — given a *requested* frame (whatever was
/// restored, possibly garbage), the available visible screen rects, and the
/// minimum content-derived window size — what frame should we actually show?
/// — into a stateless function over plain `CGRect`s. The live `NSWindow`
/// apply + the on-screen result stay the VM tail; the math is pinned by
/// `ViewerCoreTests.WindowGeometryTests`.
///
/// SwiftUI/AppKit-free on purpose so the host suite covers it.
public enum WindowGeometry {

    /// The factory-default window content size used when there is no usable
    /// saved geometry (first launch, or a corrupt/degenerate restore). The
    /// app's hard minimum content size is `600 × 360` (`main.swift`); the
    /// default is comfortably larger so a fresh launch isn't cramped.
    public static let defaultContentSize = CGSize(width: 1000, height: 700)

    /// Hard minimum content size — mirrors `window.contentMinSize` in
    /// `main.swift`. A restored frame smaller than this on either axis is
    /// grown back to it (you can never be left with a sub-usable window).
    public static let minContentSize = CGSize(width: 600, height: 360)

    /// A persisted window frame. Codable so it can round-trip through
    /// `PreferencesStore` as JSON (a single key, screen-independent numbers).
    /// We persist the *content-relative* frame in screen coordinates; the
    /// caller converts to/from a window frame at the AppKit boundary.
    public struct Frame: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public init(_ rect: CGRect) {
            self.x = Double(rect.origin.x)
            self.y = Double(rect.origin.y)
            self.width = Double(rect.size.width)
            self.height = Double(rect.size.height)
        }

        public var cgRect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }

        /// `true` when every component is finite and both dimensions are
        /// strictly positive. A NaN/inf/zero/negative frame (a hand-edited
        /// or corrupt persisted value) is rejected — the caller falls back
        /// to the default.
        public var isUsable: Bool {
            x.isFinite && y.isFinite && width.isFinite && height.isFinite
                && width > 0 && height > 0
        }
    }

    /// Outcome of resolving a requested frame against the screen layout.
    public enum Resolution: Equatable {
        /// Use this frame as-is (it was usable and fully visible).
        case restore(CGRect)
        /// The frame was clamped (oversize/below-min) but kept its anchor.
        case clamped(CGRect)
        /// No usable saved frame (or fully off-screen) — center a
        /// default-sized window on the primary screen.
        case centerDefault(CGSize)

        /// The concrete frame the window should adopt. For `.centerDefault`
        /// this centers the default size within `primaryVisible`.
        public func frame(primaryVisible: CGRect) -> CGRect {
            switch self {
            case let .restore(r), let .clamped(r):
                return r
            case let .centerDefault(size):
                return WindowGeometry.centered(size, in: primaryVisible)
            }
        }
    }

    /// Center `size` within `bounds`.
    public static func centered(_ size: CGSize, in bounds: CGRect) -> CGRect {
        let x = bounds.origin.x + (bounds.size.width - size.width) / 2
        let y = bounds.origin.y + (bounds.size.height - size.height) / 2
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Resolve a requested window frame against the current screen layout.
    ///
    /// - Parameters:
    ///   - requested: the restored frame, or `nil` if nothing was saved.
    ///   - visibleFrames: every currently-attached screen's `visibleFrame`
    ///     (menu-bar / Dock-excluded usable area). Empty ⇒ treated as a
    ///     single notional primary at the origin sized to the default.
    ///   - minSize: minimum content-derived window size (default
    ///     ``minContentSize``).
    ///   - defaultSize: the size for a centered default window (default
    ///     ``defaultContentSize``).
    /// - Returns: a ``Resolution`` describing how to place the window.
    public static func resolve(
        requested: Frame?,
        visibleFrames: [CGRect],
        minSize: CGSize = minContentSize,
        defaultSize: CGSize = defaultContentSize
    ) -> Resolution {
        // No saved frame, or a degenerate one (NaN / zero / negative) →
        // factory default, centered.
        guard let requested, requested.isUsable else {
            return .centerDefault(defaultSize)
        }

        let primary = visibleFrames.first ?? CGRect(origin: .zero,
                                                    size: defaultSize)
        var rect = requested.cgRect
        var didClamp = false

        // 1. Grow a too-small frame back to the minimum (you can never be
        //    left with a sub-usable window). Don't let the minimum exceed
        //    the primary screen — clamp the min itself to the screen so we
        //    never request a window bigger than the display.
        let effectiveMin = CGSize(
            width: min(minSize.width, primary.size.width),
            height: min(minSize.height, primary.size.height)
        )
        if rect.size.width < effectiveMin.width {
            rect.size.width = effectiveMin.width
            didClamp = true
        }
        if rect.size.height < effectiveMin.height {
            rect.size.height = effectiveMin.height
            didClamp = true
        }

        // 2. Cap an oversize frame to the screen it lives on (a saved frame
        //    from a bigger external display, restored on a smaller built-in).
        let host = screen(for: rect, in: visibleFrames) ?? primary
        if rect.size.width > host.size.width {
            rect.size.width = host.size.width
            didClamp = true
        }
        if rect.size.height > host.size.height {
            rect.size.height = host.size.height
            didClamp = true
        }

        // 3. If the frame doesn't overlap ANY visible screen (a window that
        //    was on a now-disconnected monitor), recover with a centered
        //    default rather than nudging an off-screen anchor.
        let onAScreen = visibleFrames.contains { $0.intersects(rect) }
        if !visibleFrames.isEmpty && !onAScreen {
            return .centerDefault(defaultSize)
        }

        // 4. Nudge a partially-off-screen frame fully back onto its host so
        //    its title bar / resize controls stay reachable.
        let nudged = clampOrigin(rect, into: host)
        if nudged != rect {
            rect = nudged
            didClamp = true
        }

        return didClamp ? .clamped(rect) : .restore(rect)
    }

    /// TSK-1576: a deterministic, footer-inclusive window frame for UAT SCENE
    /// captures — a generous `target` size (large enough that the WHOLE app
    /// chrome, including the status-bar FOOTER, renders), centered in and capped
    /// to `visible`. Scene spawns otherwise restore whatever frame the VM last
    /// saved, which can be as small as the minimum content size (600×360) — at
    /// that height the footer is squeezed out of the window-id capture entirely
    /// (verified 2026-07-09: at 600×360 no footer captured; at 1280×860 the full
    /// footer + every chip render). Deterministic (depends only on `visible` +
    /// `target`), so every scene captures the same reproducible geometry rather
    /// than a leftover saved frame.
    public static func sceneCaptureFrame(
        in visible: CGRect,
        target: CGSize = CGSize(width: 1280, height: 860),
        margin: CGFloat = 20
    ) -> CGRect {
        let w = max(1, min(target.width, visible.size.width - 2 * margin))
        let h = max(1, min(target.height, visible.size.height - 2 * margin))
        let x = visible.minX + (visible.size.width - w) / 2
        let y = visible.minY + (visible.size.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The visible screen rect that contains the largest share of `rect`
    /// (the display the window "belongs to"), or `nil` if it overlaps none.
    public static func screen(for rect: CGRect, in visibleFrames: [CGRect]) -> CGRect? {
        var best: CGRect?
        var bestArea: CGFloat = 0
        for vf in visibleFrames {
            let inter = vf.intersection(rect)
            guard !inter.isNull else { continue }
            let area = inter.size.width * inter.size.height
            if area > bestArea {
                bestArea = area
                best = vf
            }
        }
        return best
    }

    /// Shift `rect`'s origin so it sits fully within `bounds` where it can
    /// (a rect no larger than `bounds` ends up fully contained; an oversize
    /// rect is pinned to the bounds' origin). Size is never changed here.
    public static func clampOrigin(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var x = rect.origin.x
        var y = rect.origin.y
        let maxX = bounds.origin.x + bounds.size.width - rect.size.width
        let maxY = bounds.origin.y + bounds.size.height - rect.size.height
        // If the rect is wider/taller than the bounds, maxX/maxY < minX/minY;
        // pin to the origin in that case (the size cap in resolve() handles
        // the over-size case, but be defensive for direct callers).
        x = min(max(x, bounds.origin.x), max(maxX, bounds.origin.x))
        y = min(max(y, bounds.origin.y), max(maxY, bounds.origin.y))
        return CGRect(x: x, y: y, width: rect.size.width, height: rect.size.height)
    }
}
