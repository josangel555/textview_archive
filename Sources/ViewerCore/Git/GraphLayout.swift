import Foundation

/// Topological graph layout for `GitClient.GraphCommit` sequences —
/// turns a flat topo-ordered commit list into per-row lane assignments
/// suitable for rendering with a SwiftUI Canvas.
///
/// The algorithm tracks an array of "active lanes" — slots reserved
/// for commits the renderer has not yet drawn. When a commit comes in,
/// it claims an existing slot (placed there by an earlier child) or
/// opens a new slot. Its first parent inherits the slot (vertical
/// line continues); additional parents (merges) get fresh slots.
///
/// The widest graph this returns honors `maxLanes` — when a row would
/// need more, `layout(_:)` returns `nil` so the caller can fall back
/// to a flat list. The spec caps that at 4.
public enum GraphLayout {

    public struct Row: Equatable, Sendable {
        public let commit: GitClient.GraphCommit
        /// Lane this commit's dot sits in.
        public let lane: Int
        /// Active lanes (pending child shas) *before* this commit is
        /// processed. Index = lane; `nil` slot = unused.
        public let lanesBefore: [String?]
        /// Active lanes *after* processing — parents now occupy slots.
        public let lanesAfter: [String?]
    }

    public struct Layout: Equatable, Sendable {
        public let rows: [Row]
        public let maxLane: Int  // 0-based; total width = maxLane + 1
    }

    /// Returns nil if any row would need more than `maxLanes` active
    /// concurrent lanes — caller should render a flat list instead.
    public static func layout(_ commits: [GitClient.GraphCommit], maxLanes: Int = 4) -> Layout? {
        var lanes: [String?] = []
        var rows: [Row] = []
        var observedMax = -1

        for c in commits {
            // 1. Find this commit's lane.
            var myLane = lanes.firstIndex(where: { $0 == c.sha })
            if myLane == nil {
                myLane = firstFree(in: lanes)
                if myLane! == lanes.count { lanes.append(nil) }
            }
            // Cap check (after potential append).
            if lanes.count > maxLanes { return nil }

            let before = lanes

            // 2. Free this commit's lane.
            lanes[myLane!] = nil

            // 3. Place each parent. First parent inherits this commit's
            //    slot when possible; merges spawn new slots.
            for (idx, parent) in c.parents.enumerated() {
                if lanes.contains(parent) { continue }
                if idx == 0 && lanes[myLane!] == nil {
                    lanes[myLane!] = parent
                } else {
                    let free = firstFree(in: lanes)
                    if free == lanes.count { lanes.append(parent) }
                    else { lanes[free] = parent }
                }
            }
            if lanes.count > maxLanes { return nil }

            // 4. Compact: trim trailing nils so `lanes.count` tracks
            //    the actual max-width-after-row. Doesn't reshuffle
            //    indices, just shrinks the tail.
            while lanes.last == .some(nil) { lanes.removeLast() }

            let after = lanes
            rows.append(Row(
                commit: c, lane: myLane!,
                lanesBefore: before, lanesAfter: after
            ))
            observedMax = max(observedMax,
                              max(before.count, after.count) - 1,
                              myLane!)
        }

        return Layout(rows: rows, maxLane: max(observedMax, 0))
    }

    private static func firstFree(in lanes: [String?]) -> Int {
        for (i, v) in lanes.enumerated() where v == nil { return i }
        return lanes.count
    }
}
