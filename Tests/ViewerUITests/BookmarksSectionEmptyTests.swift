import XCTest
import Foundation
import ViewerCore
@testable import ViewerUI

/// Pure-logic, NO-window assertions about the `BookmarksSection`'s
/// empty-state placeholder strings. These tests do not instantiate the
/// view; they only verify that the well-known placeholder constants
/// exist with stable values so the fixed-envelope behaviour (panel
/// occupies its full body height even with zero bookmarks) keeps
/// surfacing a visible placeholder.
///
/// Safe to run on the host — no NSApp activation, no window. The
/// fact that this file lives under `ViewerUITests` is incidental: the
/// `BookmarksSection` symbol is in `ViewerUI`, so the test target has
/// to be `ViewerUITests` for the `@testable import` to reach it.
/// Filter with:
///   `swift test --filter ViewerUITests.BookmarksSectionEmptyTests`
final class BookmarksSectionEmptyTests: XCTestCase {

    func test_emptyPlaceholder_stringIsStable() {
        // Pin the user-visible string so a casual edit doesn't silently
        // drop the panel's only visible content in the empty state.
        XCTAssertEqual(BookmarksSection.emptyPlaceholder, "No bookmarks yet.")
    }

    func test_emptyFilterPlaceholder_stringIsStable() {
        XCTAssertEqual(BookmarksSection.emptyFilterPlaceholder,
                       "No bookmarks match this filter.")
    }

    /// Sanity: both placeholders are non-empty. A regression that
    /// blanked one to "" would defeat the fixed-envelope point — the
    /// panel would look empty even though it occupies real estate.
    func test_placeholders_areNonEmpty() {
        XCTAssertFalse(BookmarksSection.emptyPlaceholder.isEmpty)
        XCTAssertFalse(BookmarksSection.emptyFilterPlaceholder.isEmpty)
    }

    // MARK: Root-folder scope filter (TSK-307)

    /// `underRoot` keeps the root itself + its descendants, excludes outside
    /// paths, doesn't false-match a sibling sharing the name prefix, and a nil
    /// root is a no-op (so the "R" chip does nothing when no folder is open).
    func test_underRoot_keepsDescendants_excludesSiblingPrefix_nilIsNoOp() {
        let now = Date()
        func bm(_ path: String) -> BookmarkEntry {
            BookmarkEntry(url: URL(fileURLWithPath: path), addedAt: now)
        }
        let all = [
            bm("/proj/src/a.swift"),
            bm("/proj/README.md"),
            bm("/proj"),                // the root itself
            bm("/other/b.txt"),         // outside → excluded
            bm("/proj-sibling/c.txt"),  // shares "/proj" prefix but is NOT under it
        ]
        let scoped = BookmarksSection.underRoot(all, root: URL(fileURLWithPath: "/proj"))
        XCTAssertEqual(
            Set(scoped.map { $0.url.path }),
            ["/proj", "/proj/src/a.swift", "/proj/README.md"],
            "root itself + descendants only; /other and the /proj-sibling false-prefix excluded")
        XCTAssertEqual(BookmarksSection.underRoot(all, root: nil).count, all.count,
                       "nil root (no folder open) is a no-op")
    }
}
