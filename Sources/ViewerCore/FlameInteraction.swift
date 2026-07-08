import Foundation
import CoreGraphics

/// TSK-1158 — the flame chart's INTERACTION math, pure over `FlameProfile` /
/// `FlameLayout` (the DependencyGraphInteraction mold): click hit-test,
/// zoom-to-frame with a breadcrumb trail, the classic flamegraph search
/// (matched ids + non-overlapping matched weight), and tooltip text. The
/// SwiftUI canvas + gesture wiring is the render tail; a wrong zoom root or
/// double-counted search weight is caught HERE on the host.
public enum FlameInteraction {

    /// The cell whose rect contains `point`. Cells never overlap (the layout
    /// tiles rows), so the first hit is THE hit; `nil` = empty canvas.
    public static func cell(
        at point: CGPoint, cells: [FlameLayout.Cell]
    ) -> FlameLayout.Cell? {
        cells.first { $0.rect.contains(point) }
    }

    /// Resolve a frame by its stable path id (`;`-joined names root→frame).
    /// Walks the tree by path segments — O(depth · siblings), no full scan.
    public static func frame(
        withID id: String, in profile: FlameProfile
    ) -> FlameProfile.Frame? {
        guard !id.isEmpty else { return nil }
        var current = profile.root
        for segment in id.split(separator: ";", omittingEmptySubsequences: false) {
            guard let next = current.children.first(where: { $0.name == segment }) else {
                return nil
            }
            current = next
        }
        return current
    }

    /// Zoom the chart to `id` (the flame-graph click): the frame becomes the
    /// sole child of a fresh synthetic root, so `FlameLayout.lay` spans it
    /// across the full width. Frame ids inside the subtree are UNCHANGED
    /// (they stay root-relative), so search highlights survive the zoom.
    /// `breadcrumb` is the name trail root→frame for the escape UI.
    public static func zoomed(
        to id: String, in profile: FlameProfile
    ) -> (profile: FlameProfile, breadcrumb: [String])? {
        guard let target = frame(withID: id, in: profile) else { return nil }
        let root = FlameProfile.Frame(
            name: "", total: target.total, selfWeight: 0,
            children: [target], id: "")
        let crumbs = id.split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)
        return (FlameProfile(root: root, malformedLineCount: profile.malformedLineCount),
                crumbs)
    }

    /// The classic flamegraph search: every frame whose name contains
    /// `query` (case-insensitive) → the id set for highlighting, plus the
    /// MATCHED WEIGHT — counted over TOPMOST matches only (a match inside an
    /// already-matched subtree adds nothing), so the "X% matched" figure
    /// never double-counts.
    public static func matches(
        query: String, in profile: FlameProfile
    ) -> (ids: Set<String>, matchedTotal: Int64) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return ([], 0) }
        var ids: Set<String> = []
        var total: Int64 = 0
        func walk(_ frame: FlameProfile.Frame, insideMatch: Bool) {
            let hit = frame.name.lowercased().contains(q)
            if hit {
                ids.insert(frame.id)
                if !insideMatch { total += frame.total }
            }
            for child in frame.children {
                walk(child, insideMatch: insideMatch || hit)
            }
        }
        for child in profile.root.children { walk(child, insideMatch: false) }
        return (ids, total)
    }

    /// Tooltip / status-bar line: name, subtree weight with its share of the
    /// profile, and self weight. Percentages to one decimal.
    public static func tooltip(
        for frame: FlameProfile.Frame, profileTotal: Int64
    ) -> String {
        func pct(_ value: Int64) -> String {
            guard profileTotal > 0 else { return "0%" }
            return String(format: "%.1f%%", Double(value) / Double(profileTotal) * 100)
        }
        return "\(frame.name) — total \(frame.total) (\(pct(frame.total))), "
            + "self \(frame.selfWeight) (\(pct(frame.selfWeight)))"
    }
}
