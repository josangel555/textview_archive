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

        /// TSK-1603 — the lane each PARENT occupies after this row, in
        /// `commit.parents` order. This is the edge data the renderer needs to
        /// draw the fork/merge connection: previously a parent that was
        /// ALREADY pending in another lane recorded nothing, so the branch line
        /// simply stopped mid-graph with no visible join ("hard to see where
        /// the branch originates"). `-1` marks a parent outside the loaded
        /// window (the graph's bottom edge).
        public let parentLanes: [Int]

        /// TSK-1603 — stable identity for the RUN of commits occupying this
        /// commit's lane. Lane indices get recycled, so coloring by lane made
        /// a finished branch and a brand-new one share a color with no way to
        /// tell them apart ("did a branch end and the color got reused, or is
        /// this one very long line?"). A branch id is minted whenever a lane is
        /// newly occupied, so consecutive occupants of one lane differ.
        public let branchID: Int
        /// Branch ids parallel to `lanesBefore` / `lanesAfter`.
        public let beforeIDs: [Int?]
        public let afterIDs: [Int?]
    }

    public struct Layout: Equatable, Sendable {
        public let rows: [Row]
        public let maxLane: Int  // 0-based; total width = maxLane + 1
    }

    /// Returns nil if any row would need more than `maxLanes` active
    /// concurrent lanes — caller should render a flat list instead.
    public static func layout(_ commits: [GitClient.GraphCommit], maxLanes: Int = 4) -> Layout? {
        var lanes: [String?] = []
        /// Branch id per lane index, parallel to `lanes` (nil = free slot).
        var laneIDs: [Int?] = []
        var nextBranchID = 0
        var rows: [Row] = []
        var observedMax = -1

        /// Occupy `lane` with `sha`, minting a fresh branch id unless the lane
        /// is INHERITING an existing run (the first-parent continuation).
        func occupy(_ lane: Int, _ sha: String, inheriting id: Int?) {
            while laneIDs.count < lanes.count { laneIDs.append(nil) }
            lanes[lane] = sha
            if let id {
                laneIDs[lane] = id
            } else {
                laneIDs[lane] = nextBranchID
                nextBranchID += 1
            }
        }

        for c in commits {
            // 1. Find this commit's lane.
            var myLane = lanes.firstIndex(where: { $0 == c.sha })
            if myLane == nil {
                myLane = firstFree(in: lanes)
                if myLane! == lanes.count { lanes.append(nil) }
            }
            // Cap check (after potential append).
            if lanes.count > maxLanes { return nil }
            while laneIDs.count < lanes.count { laneIDs.append(nil) }

            // A commit landing in a previously-unused lane starts a new branch
            // run (a tip); one claimed by a child inherits that run's id.
            let myBranchID: Int
            if let existing = laneIDs[myLane!] {
                myBranchID = existing
            } else {
                myBranchID = nextBranchID
                nextBranchID += 1
                laneIDs[myLane!] = myBranchID
            }

            let before = lanes
            let beforeIDs = laneIDs

            // 2. Free this commit's lane.
            lanes[myLane!] = nil
            laneIDs[myLane!] = nil

            // 3. Place each parent, RECORDING the lane it lands in so the
            //    renderer can draw the connecting edge (TSK-1603). First
            //    parent inherits this commit's slot + branch run when
            //    possible; merges spawn new slots (and new branch ids).
            var parentLanes: [Int] = []
            for (idx, parent) in c.parents.enumerated() {
                if let existing = lanes.firstIndex(of: parent) {
                    // Parent already pending in another lane: the branch JOINS
                    // it here. Previously this recorded nothing and the line
                    // vanished; now the edge is explicit.
                    parentLanes.append(existing)
                    continue
                }
                if idx == 0 && lanes[myLane!] == nil {
                    occupy(myLane!, parent, inheriting: myBranchID)
                    parentLanes.append(myLane!)
                } else {
                    var free = firstFree(in: lanes)
                    if free == lanes.count {
                        lanes.append(nil)
                        laneIDs.append(nil)
                        free = lanes.count - 1
                    }
                    occupy(free, parent, inheriting: nil)
                    parentLanes.append(free)
                }
            }
            if lanes.count > maxLanes { return nil }

            // 4. Compact: trim trailing nils so `lanes.count` tracks
            //    the actual max-width-after-row. Doesn't reshuffle
            //    indices, just shrinks the tail.
            while lanes.last == .some(nil) {
                lanes.removeLast()
                if laneIDs.count > lanes.count { laneIDs.removeLast() }
            }
            while laneIDs.count > lanes.count { laneIDs.removeLast() }

            let after = lanes
            rows.append(Row(
                commit: c, lane: myLane!,
                lanesBefore: before, lanesAfter: after,
                parentLanes: parentLanes,
                branchID: myBranchID,
                beforeIDs: beforeIDs, afterIDs: laneIDs
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
