import XCTest
@testable import ViewerCore

/// Targeted tests for the custom `Tab` Equatable conformance
/// (state-payload comparison is case-only on most cases, but
/// `.loading` and `.preview` carry their URL/contents into the
/// comparison).
final class TabEquatableTests: XCTestCase {

    /// S3-D: two `.loading` tabs (same id, url, viewMode, dirty, and
    /// loading URL) must compare equal. Without the explicit case
    /// they fell into `default → false` and SwiftUI did redundant
    /// diff work on every tick.
    func test_loadingTabs_sameURL_areEqual() {
        let url = URL(fileURLWithPath: "/tmp/x.md")
        let id = UUID()
        let a = Tab(id: id, url: url, state: .loading(url))
        let b = Tab(id: id, url: url, state: .loading(url))
        XCTAssertEqual(a, b)
    }

    /// Different loading URLs differ.
    func test_loadingTabs_differentLoadingURL_areUnequal() {
        let urlA = URL(fileURLWithPath: "/tmp/a.md")
        let urlB = URL(fileURLWithPath: "/tmp/b.md")
        let id = UUID()
        let a = Tab(id: id, url: urlA, state: .loading(urlA))
        let b = Tab(id: id, url: urlA, state: .loading(urlB))
        XCTAssertNotEqual(a, b)
    }

    // MARK: - View-hosting tab kind (WAVE 2b item 1)

    /// Two hosted-view tabs with the same id + title compare equal —
    /// the AnyView payload lives outside ViewerCore so equality is by
    /// the hosted id (+ title) only.
    func test_hostedViewTabs_sameIDAndTitle_areEqual() {
        let hostID = UUID()
        let id = UUID()
        let a = Tab(id: id, state: .hostedView(id: hostID, title: "History: x.swift"))
        let b = Tab(id: id, state: .hostedView(id: hostID, title: "History: x.swift"))
        XCTAssertEqual(a, b)
    }

    /// Different hosted ids differ (distinct embedded views).
    func test_hostedViewTabs_differentHostID_areUnequal() {
        let id = UUID()
        let a = Tab(id: id, state: .hostedView(id: UUID(), title: "History"))
        let b = Tab(id: id, state: .hostedView(id: UUID(), title: "History"))
        XCTAssertNotEqual(a, b)
    }

    /// The tab title surfaces the hosted-view title for the strip.
    func test_hostedViewTab_titleIsHostedTitle() {
        let t = Tab(state: .hostedView(id: UUID(), title: "History: README.md"))
        XCTAssertEqual(t.title, "History: README.md")
        XCTAssertFalse(t.isBlank)
    }
}
