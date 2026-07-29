import XCTest
import TestSupport
@testable import ViewerCore

/// TSK-1603 — the graph-layout data the renderer needs to draw a READABLE
/// history: parent EDGES (so a branch's origin/join is visible instead of the
/// line just stopping) and stable BRANCH IDS (so a recycled lane doesn't reuse
/// a color with no way to tell "branch ended" from "very long branch").
final class GraphLayoutEdgesTests: XCTestCase {

    private func c(_ sha: String, _ parents: [String]) -> GitClient.GraphCommit {
        GitClient.GraphCommit(
            sha: sha, parents: parents, author: "t", timestamp: 0,
            subject: sha, refs: [], filesChanged: 0, insertions: 0, deletions: 0)
    }

    /// A merge: M(A,B) → A → B → base. Topo order newest-first.
    private var mergeHistory: [GitClient.GraphCommit] {
        [c("m", ["a", "b"]), c("a", ["base"]), c("b", ["base"]), c("base", [])]
    }

    func test_parentLanes_recordAnEdgeForEveryParent() throws {
        let lay = try XCTUnwrap(GraphLayout.layout(mergeHistory))
        for row in lay.rows {
            XCTAssertEqual(
                row.parentLanes.count, row.commit.parents.count,
                "every parent needs a lane edge so the renderer can connect it "
                + "(row \(row.commit.sha))")
        }
    }

    func test_joinToAnAlreadyPendingLane_isRecorded_notDropped() throws {
        // `a` and `b` share parent `base`. Whichever is processed second finds
        // `base` ALREADY pending in another lane — the old layout dropped that
        // edge entirely and the branch line vanished mid-graph.
        let lay = try XCTUnwrap(GraphLayout.layout(mergeHistory))
        let a = try XCTUnwrap(lay.rows.first { $0.commit.sha == "a" })
        let b = try XCTUnwrap(lay.rows.first { $0.commit.sha == "b" })
        XCTAssertEqual(a.parentLanes.count, 1)
        XCTAssertEqual(b.parentLanes.count, 1)
        // Both must point at a real lane, and at the SAME one (their shared parent).
        XCTAssertGreaterThanOrEqual(a.parentLanes[0], 0)
        XCTAssertGreaterThanOrEqual(b.parentLanes[0], 0)
        XCTAssertEqual(a.parentLanes[0], b.parentLanes[0],
                       "a shared parent lives in ONE lane — both branches join it there")
    }

    func test_mergeRow_edgesPointAtBothParentLanes() throws {
        let lay = try XCTUnwrap(GraphLayout.layout(mergeHistory))
        let m = try XCTUnwrap(lay.rows.first { $0.commit.sha == "m" })
        XCTAssertEqual(m.parentLanes.count, 2, "a merge draws two outgoing edges")
        XCTAssertNotEqual(m.parentLanes[0], m.parentLanes[1],
                          "the two parents occupy DIFFERENT lanes — that's the fork shape")
        XCTAssertTrue(m.parentLanes.contains(m.lane),
                      "the first parent continues the merge commit's own lane")
    }

    func test_branchID_isStableAlongALaneRun() throws {
        // A straight line: every commit continues one branch run.
        let lay = try XCTUnwrap(GraphLayout.layout([
            c("c3", ["c2"]), c("c2", ["c1"]), c("c1", []),
        ]))
        let ids = Set(lay.rows.map(\.branchID))
        XCTAssertEqual(ids.count, 1,
                       "an unbroken first-parent chain is ONE branch run, one color")
    }

    func test_branchID_differsForAReusedLane() throws {
        // Two independent tips that both land in lane 0 at different times:
        // tip1 → base, then an unrelated tip2 → base2. Lane 0 is recycled, so
        // the SECOND occupant must get a different branch id (else the color
        // silently repeats and reads as one long branch).
        let lay = try XCTUnwrap(GraphLayout.layout([
            c("t1", ["p1"]), c("p1", []),      // run A finishes (lane freed)
            c("t2", ["p2"]), c("p2", []),      // run B reuses lane 0
        ]))
        let t1 = try XCTUnwrap(lay.rows.first { $0.commit.sha == "t1" })
        let t2 = try XCTUnwrap(lay.rows.first { $0.commit.sha == "t2" })
        XCTAssertEqual(t1.lane, t2.lane, "precondition: the lane IS recycled")
        XCTAssertNotEqual(t1.branchID, t2.branchID,
                          "a recycled lane starts a NEW branch run → different color")
    }

    func test_branchIDs_areParallelToLaneArrays() throws {
        let lay = try XCTUnwrap(GraphLayout.layout(mergeHistory))
        for row in lay.rows {
            XCTAssertEqual(row.beforeIDs.count, row.lanesBefore.count)
            XCTAssertEqual(row.afterIDs.count, row.lanesAfter.count)
            // An occupied lane always carries an id (the renderer colors by it).
            for (i, sha) in row.lanesAfter.enumerated() where sha != nil {
                XCTAssertNotNil(row.afterIDs[i],
                                "occupied lane \(i) must carry a branch id")
            }
        }
    }

    func test_existingContract_unchanged_lanesAndCap() throws {
        // The pre-existing invariants the renderer already relied on.
        let lay = try XCTUnwrap(GraphLayout.layout(mergeHistory))
        XCTAssertEqual(lay.rows.count, 4)
        XCTAssertEqual(lay.rows.first?.lane, 0, "the newest commit anchors lane 0")
        XCTAssertGreaterThanOrEqual(lay.maxLane, 1, "a merge widens the graph")
        // Over-wide histories still bail out so the caller can go flat. Each
        // tip needs its OWN pending parent to hold a lane open — tips sharing
        // one parent all JOIN that parent's single lane (2 wide, not 10).
        let wide = (0..<6).map { c("tip\($0)", ["p\($0)"]) }
        XCTAssertNil(GraphLayout.layout(wide, maxLanes: 4),
                     "more concurrent lanes than the cap → nil (flat-list fallback)")
        // And the shared-parent case genuinely stays narrow (the join fix).
        let shared = (0..<10).map { c("s\($0)", ["shared"]) }
        let narrow = try XCTUnwrap(GraphLayout.layout(shared, maxLanes: 4))
        XCTAssertLessThanOrEqual(narrow.maxLane, 1,
            "ten tips onto one parent occupy one lane + the parent's, not ten")
        XCTAssertTrue(narrow.rows.allSatisfy { $0.parentLanes == [0] },
            "every tip draws a join edge into the shared parent's lane")
    }
}
