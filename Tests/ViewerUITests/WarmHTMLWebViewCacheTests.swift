import XCTest
import AppKit
import WebKit
import ViewerCore
@testable import ViewerUI

/// Perf (TSK-1190) host-testable kernel of the warm-WebView cache for the
/// RAW-HTML render pane (`HTMLRenderedView`). The end-to-end "zero WKWebView
/// rebuild across an Editor↔Render switch" proof is `MountProbe.webViewMakes`
/// holding steady, which needs real WebContent processes and so lives in the VM
/// / `MDV_RUN_WEBVIEW_TESTS` lane. THIS suite pins the pure cache logic — stash
/// → take-once retrieve, parented-rejection, LRU eviction — AND the
/// `HTMLRenderedView` wiring (cacheKey derivation, adoptNavigationState) on the
/// bare host gate, so a regression of the mechanism fails without the VM.
///
/// Constructing a bare `WKWebView` is host-safe (no window, no page load); we
/// never call `loadHTMLString`, so no WebContent first-open cost is paid.
@MainActor
final class WarmHTMLWebViewCacheTests: XCTestCase {

    private func makeWebView() -> WKWebView {
        _ = NSApplication.shared
        return WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    private func makeCoordinator() -> HTMLRenderedView.Coordinator {
        HTMLRenderedView.Coordinator()
    }

    // MARK: - Cache kernel (mirror of WarmWebViewCacheTests)

    func test_stashThenRetrieve_roundTripsTheSameWebView() {
        let cache = WarmHTMLWebViewCache(capacity: 4)
        let wv = makeWebView()
        let coord = makeCoordinator()
        coord.lastDocument = "<!DOCTYPE html><html><body><h1>Alpha</h1></body></html>"

        cache.stash(wv, coordinator: coord, forKey: "/tmp/a.html")
        XCTAssertEqual(cache.count, 1)
        XCTAssertTrue(cache.contains("/tmp/a.html"))

        let got = cache.retrieve(forKey: "/tmp/a.html")
        XCTAssertNotNil(got, "a stashed entry must be retrievable by its key")
        XCTAssertTrue(got?.webView === wv, "retrieve must return the SAME WKWebView instance")
        XCTAssertEqual(got?.coordinator.lastDocument,
                       "<!DOCTYPE html><html><body><h1>Alpha</h1></body></html>",
            "the parked coordinator (carrying lastDocument) must round-trip — that's what lets the re-attach skip the reload")
    }

    func test_retrieve_isTakeOnce_soTwoPanesNeverShareAWebView() {
        let cache = WarmHTMLWebViewCache(capacity: 4)
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "/tmp/a.html")

        XCTAssertNotNil(cache.retrieve(forKey: "/tmp/a.html"), "first retrieve hits")
        XCTAssertNil(cache.retrieve(forKey: "/tmp/a.html"),
            "second retrieve must MISS — an entry is removed on hit so no two live panes share one WebView")
        XCTAssertEqual(cache.count, 0)
    }

