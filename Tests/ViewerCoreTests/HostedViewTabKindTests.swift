import XCTest
@testable import ViewerCore
import ViewerKit

/// WAVE 2b item 2 — the view-hosting tab kind at the ViewerCore layer.
/// Host-safe (pure value, no SwiftUI / no app launch). The `AnyView`
/// payload lives in the UI layer's registry (`DocumentModel.hostedViews`);
/// here `DocumentState.hostedView(id:title:)` carries only the identity
/// (a UUID key) + the tab-strip title. Pins:
///
///   - `Tab.title` reads the hosted title (not the file leaf — there's
///     no URL);
///   - a hosted tab is NOT blank (so it isn't treated as the reusable
///     scratch tab);
///   - `DocumentState`/`Tab` Equatable on a hosted tab is IDENTITY-based
///     (same id+title ⇒ equal; different id ⇒ not equal) — the property
///     the SwiftUI ForEach diff relies on;
///   - a hosted tab carries no URL (the session-snapshot exclusion: the
///     persistence layer skips tabs with `url == nil`).
final class HostedViewTabKindTests: XCTestCase {

    // MARK: - DocumentState

    func test_hostedView_state_title_and_equality() {
        let id = UUID()
        let a = DocumentState.hostedView(id: id, title: "History: a.txt")
        let b = DocumentState.hostedView(id: id, title: "History: a.txt")
        XCTAssertEqual(a, b, "same id + title ⇒ equal")

        let differentID = DocumentState.hostedView(id: UUID(), title: "History: a.txt")
        XCTAssertNotEqual(a, differentID, "different hosted id ⇒ not equal")

        let differentTitle = DocumentState.hostedView(id: id, title: "History: b.txt")
        XCTAssertNotEqual(a, differentTitle, "different title ⇒ not equal")
    }

    func test_hostedView_notEqualToOtherStates() {
        let hosted = DocumentState.hostedView(id: UUID(), title: "X")
        XCTAssertNotEqual(hosted, .empty)
        XCTAssertNotEqual(hosted, .loading(URL(fileURLWithPath: "/tmp/x")))
        XCTAssertNotEqual(hosted, .preview(URL(fileURLWithPath: "/tmp/x"), .image))
    }

    // MARK: - Tab integration

    func test_tab_title_readsHostedTitle() {
        let tab = Tab(state: .hostedView(id: UUID(), title: "History: README.md"),
                      viewMode: .source)
        XCTAssertEqual(tab.title, "History: README.md")
    }

    func test_hostedTab_isNotBlank() {
        // A hosted tab has no URL but is NOT the reusable blank scratch
        // tab (which is url==nil AND state==.empty). Misclassifying it as
        // blank would let "open a file" recycle the History tab.
        let tab = Tab(state: .hostedView(id: UUID(), title: "X"), viewMode: .source)
        XCTAssertFalse(tab.isBlank)
        XCTAssertNil(tab.url, "hosted tabs are not file-backed")
    }

    func test_hostedTab_equality_isIdentityBased() {
        let hostID = UUID()
        let t1 = Tab(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                     state: .hostedView(id: hostID, title: "X"), viewMode: .source)
        // Same Tab id + same hosted payload ⇒ equal.
        let t1Copy = Tab(id: t1.id, state: .hostedView(id: hostID, title: "X"),
                         viewMode: .source)
        XCTAssertEqual(t1, t1Copy)

        // Same Tab id but a DIFFERENT hosted id ⇒ not equal (the hosted
        // payload is part of the discriminator so a re-hosted tab
        // re-renders).
        let t1Rehosted = Tab(id: t1.id,
                             state: .hostedView(id: UUID(), title: "X"),
                             viewMode: .source)
        XCTAssertNotEqual(t1, t1Rehosted)

        // Different Tab id ⇒ not equal regardless of payload.
        let t2 = Tab(id: UUID(), state: .hostedView(id: hostID, title: "X"),
                     viewMode: .source)
        XCTAssertNotEqual(t1, t2)
    }

    func test_hostedTab_excludedFromPersistence_byNilURL() {
        // The session snapshotter only persists tabs whose `url` is set
        // (it maps `t.url` and skips nil). A hosted tab has url==nil, so
        // it is structurally excluded — assert that invariant here so a
        // regression that gives hosted tabs a synthetic URL is caught.
        let hosted = Tab(state: .hostedView(id: UUID(), title: "History"),
                         viewMode: .source)
        XCTAssertNil(hosted.url)

        let fileTab = Tab(url: URL(fileURLWithPath: "/tmp/a.md"),
                          state: .empty, viewMode: .rendered)
        let persistable = [hosted, fileTab].filter { $0.url != nil }
        XCTAssertEqual(persistable.count, 1)
        XCTAssertEqual(persistable.first?.url?.lastPathComponent, "a.md")
    }
}
