import SwiftUI
import ViewerCore

/// Left-side graph column for the Log tab. Renders dots + lines for
/// one row of a `GraphLayout`. Stateless — owns no animation, just
/// paints what the layout describes.
///
/// Width: `(maxLane + 1) * laneWidth`. Drop into an HStack ahead of
/// the commit text body.
struct GitGraphColumn: View {
    let row: GraphLayout.Row
    let maxLane: Int
    let isHead: Bool

    private let laneWidth: CGFloat = 14
    private let dotRadius: CGFloat = 3.5
    private let lineWidth: CGFloat = 1.4

    /// Per-lane palette — keeps merge branches visually distinct.
    private static let palette: [Color] = [
        .accentColor,
        .orange,
        .purple,
        .teal,
    ]

    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            let mid = h / 2
            // Phase A: lines from top edge to mid for lanes in
            // lanesBefore. The lane carries the child sha; the line
            // ends at mid only if this row is that child OR the lane
            // continues (sha also in lanesAfter at any position).
            for (i, before) in row.lanesBefore.enumerated() {
                guard let sha = before else { continue }
                let x = xFor(i)
                let isMyLane = (i == row.lane)
                let continuesBelow = row.lanesAfter.contains(sha)
                let path = Path { p in
                    p.move(to: CGPoint(x: x, y: 0))
                    // Always reach mid for own-lane (so the dot is centered)
                    // or for continuing lanes.
                    p.addLine(to: CGPoint(x: x, y: mid))
                }
                ctx.stroke(path, with: .color(color(forLane: i, isMy: isMyLane)),
                           lineWidth: lineWidth)
                _ = continuesBelow  // suppress unused; logic handled below
            }
            // Phase B: lines from mid to bottom for lanes in lanesAfter.
            // For parents that share the commit's lane (first parent),
            // it's a vertical line. For parents in different lanes
            // (merges), draw an angled line from (myLane, mid) to
            // (parentLane, bottom).
            for (i, after) in row.lanesAfter.enumerated() {
                guard let sha = after else { continue }
                // If this lane was already active above and we're just
                // passing through, draw a vertical from mid down.
                let isMyLane = (i == row.lane)
                let cameFromAbove = row.lanesBefore.indices.contains(i)
                    && row.lanesBefore[i] == sha
                let spawnedHere = !cameFromAbove
                let parentLaneX = xFor(i)
                if spawnedHere && !isMyLane {
                    // Angled line from my dot to this parent's lane at bottom.
                    let path = Path { p in
                        p.move(to: CGPoint(x: xFor(row.lane), y: mid))
                        p.addLine(to: CGPoint(x: parentLaneX, y: h))
                    }
                    ctx.stroke(path, with: .color(color(forLane: i, isMy: false)),
                               lineWidth: lineWidth)
                } else {
                    // Vertical from mid to bottom.
                    let path = Path { p in
                        p.move(to: CGPoint(x: parentLaneX, y: mid))
                        p.addLine(to: CGPoint(x: parentLaneX, y: h))
                    }
                    ctx.stroke(path, with: .color(color(forLane: i, isMy: isMyLane)),
                               lineWidth: lineWidth)
                }
            }
            // Phase C: the dot itself.
            let dotCenter = CGPoint(x: xFor(row.lane), y: mid)
            let dotRect = CGRect(
                x: dotCenter.x - dotRadius,
                y: dotCenter.y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )
            let fill: Color = row.commit.isMerge
                ? Color.purple
                : (isHead ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
            let stroke: Color = isHead
                ? Color.accentColor
                : color(forLane: row.lane, isMy: true)
            ctx.fill(Path(ellipseIn: dotRect), with: .color(fill))
            ctx.stroke(Path(ellipseIn: dotRect), with: .color(stroke), lineWidth: lineWidth)
        }
        .frame(width: CGFloat(maxLane + 1) * laneWidth)
    }

    private func xFor(_ lane: Int) -> CGFloat {
        CGFloat(lane) * laneWidth + laneWidth / 2
    }

    private func color(forLane lane: Int, isMy: Bool) -> Color {
        let palette = Self.palette
        return palette[lane % palette.count]
    }
}
