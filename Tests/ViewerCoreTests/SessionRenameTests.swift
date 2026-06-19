import XCTest
@testable import ViewerCore

/// TSK-931 — the rename decision shared by the inline session-tab editor and
/// the menu-bar "Rename Session…" command.
final class SessionRenameTests: XCTestCase {

    func test_appliesNewName() {
        XCTAssertEqual(SessionRename.sanitize("My Work", current: "old"), "My Work")
    }

    func test_trimsSurroundingWhitespace() {
        XCTAssertEqual(SessionRename.sanitize("  Spaced  ", current: "old"), "Spaced")
    }

    func test_rejectsEmpty() {
        XCTAssertNil(SessionRename.sanitize("", current: "old"))
    }

    func test_rejectsWhitespaceOnly() {
        XCTAssertNil(SessionRename.sanitize("   \n ", current: "old"),
            "a stray Enter / blank must not clobber the name")
    }

    func test_rejectsNoOp() {
        XCTAssertNil(SessionRename.sanitize("old", current: "old"))
    }

    func test_rejectsNoOp_afterTrimming() {
        XCTAssertNil(SessionRename.sanitize("  old  ", current: "old"),
            "trims to the current name ⇒ no-op")
    }

    // MARK: defaultDisplayName(forRoot:) — root-URL → title table (TSK-1016) --

    func test_defaultDisplayName_folderName() {
        XCTAssertEqual(
            SessionRename.defaultDisplayName(forRoot: URL(fileURLWithPath: "/Users/me/code/myproj")),
            "myproj")
    }

    func test_defaultDisplayName_trailingSlash() {
        // A folder URL constructed as a directory keeps a trailing slash; the
        // last meaningful component must still come through.
        XCTAssertEqual(
            SessionRename.defaultDisplayName(forRoot: URL(fileURLWithPath: "/Users/me/code/myproj/", isDirectory: true)),
            "myproj")
    }

    func test_defaultDisplayName_rootSlash() {
        XCTAssertEqual(
            SessionRename.defaultDisplayName(forRoot: URL(fileURLWithPath: "/")),
            "Untitled")
    }

    func test_defaultDisplayName_fromPathString_folder() {
        XCTAssertEqual(SessionRename.defaultDisplayName(forRootPath: "/a/b/proj"), "proj")
    }

    func test_defaultDisplayName_fromPathString_trailingSlash() {
        XCTAssertEqual(SessionRename.defaultDisplayName(forRootPath: "/a/b/proj/"), "proj")
    }

    func test_defaultDisplayName_fromPathString_rootSlash() {
        XCTAssertEqual(SessionRename.defaultDisplayName(forRootPath: "/"), "Untitled")
    }

    func test_defaultDisplayName_fromPathString_empty() {
        XCTAssertEqual(SessionRename.defaultDisplayName(forRootPath: ""), "Untitled")
    }

    // MARK: relabelForRootChange — the auto-relabel decision (TSK-1016) -------

    func test_relabel_rootChange_noManualRename_yieldsNewFolderName() {
        // Root changed from /a/old → /a/new, no manual rename: relabel to "new".
        XCTAssertEqual(
            SessionRename.relabelForRootChange(
                newRoot: URL(fileURLWithPath: "/a/new"),
                currentDisplayName: "old",
                displayNameIsUserSet: false),
            "new")
    }

    func test_relabel_rootChange_afterManualRename_keepsManualName() {
        // The user pinned "My Work"; a later root change must NOT clobber it.
        XCTAssertNil(
            SessionRename.relabelForRootChange(
                newRoot: URL(fileURLWithPath: "/a/new"),
                currentDisplayName: "My Work",
                displayNameIsUserSet: true),
            "a manual rename wins — root change must not auto-relabel")
    }

    func test_relabel_rootUnchangedName_isNoOp() {
        // Derived folder name already equals the current name ⇒ nil (no
        // spurious republish / autosave write).
        XCTAssertNil(
            SessionRename.relabelForRootChange(
                newRoot: URL(fileURLWithPath: "/a/proj"),
                currentDisplayName: "proj",
                displayNameIsUserSet: false))
    }

    func test_relabel_rootToSystemRoot_yieldsUntitled() {
        XCTAssertEqual(
            SessionRename.relabelForRootChange(
                newRoot: URL(fileURLWithPath: "/"),
                currentDisplayName: "proj",
                displayNameIsUserSet: false),
            "Untitled")
    }
}
