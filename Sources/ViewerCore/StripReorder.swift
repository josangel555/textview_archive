import CoreGraphics
import Foundation

/// Pure geometry for drag-to-reorder in a horizontal strip (the file tab
/// bar and the session tab bar both use it).
///
/// ## Why this is a gesture, not a drag-and-drop payload
///
/// The strip used to reorder via `.onDrag` + `.onDrop` with an
/// `NSItemProvider` carrying an encoded tab id. That round-trip had three
/// failure surfaces the user actually hit (2026-07-27): the same provider
/// also carries `public.file-url` (so the drag reads as a FILE drag and
/// the window-level `.onDrop(of: [.fileURL])` in `ContentView` lights up
/// and tries to open it), the in-strip drop target and that window target
/// compete for the same pointer, and — worst — the whole interaction is
/// INVISIBLE: no insertion indicator, so a user cannot tell reordering is
/// even possible. Measuring the payload proved it round-trips fine, which
/// ruled out the data layer and left the routing/feedback layer.
///
/// Driving the reorder from a `DragGesture` collapses that chain: no
/// pasteboard, no second drop target, and the caret shows exactly where
/// the tab will land. The geometry lives here so it is host-testable —
/// the SwiftUI layer only supplies pointer x and the item frames.
public enum StripReorder {

    /// One item's horizontal extent in the strip's coordinate space.
    /// Widths are NOT assumed uniform: file tabs share a computed width,
    /// but session pills size to their content, so both strips feed real
    /// measured frames rather than an index × width approximation.
    public struct ItemFrame: Equatable, Sendable {
        public let id: UUID
        public let minX: CGFloat
        public let maxX: CGFloat

        public init(id: UUID, minX: CGFloat, maxX: CGFloat) {
            self.id = id
            self.minX = minX
            self.maxX = maxX
        }

        public var midX: CGFloat { (minX + maxX) / 2 }
    }

    /// The GAP the dragged item should be inserted at, in
    /// `TabsState.move(from:to:)` coordinates: an insertion point in the
    /// ORIGINAL array, so it ranges `0...frames.count` (0 = before the
    /// first item, `count` = after the last).
    ///
    /// Counts the items the pointer has passed the midpoint of rather
    /// than scanning for the first miss, so a pointer dragged far beyond
    /// either end clamps naturally to the first/last gap.
    public static func insertionGap(pointerX: CGFloat, frames: [ItemFrame]) -> Int {
        frames.reduce(into: 0) { gap, frame in
            if pointerX >= frame.midX { gap += 1 }
        }
    }

    /// True when dropping at `gap` would leave the item exactly where it
    /// started. BOTH `source` and `source + 1` are no-ops: they are the
    /// gaps on either side of the dragged item itself. Callers use this
    /// to skip the model mutation AND to hide the insertion caret, so a
    /// tab nudged a few points doesn't flash a misleading indicator.
    public static func isNoOp(source: Int, gap: Int) -> Bool {
        gap == source || gap == source + 1
    }

    /// Re-resolve a finished drag against the CURRENT item order.
    ///
    /// A drag is committed by item ID, never by the index captured when it
    /// started: the strip can change underneath a drag (a tab closed by an
    /// external delete, another window, an agent verb), and a stale index
    /// would move the WRONG item. Returns nil when the dragged item is gone
    /// or the drop turns out to be a no-op, so callers can move blindly.
    ///
    /// `gap` is clamped into `0...ids.count` because it was computed from
    /// frames snapshotted at drag start, which may describe more items than
    /// are left.
    public static func resolveMove(itemID: UUID, ids: [UUID], gap: Int)
        -> (source: Int, destination: Int)?
    {
        guard let source = ids.firstIndex(of: itemID) else { return nil }
        let destination = min(max(gap, 0), ids.count)
        guard !isNoOp(source: source, gap: destination) else { return nil }
        return (source, destination)
    }

    /// x of the insertion caret for `gap`, in the same coordinate space
    /// as `frames`. Nil when there is nothing to draw against (no items).
    public static func caretX(gap: Int, frames: [ItemFrame]) -> CGFloat? {
        guard !frames.isEmpty else { return nil }
        if gap <= 0 { return frames[0].minX }
        if gap >= frames.count { return frames[frames.count - 1].maxX }
        return frames[gap].minX
    }
}
