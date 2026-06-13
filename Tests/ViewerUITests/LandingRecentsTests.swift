import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-745: the empty-tab landing surfaces recent files, capped so the welcome
/// screen stays a glanceable launcher (the sidebar's Recent section keeps the
/// full scrollable list). Pins the pure cap; the list RENDER + click-to-open in
/// EmptyStateView are SwiftUI → VM/review (a11y ids mdv.emptyState.recent* in place).
final class LandingRecentsTests: XCTestCase {

    private func entries(_ n: Int) -> [HistoryEntry] {
        (0..<n).map { i in
            HistoryEntry(url: URL(fileURLWithPath: "/r/\(i).md"), kind: .file,
                         lastOpenedAt: Date(timeIntervalSince1970: TimeInterval(n - i)))
        }
    }

    func test_landingRecents_capsToTheLimit_preservingOrder() {
        let all = entries(20)
        let landing = DocumentModel.landingRecents(from: all)
        XCTAssertEqual(landing.count, DocumentModel.landingRecentsCap,
                       "a long recents list is capped for the welcome screen")
        XCTAssertEqual(landing.map(\.id), Array(all.prefix(DocumentModel.landingRecentsCap)).map(\.id),
                       "the cap keeps the newest-first prefix, in order")
    }

    func test_landingRecents_passesThroughWhenUnderCap() {
        let all = entries(3)
        XCTAssertEqual(DocumentModel.landingRecents(from: all).map(\.id), all.map(\.id),
                       "fewer than the cap ⇒ show them all, unchanged")
    }

    func test_landingRecents_emptyWhenNoRecents() {
        XCTAssertTrue(DocumentModel.landingRecents(from: []).isEmpty,
                      "no recents ⇒ empty (the view falls back to the search hint)")
    }
}
