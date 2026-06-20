import XCTest
import AppKit
import WebKit
import ViewerCore
@testable import ViewerUI

/// Perf P1 (TSK-1042) host-testable kernel of the warm-WebView cache that
/// survives a session switch. The end-to-end "zero WKWebView rebuild across a
/// session switch" proof is `MountProbe.webViewMakes == 0`, which needs real
/// WebContent processes and so lives in the VM / `MDV_RUN_WEBVIEW_TESTS` lane
/// (`SessionSwitchPaneRetentionTests`). THIS suite pins the pure cache logic —
/// stash → take-once retrieve, parented-rejection, LRU eviction — on the bare
/// host gate, so a regression of the mechanism fails without the VM.
///
/// Constructing a bare `WKWebView` is host-safe (no window, no page load); we
/// never call `loadHTMLString`, so no WebContent first-open cost is paid.
@MainActor
final class WarmWebViewCacheTests: XCTestCase {

    private func makeWebView() -> WKWebView {
        _ = NSApplication.shared
        return WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    private func makeCoordinator() -> MarkdownRenderedView.Coordinator {
        MarkdownRenderedView.Coordinator()
    }

    func test_stashThenRetrieve_roundTripsTheSameWebView() {
        let cache = WarmWebViewCache(capacity: 4)
        let wv = makeWebView()
        let coord = makeCoordinator()
        coord.lastHTML = "<h1>Alpha</h1>"

        cache.stash(wv, coordinator: coord, forKey: "/tmp/a.md")
        XCTAssertEqual(cache.count, 1)
        XCTAssertTrue(cache.contains("/tmp/a.md"))

        let got = cache.retrieve(forKey: "/tmp/a.md")
        XCTAssertNotNil(got, "a stashed entry must be retrievable by its key")
        XCTAssertTrue(got?.webView === wv, "retrieve must return the SAME WKWebView instance")
        XCTAssertEqual(got?.coordinator.lastHTML, "<h1>Alpha</h1>",
            "the parked coordinator (carrying lastHTML) must round-trip — that's what lets the re-attach skip the reload")
    }

    func test_retrieve_isTakeOnce_soTwoPanesNeverShareAWebView() {
        let cache = WarmWebViewCache(capacity: 4)
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "/tmp/a.md")

        XCTAssertNotNil(cache.retrieve(forKey: "/tmp/a.md"), "first retrieve hits")
        XCTAssertNil(cache.retrieve(forKey: "/tmp/a.md"),
            "second retrieve must MISS — an entry is removed on hit so no two live panes share one WebView")
        XCTAssertEqual(cache.count, 0)
    }

    func test_retrieve_missForUnknownKey() {
        let cache = WarmWebViewCache(capacity: 4)
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "/tmp/a.md")
        XCTAssertNil(cache.retrieve(forKey: "/tmp/other.md"))
        XCTAssertEqual(cache.count, 1, "a miss must not disturb the parked entry")
    }

    func test_stash_detachesTheWebViewFromAnySuperview() {
        // stash() must remove the WebView from its superview so a parked pane
        // is never still on screen.
        let cache = WarmWebViewCache(capacity: 4)
        let wv = makeWebView()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(wv)
        XCTAssertNotNil(wv.superview)

        cache.stash(wv, coordinator: makeCoordinator(), forKey: "/tmp/a.md")
        XCTAssertNil(wv.superview, "stash must detach the WebView from its superview")
        XCTAssertNotNil(cache.retrieve(forKey: "/tmp/a.md"),
            "a detached parked WebView is retrievable")
    }

    func test_retrieve_rejectsAndDropsAReParentedWebView() {
        // Defensive belt-and-suspenders: if something re-parents a parked
        // WebView AFTER it was stashed (a make for path P racing a live pane
        // for P), `retrieve` must refuse to hand it out and drop the entry.
        let cache = WarmWebViewCache(capacity: 4)
        let wv = makeWebView()
        cache.stash(wv, coordinator: makeCoordinator(), forKey: "/tmp/a.md")
        // Simulate the race: a live pane re-parents the parked WebView.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(wv)   // wv.superview != nil while parked

        XCTAssertNil(cache.retrieve(forKey: "/tmp/a.md"),
            "a re-parented WebView must NOT be re-attached")
        XCTAssertEqual(cache.count, 0,
            "a rejected (parented) entry is dropped so it can't be probed again")
    }

    func test_lruEviction_dropsLeastRecentlyStashedBeyondCapacity() {
        let cache = WarmWebViewCache(capacity: 2)
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "k1")  // tail
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "k2")
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "k3")  // evicts k1

        XCTAssertEqual(cache.count, 2, "the cache must not grow past capacity")
        XCTAssertFalse(cache.contains("k1"), "the least-recently-stashed key is evicted")
        XCTAssertTrue(cache.contains("k2"))
        XCTAssertTrue(cache.contains("k3"))
    }

    func test_reStashSameKey_replacesAndDoesNotDuplicate() {
        let cache = WarmWebViewCache(capacity: 4)
        let first = makeWebView()
        let second = makeWebView()
        cache.stash(first, coordinator: makeCoordinator(), forKey: "/tmp/a.md")
        cache.stash(second, coordinator: makeCoordinator(), forKey: "/tmp/a.md")

        XCTAssertEqual(cache.count, 1, "re-stashing the same key must replace, not duplicate")
        XCTAssertTrue(cache.retrieve(forKey: "/tmp/a.md")?.webView === second,
            "the latest stash for a key wins")
    }

    func test_removeAll_clearsEverything() {
        let cache = WarmWebViewCache(capacity: 4)
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "k1")
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "k2")
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertFalse(cache.contains("k1"))
        XCTAssertFalse(cache.contains("k2"))
    }

    func test_adoptNavigationState_copiesTheReloadGateFields() {
        // The make path copies these from the parked coordinator so
        // `updateNSView`'s `lastHTML == html` gate is a no-op (no reload).
        let parked = makeCoordinator()
        parked.lastHTML = "<h1>Doc</h1>"
        parked.currentURL = URL(fileURLWithPath: "/tmp/a.md")
        parked.mermaidInjected = true
        parked.documentReady = true
        parked.didFinishFirstLoad = true
        parked.contentScale = 1.5
        parked.lastAppliedScale = 1.5

        let fresh = makeCoordinator()
        fresh.adoptNavigationState(from: parked)

        XCTAssertEqual(fresh.lastHTML, "<h1>Doc</h1>",
            "lastHTML must transfer — it's the field the reload gate compares")
        XCTAssertEqual(fresh.currentURL, URL(fileURLWithPath: "/tmp/a.md"))
        XCTAssertTrue(fresh.mermaidInjected)
        XCTAssertTrue(fresh.documentReady)
        XCTAssertTrue(fresh.didFinishFirstLoad)
        XCTAssertEqual(fresh.contentScale, 1.5)
        XCTAssertEqual(fresh.lastAppliedScale, 1.5)
    }

    #if DEBUG
    func test_probes_countStashesHitsMissesEvictions() {
        let cache = WarmWebViewCache(capacity: 1)
        cache.resetProbes()
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "k1")
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "k2")  // evicts k1
        _ = cache.retrieve(forKey: "k2")   // hit
        _ = cache.retrieve(forKey: "k1")   // miss (evicted)

        XCTAssertEqual(cache.stashes, 2)
        XCTAssertEqual(cache.evictions, 1)
        XCTAssertEqual(cache.hits, 1)
        XCTAssertEqual(cache.misses, 1)
    }
    #endif
}
