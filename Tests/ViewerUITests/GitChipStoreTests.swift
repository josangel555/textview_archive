import XCTest
@testable import ViewerUI
import ViewerCore

/// TSK-734: the git-chip menu must read branch/worktree data from an off-main
/// cache, never spawn `git` synchronously in the SwiftUI Menu builder (that
/// crashed via a nested runloop inside the layout commit). These pin the cache
/// contract: empty before load, populated by `load()` via the injectable
/// enumerator, replaced per root. A counting fake stands in for the real
/// off-main `GitClient` enumeration.
@MainActor
final class GitChipStoreTests: XCTestCase {

    private actor Calls {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    func test_cacheIsEmptyBeforeLoad_soMenuBuildSpawnsNothing() {
        let store = GitChipStore()
        XCTAssertEqual(store.branches, [], "a menu built before load reads an empty cache — zero git work")
        XCTAssertEqual(store.worktrees, [])
        XCTAssertNil(store.loadedRoot)
    }

    func test_load_invokesEnumerateOnce_andPublishesResult() async {
        let store = GitChipStore()
        let calls = Calls()
        store.enumerate = { _ in
            await calls.bump()
            return (["main", "feature/x"], [])
        }
        let root = URL(fileURLWithPath: "/tmp/repo-a")
        await store.load(root: root)

        XCTAssertEqual(store.branches, ["main", "feature/x"], "load must publish the enumerated branches")
        XCTAssertEqual(store.loadedRoot, root)
        let n = await calls.count
        XCTAssertEqual(n, 1, "load runs the git enumeration exactly once")
    }

    func test_load_secondRoot_replacesCache() async {
        let store = GitChipStore()
        store.enumerate = { root in
            root.lastPathComponent == "a" ? (["a-main"], []) : (["b-main", "b-dev"], [])
        }
        await store.load(root: URL(fileURLWithPath: "/tmp/a"))
        XCTAssertEqual(store.branches, ["a-main"])
        await store.load(root: URL(fileURLWithPath: "/tmp/b"))
        XCTAssertEqual(store.branches, ["b-main", "b-dev"], "cache replaced for the new root")
        XCTAssertEqual(store.loadedRoot?.lastPathComponent, "b")
    }
}