    func test_retrieve_missForUnknownKey() {
        let cache = WarmHTMLWebViewCache(capacity: 4)
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "/tmp/a.html")
        XCTAssertNil(cache.retrieve(forKey: "/tmp/other.html"))
        XCTAssertEqual(cache.count, 1, "a miss must not disturb the parked entry")
    }

    func test_stash_detachesTheWebViewFromAnySuperview() {
        let cache = WarmHTMLWebViewCache(capacity: 4)
        let wv = makeWebView()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(wv)
        XCTAssertNotNil(wv.superview)

        cache.stash(wv, coordinator: makeCoordinator(), forKey: "/tmp/a.html")
        XCTAssertNil(wv.superview, "stash must detach the WebView from its superview")
        XCTAssertNotNil(cache.retrieve(forKey: "/tmp/a.html"),
            "a detached parked WebView is retrievable")
    }

    func test_retrieve_rejectsAndDropsAReParentedWebView() {
        let cache = WarmHTMLWebViewCache(capacity: 4)
        let wv = makeWebView()
        cache.stash(wv, coordinator: makeCoordinator(), forKey: "/tmp/a.html")
        // Simulate the race: a live pane re-parents the parked WebView.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(wv)

        XCTAssertNil(cache.retrieve(forKey: "/tmp/a.html"),
            "a re-parented WebView must NOT be re-attached")
        XCTAssertEqual(cache.count, 0,
            "a rejected (parented) entry is dropped so it can't be probed again")
    }

    func test_lruEviction_dropsLeastRecentlyStashedBeyondCapacity() {
        let cache = WarmHTMLWebViewCache(capacity: 2)
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "k1")  // tail
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "k2")
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "k3")  // evicts k1

        XCTAssertEqual(cache.count, 2, "the cache must not grow past capacity")
        XCTAssertFalse(cache.contains("k1"), "the least-recently-stashed key is evicted")
        XCTAssertTrue(cache.contains("k2"))
        XCTAssertTrue(cache.contains("k3"))
    }

    func test_reStashSameKey_replacesAndDoesNotDuplicate() {
        let cache = WarmHTMLWebViewCache(capacity: 4)
        let first = makeWebView()
        let second = makeWebView()
        cache.stash(first, coordinator: makeCoordinator(), forKey: "/tmp/a.html")
        cache.stash(second, coordinator: makeCoordinator(), forKey: "/tmp/a.html")

        XCTAssertEqual(cache.count, 1, "re-stashing the same key must replace, not duplicate")
        XCTAssertTrue(cache.retrieve(forKey: "/tmp/a.html")?.webView === second,
            "the latest stash for a key wins")
    }

    func test_removeAll_clearsEverything() {
        let cache = WarmHTMLWebViewCache(capacity: 4)
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "k1")
        cache.stash(makeWebView(), coordinator: makeCoordinator(), forKey: "k2")
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertFalse(cache.contains("k1"))
        XCTAssertFalse(cache.contains("k2"))
    }

    #if DEBUG
    func test_probes_countStashesHitsMissesEvictions() {
        let cache = WarmHTMLWebViewCache(capacity: 1)
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

    // MARK: - HTMLRenderedView wiring (cacheKey + adoptNavigationState)

    func test_cacheKey_isResolvedFilePath() {
        let url = URL(fileURLWithPath: "/tmp/dir/page.html")
        let v = HTMLRenderedView(rawHTML: "<h1>x</h1>", documentURL: url)
        XCTAssertEqual(v.cacheKey, url.resolvingSymlinksInPath().standardizedFileURL.path,
            "the HTML pane parks under the resolved file path — stable across an Editor↔Render toggle and a session switch")
    }

    func test_cacheKey_nilForNonFileURL() {
        // Defensive: a non-file URL produces no key (opts out of the cache)
        // rather than minting a bogus path key.
        let v = HTMLRenderedView(rawHTML: "<h1>x</h1>",
                                 documentURL: URL(string: "https://example.com/x.html")!)
        XCTAssertNil(v.cacheKey)
    }

    func test_adoptNavigationState_copiesTheReloadGateFields() {
        // The make path copies these from the parked coordinator so
        // `updateNSView`'s `lastDocument == document` gate is a no-op (no reload).
        let parked = makeCoordinator()
        parked.lastDocument = "<!DOCTYPE html><body>Doc</body>"
        parked.lastJSEnabled = true
        parked.documentURL = URL(fileURLWithPath: "/tmp/a.html")
        parked.didFinishFirstLoad = true

        let fresh = makeCoordinator()
        fresh.adoptNavigationState(from: parked)

        XCTAssertEqual(fresh.lastDocument, "<!DOCTYPE html><body>Doc</body>",
            "lastDocument must transfer — it's the field the reload gate compares")
        XCTAssertEqual(fresh.lastJSEnabled, true,
            "lastJSEnabled must transfer so a JS-opt-in change while parked is still detected")
        XCTAssertEqual(fresh.documentURL, URL(fileURLWithPath: "/tmp/a.html"))
        XCTAssertTrue(fresh.didFinishFirstLoad,
            "didFinishFirstLoad must transfer so the nav-policy window stays correct without a reload")
    }

    func test_freshCoordinator_startsWithNilCacheKey() {
        // A fresh coordinator opts OUT of the cache until make/update sets the
        // key — so a never-mounted pane's dismantle can't park a bogus entry.
        XCTAssertNil(makeCoordinator().cacheKey)
    }
}
