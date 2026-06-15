import XCTest
@testable import ViewerCore

/// TSK-919 — a folder dragged from the nav and dropped back in the same window
/// must not re-root if it's the current root or a descendant (the self/sub-folder
/// drag trap); an external folder still re-roots.
final class DropReRootPolicyTests: XCTestCase {

    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }

    func test_noRootYet_opensTheFolder() {
        XCTAssertTrue(DropReRootPolicy.shouldReRoot(folder: u("/a/b"), currentRoot: nil))
    }

    func test_currentRootItself_doesNotReRoot() {
        XCTAssertFalse(DropReRootPolicy.shouldReRoot(folder: u("/a"), currentRoot: u("/a")))
    }

    func test_descendant_doesNotReRoot() {
        XCTAssertFalse(DropReRootPolicy.shouldReRoot(folder: u("/a/b"), currentRoot: u("/a")),
            "dragging a subfolder back in must not re-root (the trap)")
        XCTAssertFalse(DropReRootPolicy.shouldReRoot(folder: u("/a/b/c"), currentRoot: u("/a")))
    }

    func test_externalSiblingOrParent_reRoots() {
        XCTAssertTrue(DropReRootPolicy.shouldReRoot(folder: u("/x"), currentRoot: u("/a")))
        XCTAssertTrue(DropReRootPolicy.shouldReRoot(folder: u("/"), currentRoot: u("/a")),
            "a parent folder is a legitimate re-root")
    }

    func test_siblingPrefixCollision_isNotADescendant() {
        // "/ab" must not be treated as under "/a" (component-wise check).
        XCTAssertTrue(DropReRootPolicy.shouldReRoot(folder: u("/ab"), currentRoot: u("/a")))
    }

    func test_trailingSlashNormalized() {
        XCTAssertFalse(DropReRootPolicy.shouldReRoot(folder: u("/a/"), currentRoot: u("/a")))
    }
}
