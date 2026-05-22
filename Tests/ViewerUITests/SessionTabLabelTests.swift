import XCTest
@testable import ViewerUI

/// Pure-logic tests for `SessionTabLabel.truncated(_:limit:)`. Lives in
/// ViewerUITests because the helper itself lives in ViewerUI, but does
/// NOT instantiate any SwiftUI / AppKit machinery — safe to run on the
/// host Mac per the CLAUDE.md testing rules.
final class SessionTabLabelTests: XCTestCase {

    func testShortNamePassesThroughUnchanged() {
        XCTAssertEqual(SessionTabLabel.truncated("main"), "main")
        XCTAssertEqual(SessionTabLabel.truncated("worktree-feat-foo"),
                       "worktree-feat-foo")
    }

    func testWhitespaceTrimmed() {
        XCTAssertEqual(SessionTabLabel.truncated("  main  "), "main")
    }

    func testNameAtLimitIsUntouched() {
        let s = String(repeating: "a", count: 32)
        XCTAssertEqual(SessionTabLabel.truncated(s, limit: 32), s)
    }

    func testLongNameMiddleEllipsized() {
        let long = "/Users/me/Documents/workspaces/extremely-long-session-name"
        let out = SessionTabLabel.truncated(long, limit: 20)
        XCTAssertTrue(out.contains("…"), "expected ellipsis, got \(out)")
        // Reserved budget = limit - 1 ellipsis = 19 chars of source
        // material; total length therefore equals `limit`.
        XCTAssertEqual(out.count, 20)
        // Head + tail came from the original string.
        let parts = out.split(separator: "…", maxSplits: 1, omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(long.hasPrefix(String(parts[0])))
        XCTAssertTrue(long.hasSuffix(String(parts[1])))
    }

    func testDegenerateLimitReturnsTrimmedInput() {
        // Limit < 5 disables ellipsization (no room to be useful);
        // the helper just returns the trimmed input.
        let s = "very-long-session-name-here"
        XCTAssertEqual(SessionTabLabel.truncated(s, limit: 3), s)
    }
}
