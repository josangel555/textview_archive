import SwiftUI
import ViewerCore

/// Left-side graph column for the Log tab. Renders dots + lines for
/// one row of a `GraphLayout`. Stateless — owns no animation, just
/// paints what the layout describes.
///
/// TSK-1603 (owner 2026-07-24) — four rendering fixes:
///   1. **Continuous lines.** The canvas paints edge-to-edge (top 0 → bottom
///      h) and the ROW no longer pads the graph column, so consecutive rows'
///      strokes meet exactly. Previously the row's `.padding(.vertical)`
///      inset every canvas, leaving a gap in each row — "the lines are
///      disconnected in every row".
///   2. **Real fork/merge shape.** Parent edges that change lane are drawn as
///      smooth curves out of the dot (and INTO the joined lane), instead of a
///      straight diagonal — the branching look. `Row.parentLanes` also makes
///      a join to an already-pending lane visible; that edge used to be
///      dropped entirely, so a branch line just stopped.
///   3. **Branch-stable colors.** Color comes from `branchID` (a run of
///      commits in a lane), not the recycled lane index, so a finished branch
///      and the next occupant of that lane read differently.
///   4. **Hover highlight.** `hoveredBranchID` dims every other branch, so
///      hovering shows exactly which commits and lines belong together.
///
/// Width: `(maxLane + 1) * laneWidth`. Drop into an HStack ahead of
/// the commit text body.
struct GitGraphColumn: View {
    let row: GraphLayout.Row
    let maxLane: Int
    let isHead: Bool
    /// Branch id the pointer is currently over, if any (TSK-1603).
    var hoveredBranchID: Int? = nil

    private let laneWidth: CGFloat = 14
    private let dotRadius: CGFloat = 3.5
    private let lineWidth: CGFloat = 1.6

    /// Per-BRANCH palette. Eight hues (was four) so a lane reused several
    /// times in view keeps cycling before repeating; system colors so both
    /// appearances stay legible.
    private static let palette: [Color] = [
        .accentColor, .orange, .purple, .teal,
        .pink, .green, .indigo, .brown,
    ]

    /// How much a non-hovered branch fades while another is hovered.
    private static let dimmedOpacity: Double = 0.22

    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            let mid = h / 2
            let myX = xFor(row.lane)

            // ---- Pass-through lanes: a lane active BOTH before and after
            // this row (and not this commit's own) runs straight through,
            // full height — no seam at the row boundary.
            for (i, before) in row.lanesBefore.enumerated() where before != nil {
                guard i != row.lane else { continue }
                let stillActive = i < row.lanesAfter.count && row.lanesAfter[i] == before
                guard stillActive else { continue }
                let x = xFor(i)
                stroke(ctx, id: idBefore(i),
                       path: Path { p in
                           p.move(to: CGPoint(x: x, y: 0))
                           p.addLine(to: CGPoint(x: x, y: h))
                       })
            }

            // ---- Incoming edge: this commit's lane, from the top edge down
            // to the dot. Present whenever a child above already reserved the
            // lane (i.e. this row isn't the branch's newest commit).
            if row.lane < row.lanesBefore.count, row.lanesBefore[row.lane] != nil {
                stroke(ctx, id: row.branchID,
                       path: Path { p in
                           p.move(to: CGPoint(x: myX, y: 0))
                           p.addLine(to: CGPoint(x: myX, y: mid))
                       })
            }

            // ---- Parent edges: from the dot to each parent's lane at the
            // bottom. Same-lane parents run straight; lane changes curve.
            for (idx, parentLane) in row.parentLanes.enumerated() where parentLane >= 0 {
                let px = xFor(parentLane)
                // The FIRST parent continues this branch's run; a merge's
                // extra parents belong to the branch being merged in.
                let edgeID = (idx == 0 && parentLane == row.lane)
                    ? row.branchID
                    : (idAfter(parentLane) ?? row.branchID)
                if abs(px - myX) < 0.5 {
                    stroke(ctx, id: edgeID,
                           path: Path { p in
                               p.move(to: CGPoint(x: myX, y: mid))
                               p.addLine(to: CGPoint(x: myX, y: h))
                           })
                } else {
                    // Fork / join: leave the dot horizontally, then bend into
                    // the target lane and finish vertical — the shape every
                    // git GUI uses to say "this line came from there".
                    stroke(ctx, id: edgeID, path: Path { p in
                        p.move(to: CGPoint(x: myX, y: mid))
                        p.addCurve(
                            to: CGPoint(x: px, y: h),
                            control1: CGPoint(x: myX, y: mid + (h - mid) * 0.45),
                            control2: CGPoint(x: px, y: mid + (h - mid) * 0.55))
                    })
                }
            }

            // ---- The dot. A merge reads as a ring; HEAD is filled accent.
            let dotCenter = CGPoint(x: myX, y: mid)
            let r = row.commit.isMerge ? dotRadius + 0.8 : dotRadius
            let dotRect = CGRect(
                x: dotCenter.x - r, y: dotCenter.y - r, width: r * 2, height: r * 2)
            let branchColor = color(forBranch: row.branchID)
            let dimmed = isDimmed(row.branchID)
            let fill: Color = isHead
                ? Color.accentColor
                : (row.commit.isMerge ? Palette.windowBackground : branchColor)
            let strokeColor: Color = isHead ? Color.accentColor : branchColor
            ctx.fill(Path(ellipseIn: dotRect),
                     with: .color(fill.opacity(dimmed ? Self.dimmedOpacity : 1)))
            ctx.stroke(Path(ellipseIn: dotRect),
                       with: .color(strokeColor.opacity(dimmed ? Self.dimmedOpacity : 1)),
                       lineWidth: row.commit.isMerge ? lineWidth + 0.4 : lineWidth)
            // HEAD gets a halo ring so "you are here" survives the dimming.
            if isHead {
                let halo = dotRect.insetBy(dx: -2.5, dy: -2.5)
                ctx.stroke(Path(ellipseIn: halo),
                           with: .color(Color.accentColor.opacity(0.35)), lineWidth: 1)
            }
        }
        .frame(width: CGFloat(maxLane + 1) * laneWidth)
    }

    // MARK: - Drawing helpers

    /// Stroke `path` in `id`'s branch color, dimmed when another branch is
    /// hovered and thickened when THIS one is.
    private func stroke(_ ctx: GraphicsContext, id: Int, path: Path) {
        let dimmed = isDimmed(id)
        let width = (hoveredBranchID == id) ? lineWidth + 0.8 : lineWidth
        ctx.stroke(
            path,
            with: .color(color(forBranch: id).opacity(dimmed ? Self.dimmedOpacity : 1)),
            lineWidth: width)
    }

    private func isDimmed(_ id: Int) -> Bool {
        guard let hovered = hoveredBranchID else { return false }
        return hovered != id
    }

    private func idBefore(_ lane: Int) -> Int {
        (lane < row.beforeIDs.count ? row.beforeIDs[lane] : nil) ?? row.branchID
    }

    private func idAfter(_ lane: Int) -> Int? {
        lane < row.afterIDs.count ? row.afterIDs[lane] : nil
    }

    private func xFor(_ lane: Int) -> CGFloat {
        CGFloat(lane) * laneWidth + laneWidth / 2
    }

    private func color(forBranch id: Int) -> Color {
        Self.palette[abs(id) % Self.palette.count]
    }
}
