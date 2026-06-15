import XCTest
@testable import ViewerCore

/// TSK-933 — footer path → clickable breadcrumb segments (home collapsed to ~,
/// each segment carrying its cumulative URL for click-to-reveal).
final class BreadcrumbPathTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/me")

    func test_underHome_collapsesToTilde() {
        let segs = BreadcrumbPath.segments(
            for: URL(fileURLWithPath: "/Users/me/proj/f.txt"), home: home)
        XCTAssertEqual(segs.map(\.name), ["~", "proj", "f.txt"])
        XCTAssertEqual(segs.map(\.url.path), ["/Users/me", "/Users/me/proj", "/Users/me/proj/f.txt"])
    }

    func test_outsideHome_showsFromRoot() {
        let segs = BreadcrumbPath.segments(
            for: URL(fileURLWithPath: "/tmp/data/x.csv"), home: home)
        XCTAssertEqual(segs.map(\.name), ["/", "tmp", "data", "x.csv"])
        XCTAssertEqual(segs.map(\.url.path), ["/", "/tmp", "/tmp/data", "/tmp/data/x.csv"])
    }

    func test_homeItself_isSingleTilde() {
        let segs = BreadcrumbPath.segments(for: home, home: home)
        XCTAssertEqual(segs.map(\.name), ["~"])
        XCTAssertEqual(segs.first?.url.path, "/Users/me")
    }

    func test_cumulativeURLs_areAncestors() {
        let segs = BreadcrumbPath.segments(
            for: URL(fileURLWithPath: "/Users/me/a/b/c.md"), home: home)
        // Each segment's URL is a prefix of the next.
        for i in 1..<segs.count {
            XCTAssertTrue(segs[i].url.path.hasPrefix(segs[i - 1].url.path))
        }
        XCTAssertEqual(segs.last?.url.path, "/Users/me/a/b/c.md")
    }

    func test_siblingPrefix_notCollapsed() {
        // "/Users/josX" must NOT be treated as under home "/Users/me".
        let segs = BreadcrumbPath.segments(
            for: URL(fileURLWithPath: "/Users/josX/f.txt"), home: home)
        XCTAssertEqual(segs.first?.name, "/", "a sibling dir is not the home prefix")
    }

    // MARK: - TSK-934 right-click segment actions

    func test_menuActions_folderSegment_getsFolderVerbs() {
        XCTAssertEqual(
            BreadcrumbPath.menuActions(isDirectory: true),
            [.revealInSidebar, .openFolder, .copyPath, .revealInFinder, .openInTerminal])
    }

    func test_menuActions_fileSegment_getsFileVerbs() {
        let actions = BreadcrumbPath.menuActions(isDirectory: false)
        XCTAssertEqual(actions, [.revealInSidebar, .openInDefaultApp, .copyPath, .revealInFinder])
        // A file segment must NOT offer folder-only verbs.
        XCTAssertFalse(actions.contains(.openFolder), "file segment can't 'Open Folder'")
        XCTAssertFalse(actions.contains(.openInTerminal), "file segment can't 'Open in Terminal'")
    }
}
