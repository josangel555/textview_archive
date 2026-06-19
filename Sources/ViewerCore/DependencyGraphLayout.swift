import CoreGraphics

/// Deterministic 2-D placement for a `DependencyGraph.Graph` — pure geometry,
/// no AppKit/SwiftUI, so it's fully host-testable (mirrors `TreemapLayout`).
/// Backs the "Dependency graph" view (TSK-280).
///
/// Two layouts:
///   - `circle` — evenly spaced on a ring; cheap, stable, no iteration. Good
///     for small graphs and a guaranteed non-overlapping baseline.
///   - `forceDirected` — a fixed-iteration spring/repulsion relaxation
///     (Fruchterman–Reingold flavoured) seeded from the circle layout, so the
///     result is DETERMINISTIC (no RNG) and therefore assertable in a test.
public enum DependencyGraphLayout {

    /// A node id placed at a point in `bounds`.
    public struct Position: Equatable {
        public let id: String
        public let point: CGPoint
        public init(id: String, point: CGPoint) {
            self.id = id
            self.point = point
        }
    }

    /// Lay nodes evenly on a ring inside `bounds`. A single node is centred.
    /// Order follows `graph.nodes` so the placement is stable across runs.
    public static func circle(_ graph: DependencyGraph.Graph, in bounds: CGRect) -> [Position] {
        let ids = graph.nodes.map(\.id)
        guard !ids.isEmpty, bounds.width > 0, bounds.height > 0 else { return [] }
        let cx = bounds.midX, cy = bounds.midY
        if ids.count == 1 {
            return [Position(id: ids[0], point: CGPoint(x: cx, y: cy))]
        }
        // Inset so node glyphs drawn at the point aren't clipped at the edge.
        let radius = CGFloat(0.42) * min(bounds.width, bounds.height)
        let step = (2 * Double.pi) / Double(ids.count)
        return ids.enumerated().map { i, id in
            let theta = step * Double(i) - Double.pi / 2  // start at top
            return Position(
                id: id,
                point: CGPoint(
                    x: cx + radius * CGFloat(cos(theta)),
                    y: cy + radius * CGFloat(sin(theta))))
        }
    }

    public struct ForceOptions {
        public var iterations: Int
        /// Ideal edge length as a fraction of `min(bounds.w, bounds.h)`.
        public var idealEdgeFraction: CGFloat
        public var repulsion: CGFloat
        public var attraction: CGFloat
        /// Per-iteration max move, decayed each step (simulated annealing).
        public var initialStepFraction: CGFloat

        public init(
            iterations: Int = 120,
            idealEdgeFraction: CGFloat = 0.18,
            repulsion: CGFloat = 1.0,
            attraction: CGFloat = 1.0,
            initialStepFraction: CGFloat = 0.10
        ) {
            self.iterations = iterations
            self.idealEdgeFraction = idealEdgeFraction
            self.repulsion = repulsion
            self.attraction = attraction
            self.initialStepFraction = initialStepFraction
        }
    }

    /// Force-directed relaxation seeded from `circle(_:in:)`. Deterministic:
    /// identical input ⇒ identical output (no RNG, fixed iteration count).
    /// Positions are clamped to `bounds` each step so nothing escapes the view.
    public static func forceDirected(
        _ graph: DependencyGraph.Graph,
        in bounds: CGRect,
        options: ForceOptions = ForceOptions()
    ) -> [Position] {
        let seeded = circle(graph, in: bounds)
        guard seeded.count > 1 else { return seeded }

        let n = seeded.count
        var pts = seeded.map(\.point)
        let ids = seeded.map(\.id)
        let indexOf = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })

        // Edges as index pairs (skip edges to/from a node not in the layout).
        let edgePairs: [(Int, Int)] = graph.edges.compactMap { e in
            guard let a = indexOf[e.from], let b = indexOf[e.to] else { return nil }
            return (a, b)
        }

        let span = min(bounds.width, bounds.height)
        let k = max(options.idealEdgeFraction * span, 1)         // ideal length
        let k2 = k * k
        var step = options.initialStepFraction * span
        let cool = pow(0.02, 1.0 / CGFloat(max(options.iterations, 1)))  // → ~0.02·step at end

        for _ in 0..<options.iterations {
            var disp = [CGPoint](repeating: .zero, count: n)

            // Repulsion: every pair pushes apart ~ k²/d.
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var dx = pts[i].x - pts[j].x
                    var dy = pts[i].y - pts[j].y
                    var dist = (dx * dx + dy * dy).squareRoot()
                    if dist < 0.01 {
                        // Coincident: nudge deterministically by index so the
                        // pair separates the same way every run.
                        dx = CGFloat((i % 3) - 1) * 0.5 + 0.01
                        dy = CGFloat((j % 3) - 1) * 0.5 + 0.01
                        dist = (dx * dx + dy * dy).squareRoot()
                    }
                    let force = options.repulsion * k2 / dist
                    let ux = dx / dist, uy = dy / dist
                    disp[i].x += ux * force; disp[i].y += uy * force
                    disp[j].x -= ux * force; disp[j].y -= uy * force
                }
            }

            // Attraction along edges ~ d²/k.
            for (a, b) in edgePairs {
                let dx = pts[a].x - pts[b].x
                let dy = pts[a].y - pts[b].y
                let dist = max((dx * dx + dy * dy).squareRoot(), 0.01)
                let force = options.attraction * dist * dist / k
                let ux = dx / dist, uy = dy / dist
                disp[a].x -= ux * force; disp[a].y -= uy * force
                disp[b].x += ux * force; disp[b].y += uy * force
            }

            // Apply, capped at `step`, clamped to bounds.
            for i in 0..<n {
                let mag = max((disp[i].x * disp[i].x + disp[i].y * disp[i].y).squareRoot(), 0.0001)
                let capped = min(mag, step)
                pts[i].x += disp[i].x / mag * capped
                pts[i].y += disp[i].y / mag * capped
                pts[i].x = min(max(pts[i].x, bounds.minX), bounds.maxX)
                pts[i].y = min(max(pts[i].y, bounds.minY), bounds.maxY)
            }
            step *= cool
        }

        return zip(ids, pts).map { Position(id: $0, point: $1) }
    }
}
