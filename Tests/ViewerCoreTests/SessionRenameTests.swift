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
}
