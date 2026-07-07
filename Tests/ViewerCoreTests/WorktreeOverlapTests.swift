import XCTest
@testable import ViewerCore

/// TSK-1196 — the cross-agent worktree overlap detection.
final class WorktreeOverlapTests: XCTestCase {

    private func wt(_ branch: String, _ files: [String], merged: Bool = false)
        -> WorktreeOverlap.Worktree {
        .init(branch: branch, path: "/wt/\(branch)", changedFiles: Set(files), merged: merged)
    }

    func test_whoTouches_listsUnmergedBranches() {
        let trees = [
            wt("agent-a", ["Sources/DocumentModel.swift", "a.swift"]),
            wt("agent-b", ["Sources/DocumentModel.swift", "b.swift"]),
            wt("agent-c", ["c.swift"]),
        ]
        XCTAssertEqual(
            WorktreeOverlap.whoTouches("Sources/DocumentModel.swift", in: trees),
            ["agent-a", "agent-b"])
        XCTAssertEqual(WorktreeOverlap.whoTouches("c.swift", in: trees), ["agent-c"])
        XCTAssertEqual(WorktreeOverlap.whoTouches("nope.swift", in: trees), [])
    }

    func test_overlaps_flagsSharedFiles() {
        let trees = [
            wt("agent-a", ["shared.swift", "onlyA.swift"]),
            wt("agent-b", ["shared.swift", "onlyB.swift"]),
        ]
        let hits = WorktreeOverlap.overlaps(trees)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].path, "shared.swift")
        XCTAssertEqual(hits[0].branches, ["agent-a", "agent-b"])
    }

    func test_mergedWorktree_isExcluded() {
        // agent-a is already merged — a fresh agent-b touching the same file
        // is building ON it, not colliding.
        let trees = [
            wt("agent-a", ["shared.swift"], merged: true),
            wt("agent-b", ["shared.swift"]),
        ]
        XCTAssertEqual(WorktreeOverlap.overlaps(trees), [], "a merged worktree isn't an active overlap")
        XCTAssertEqual(WorktreeOverlap.whoTouches("shared.swift", in: trees), ["agent-b"])
    }

    func test_threeWayOverlap_listsAll() {
        let trees = [
            wt("a", ["hot.swift"]), wt("b", ["hot.swift"]), wt("c", ["hot.swift"]),
        ]
        XCTAssertEqual(WorktreeOverlap.overlaps(trees).first?.branches, ["a", "b", "c"])
    }

    func test_report_cleanVsOverlap() {
        XCTAssertEqual(WorktreeOverlap.report([wt("a", ["x.swift"]), wt("b", ["y.swift"])]),
                       "no cross-worktree file overlap")
        let r = WorktreeOverlap.report([wt("a", ["z.swift"]), wt("b", ["z.swift"])])
        XCTAssertTrue(r.contains("z.swift"))
        XCTAssertTrue(r.contains("a, b"))
        XCTAssertTrue(r.hasPrefix("⚠︎"))
    }

    func test_noWorktrees_noOverlap() {
        XCTAssertEqual(WorktreeOverlap.overlaps([]), [])
        XCTAssertEqual(WorktreeOverlap.report([]), "no cross-worktree file overlap")
    }
}
