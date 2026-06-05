import XCTest
@testable import ViewerCore

/// `URLSchemePolicy` is the boundary that the `markdownviewer://` URL
/// handler funnels every path argument through. These tests pin the
/// containment rule (home + per-user temp) so a regression can't
/// re-open the "click a link, read arbitrary file" hole described in
/// `docs/code-review/SECURITY_CONCURRENCY_2026-05-25.md` §1.1.
final class URLSchemePolicyTests: XCTestCase {

    // MARK: - Positive

    func test_pathInHome_accepted() {
        let home = NSHomeDirectory()
        let url = URLSchemePolicy.containedPath(home + "/notes/foo.md")
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.path, home + "/notes/foo.md")
    }

    func test_homeRoot_itself_accepted() {
        let url = URLSchemePolicy.containedPath(NSHomeDirectory())
        XCTAssertNotNil(url)
    }

    func test_tildeExpanded_thenAccepted() {
        let url = URLSchemePolicy.containedPath("~/Documents/foo.md")
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.path.hasPrefix(NSHomeDirectory()) ?? false)
    }

    func test_perUserTemp_accepted() {
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let url = URLSchemePolicy.containedPath(temp + "/scratch.md")
        XCTAssertNotNil(url)
    }

    // MARK: - Negative

    func test_etcPasswd_rejected() {
        XCTAssertNil(URLSchemePolicy.containedPath("/etc/passwd"))
    }

    func test_systemFolder_rejected() {
        XCTAssertNil(URLSchemePolicy.containedPath("/System/Library/CoreServices"))
    }

    func test_otherUserHome_rejected() {
        // Bias to a path that definitely isn't the current user's
        // home prefix. `/Users/_definitely_not_a_user_xyz` lands
        // outside `NSHomeDirectory()` either way.
        XCTAssertNil(URLSchemePolicy.containedPath("/Users/_definitely_not_a_user_xyz/secret"))
    }

    func test_relativePath_rejected() {
        // We refuse to silently resolve against CWD — relative paths
        // in a URL scheme are almost always a bug or smuggle attempt.
        XCTAssertNil(URLSchemePolicy.containedPath("foo/bar"))
        XCTAssertNil(URLSchemePolicy.containedPath("./foo"))
        XCTAssertNil(URLSchemePolicy.containedPath("../foo"))
    }

    func test_empty_rejected() {
        XCTAssertNil(URLSchemePolicy.containedPath(""))
    }

    func test_dotDotTraversalOutOfHome_rejected() {
        // `standardizedFileURL` collapses `..` segments. A path that
        // looks home-prefixed but traverses upward lands outside.
        let attack = NSHomeDirectory() + "/../../../etc/passwd"
        XCTAssertNil(URLSchemePolicy.containedPath(attack))
    }

    func test_siblingDirectoryPrefix_rejected() {
        // `/Usersfoo` must NOT count as inside `/Users`. The trailing-
        // slash check on `home + "/"` is what blocks the prefix attack.
        // We synthesise the test by picking a path that shares a
        // string-prefix with NSHomeDirectory() but isn't a subpath.
        let home = NSHomeDirectory()
        let sibling = home + "_evilsuffix/file"
        XCTAssertNil(URLSchemePolicy.containedPath(sibling))
    }

    func test_tempSiblingDirectoryPrefix_rejected() {
        // `<temp>_evil/...` shares a string-prefix with the per-user temp dir
        // but is NOT inside it. The unanchored `hasPrefix(temp)` arm used to
        // admit it (AUDIT S2 — temp does not end in `/`); the anchored
        // `== temp || hasPrefix(temp + "/")` rejects it.
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.path
        XCTAssertNil(URLSchemePolicy.containedPath(temp + "_evil/loot.md"))
    }
}
