import Foundation
import CoreGraphics

/// TSK-1470 — the dependency graph's INTERACTION math: hit-testing (click a
/// node → its id → the view opens `Node.url`), the zoom/pan transform (pinch
/// and drag over the render canvas), and the big-graph cap. All pure — the
/// gesture wiring and the open-file call are the render tail; a wrong
/// hit-test or a zoom that drifts the anchor point is caught HERE, on the
/// host, not by eyeballing the canvas.
public enum DependencyGraphInteraction {

    /// Above this many nodes the view offers "filter to subtree" instead of
    /// drawing everything (force layout + per-node views both degrade).
    public static let nodeCap = 300

    /// Whether the view should offer the subtree-filter fallback.
    public static func exceedsCap(nodeCount: Int) -> Bool { nodeCount > nodeCap }

    /// The node whose disc (of `radius`, in MODEL space) contains `point` —
    /// the NEAREST such node when discs overlap, so a click between two
    /// crowded nodes picks the closer one deterministically. `nil` when the
    /// click is on empty canvas.
    public static func node(
        at point: CGPoint,
        positions: [DependencyGraphLayout.Position],
        radius: CGFloat
    ) -> String? {
        var best: (id: String, d2: CGFloat)?
        let r2 = radius * radius
        for pos in positions {
            let dx = pos.point.x - point.x
            let dy = pos.point.y - point.y
            let d2 = dx * dx + dy * dy
            if d2 <= r2, best.map({ d2 < $0.d2 }) ?? true {
                best = (pos.id, d2)
            }
        }
        return best?.id
    }

    /// The canvas transform: `view = model · scale + offset`. Hit-tests run
    /// in MODEL space, so a click converts through `toModel` first.
    public struct Transform: Equatable, Sendable {
        public var scale: CGFloat
        public var offset: CGPoint

        /// Zoom bounds — far enough out to fit big graphs, in for detail.
        public static let minScale: CGFloat = 0.25
        public static let maxScale: CGFloat = 4.0

        public init(scale: CGFloat = 1, offset: CGPoint = .zero) {
            self.scale = scale
            self.offset = offset
        }

        public static let identity = Transform()

        public func toView(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * scale + offset.x, y: p.y * scale + offset.y)
        }

        public func toModel(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
        }

        /// Zoom by `factor` KEEPING the view point `anchor` fixed (the pinch/
        /// scroll-wheel contract: the content under the cursor stays put).
        /// The scale clamps to [minScale, maxScale]; the offset compensates
        /// exactly for whatever scale change actually applied.
        public func zoomed(by factor: CGFloat, around anchor: CGPoint) -> Transform {
            let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
            guard newScale != scale else { return self }
            // The model point under the anchor must map back to the anchor.
            let model = toModel(anchor)
            let newOffset = CGPoint(
                x: anchor.x - model.x * newScale,
                y: anchor.y - model.y * newScale)
            return Transform(scale: newScale, offset: newOffset)
        }

        /// Pan by a view-space delta (a drag).
        public func panned(by delta: CGPoint) -> Transform {
            Transform(scale: scale,
                      offset: CGPoint(x: offset.x + delta.x, y: offset.y + delta.y))
        }

        /// The fit-to-view transform: scale (clamped) + center `content`
        /// inside `viewport` with `inset` margins.
        public static func fitting(
            content: CGRect, in viewport: CGRect, inset: CGFloat = 20
        ) -> Transform {
            guard content.width > 0, content.height > 0,
                  viewport.width > inset * 2, viewport.height > inset * 2 else {
                return .identity
            }
            let sx = (viewport.width - inset * 2) / content.width
            let sy = (viewport.height - inset * 2) / content.height
            let scale = min(max(min(sx, sy), minScale), maxScale)
            let offset = CGPoint(
                x: viewport.midX - content.midX * scale,
                y: viewport.midY - content.midY * scale)
            return Transform(scale: scale, offset: offset)
        }
    }
}
