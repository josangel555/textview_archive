import XCTest
import AppKit
import WebKit
import ViewerCore
@testable import ViewerUI

/// Perf P1-followup (TSK-1047) host-testable kernel of the warm-EDITOR-WebView
/// cache that survives a session/tab switch, so a returning CM6 editor tab
/// re-attaches its existing WebView (keeping its loaded document + scroll)
/// instead of reloading CM6 at the top of the file.
///
/// The end-to-end "zero CM6 rebuild + on-screen scroll restored across a switch"
/// proof needs real WebContent processes and a GUI session, so it lives in the
/// VM lane (`ScrollRestoreUATTests` SCROLL03/04). THIS suite pins the pure cache
/// logic — stash → take-once retrieve, the LIVE-STATE text-consistency guard, the
/// parented-rejection, LRU eviction, and `adoptState` — on the bare host gate, so
/// a regression of the mechanism (especially the data-loss-class text guard)
/// fails WITHOUT the VM.
///
/// Constructing a bare `WKWebView` is host-safe (no window, no page load); we
/// never call `loadHTMLString`/`loadFileURL`, so no WebContent first-open cost is
/// paid. Mirrors `WarmWebViewCacheTests` (the rendered twin).
@MainActor
final class WarmEditorWebViewCacheTests: XCTestCase {

    private func makeWebView() -> WKWebView {
        _ = NSApplication.shared
        return WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    }

    private func makeCoordinator() -> CodeMirrorEditorView.Coordinator {
        CodeMirrorEditorView.Coordinator()
    }

    // MARK: - Round-trip

    func test_stashThenRetrieve_roundTripsTheSameWebView_whenTextMatches() {
        let cache = WarmEditorWebViewCache(capacity: 4)
        let wv = makeWebView()
        let coord = makeCoordinator()

        cache.stash(wv, coordinator: coord, text: "let x = 1\n", forKey: "/tmp/a.swift")
        XCTAssertEqual(cache.count, 1)
        XCTAssertTrue(cache.contains("/tmp/a.swift"))

        // Re-attach only when the model's text matches the parked CM6's text.
        let got = cache.retrieve(forKey: "/tmp/a.swift", expectedText: "let x = 1\n")
        XCTAssertNotNil(got, "a stashed entry must be retrievable when text matches")
        XCTAssertTrue(got?.webView === wv, "retrieve must return the SAME WKWebView instance")
        XCTAssertTrue(got?.coordinator === coord, "the parked coordinator must round-trip")
        XCTAssertEqual(got?.parkedText, "let x = 1\n")
    }

    // MARK: - The LIVE-STATE safety guard (the crux — data-loss class)

    func test_retrieve_rejectsAndDropsEntry_whenParkedTextDiverges() {
        // THE invariant: a re-attach must NEVER resurrect stale text or mask an
        // edit the model holds. If the model's text has diverged from the parked
        // CM6's text (file changed on disk, session re-hydrated the buffer
        // differently, same path edited elsewhere), the parked editor is DROPPED
        // and the caller builds fresh against the model's (correct) text.
        let cache = WarmEditorWebViewCache(capacity: 4)
        let wv = makeWebView()
        cache.stash(wv, coordinator: makeCoordinator(),
                    text: "original\n", forKey: "/tmp/a.swift")

        let got = cache.retrieve(forKey: "/tmp/a.swift",
                                 expectedText: "MODEL HAS DIFFERENT TEXT\n")
        XCTAssertNil(got, "a text mismatch must NOT re-attach (no stale text / no masked edits)")
        XCTAssertEqual(cache.count, 0,
            "a text-rejected entry is dropped so it can't be probed again with the same stale text")
    }

    func test_retrieve_matchesExactly_notByPrefixOrWhitespace() {
        // The guard is byte-exact: a one-character difference (an in-flight edit
        // that hasn't reached the model yet, or vice-versa) must reject.
        let cache = WarmEditorWebViewCache(capacity: 4)
        cache.stash(makeWebView(), coordinator: makeCoordinator(),
                    text: "abc", forKey: "k")
        XCTAssertNil(cache.retrieve(forKey: "k", expectedText: "abc "),
            "trailing whitespace difference must reject")

        cache.stash(makeWebView(), coordinator: makeCoordinator(),
                    text: "abc", forKey: "k")
        XCTAssertNil(cache.retrieve(forKey: "k", expectedText: "ab"),
            "a prefix is not a match — exact equality only")

        cache.stash(makeWebView(), coordinator: makeCoordinator(),
                    text: "", forKey: "k")
        XCTAssertNotNil(cache.retrieve(forKey: "k", expectedText: ""),
            "an empty parked doc matches an empty expected doc (never-edited file)")
    }

    // MARK: - Take-once

    func test_retrieve_isTakeOnce_soTwoPanesNeverShareAWebView() {
        let cache = WarmEditorWebViewCache(capacity: 4)
        cache.stash(makeWebView(), coordinator: makeCoordinator(),
                    text: "t", forKey: "/tmp/a.swift")

        XCTAssertNotNil(cache.retrieve(forKey: "/tmp/a.swift", expectedText: "t"),
            "first retrieve hits")
        XCTAssertNil(cache.retrieve(forKey: "/tmp/a.swift", expectedText: "t"),
            "second retrieve must MISS — an entry is removed on hit so no two live panes share one editor WebView")
        XCTAssertEqual(cache.count, 0)
    }

    func test_retrieve_missForUnknownKey() {
        let cache = WarmEditorWebViewCache(capacity: 4)
        cache.stash(makeWebView(), coordinator: makeCoordinator(),
                    text: "t", forKey: "/tmp/a.swift")
        XCTAssertNil(cache.retrieve(forKey: "/tmp/other.swift", expectedText: "t"))
        XCTAssertEqual(cache.count, 1, "a miss must not disturb the parked entry")
    }

    // MARK: - Detach / parented-rejection

    func test_stash_detachesTheWebViewFromAnySuperview() {
        let cache = WarmEditorWebViewCache(capacity: 4)
        let wv = makeWebView()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(wv)
        XCTAssertNotNil(wv.superview)

        cache.stash(wv, coordinator: makeCoordinator(), text: "t", forKey: "/tmp/a.swift")
        XCTAssertNil(wv.superview, "stash must detach the WebView from its superview")
        XCTAssertNotNil(cache.retrieve(forKey: "/tmp/a.swift", expectedText: "t"))
    }

    func test_retrieve_rejectsAndDropsAReParentedWebView() {
        // A make for path P racing a not-yet-dismantled live pane for P: the
        // parked WebView is still on screen → refuse to hand it out, drop it.
        let cache = WarmEditorWebViewCache(capacity: 4)
        let wv = makeWebView()
        cache.stash(wv, coordinator: makeCoordinator(), text: "t", forKey: "/tmp/a.swift")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(wv)   // wv.superview != nil while parked

        XCTAssertNil(cache.retrieve(forKey: "/tmp/a.swift", expectedText: "t"),
            "a re-parented WebView must NOT be re-attached even when text matches")
        XCTAssertEqual(cache.count, 0,
            "a rejected (parented) entry is dropped so it can't be probed again")
    }

    // MARK: - Bounded

    func test_lruEviction_dropsLeastRecentlyStashedBeyondCapacity() {
        let cache = WarmEditorWebViewCache(capacity: 2)
        cache.stash(makeWebView(), coordinator: makeCoordinator(), text: "1", forKey: "k1")  // tail
        cache.stash(makeWebView(), coordinator: makeCoordinator(), text: "2", forKey: "k2")
        cache.stash(makeWebView(), coordinator: makeCoordinator(), text: "3", forKey: "k3")  // evicts k1

        XCTAssertEqual(cache.count, 2, "the cache must not grow past capacity")
        XCTAssertFalse(cache.contains("k1"), "the least-recently-stashed key is evicted")
        XCTAssertTrue(cache.contains("k2"))
        XCTAssertTrue(cache.contains("k3"))
    }

    func test_reStashSameKey_replacesAndDoesNotDuplicate() {
        let cache = WarmEditorWebViewCache(capacity: 4)
        let first = makeWebView()
        let second = makeWebView()
        cache.stash(first, coordinator: makeCoordinator(), text: "old", forKey: "/tmp/a.swift")
        cache.stash(second, coordinator: makeCoordinator(), text: "new", forKey: "/tmp/a.swift")

        XCTAssertEqual(cache.count, 1, "re-stashing the same key must replace, not duplicate")
        let got = cache.retrieve(forKey: "/tmp/a.swift", expectedText: "new")
        XCTAssertTrue(got?.webView === second, "the latest stash for a key wins")
    }

    func test_removeAll_clearsEverything() {
        let cache = WarmEditorWebViewCache(capacity: 4)
        cache.stash(makeWebView(), coordinator: makeCoordinator(), text: "1", forKey: "k1")
        cache.stash(makeWebView(), coordinator: makeCoordinator(), text: "2", forKey: "k2")
        cache.removeAll()
        XCTAssertEqual(cache.count, 0)
        XCTAssertFalse(cache.contains("k1"))
        XCTAssertFalse(cache.contains("k2"))
    }

    // MARK: - Coordinator currentText + adoptState

    func test_currentText_mirrorsLastSentText() {
        let coord = makeCoordinator()
        XCTAssertEqual(coord.currentText, "",
            "a never-loaded editor reports empty text (so it can still be parked/retrieved)")
        coord._test_setLastSentText("edited body\n")
        XCTAssertEqual(coord.currentText, "edited body\n",
            "currentText must mirror the live CM6 doc (lastSentText) — the parked-text source")
    }

    func test_adoptState_copiesReloadGateMirrors_soReAttachDoesNotResetTheDoc() {
        // The make path adopts these from the parked coordinator so
        // `applyPendingState` sees the already-loaded CM6 as fully in-sync — no
        // redundant setText (which would reset the caret/scroll we preserve) and
        // no re-fire of the once-per-mount selection seed against the live doc.
        let parked = makeCoordinator()
        parked._test_setLastSentText("doc text\n")
        parked._test_setReady(true)
        parked._test_didApplyInitialSelection = true

        let fresh = makeCoordinator()
        XCTAssertFalse(fresh._test_isReady, "precondition: fresh coordinator not yet ready")
        fresh.adoptState(from: parked)

        XCTAssertEqual(fresh.currentText, "doc text\n",
            "lastSentText must transfer — it's what suppresses a redundant setText on re-attach")
        XCTAssertTrue(fresh._test_isReady,
            "isReady must transfer so post-load state pushes resume immediately, no ready round-trip")
        XCTAssertTrue(fresh._test_didApplyInitialSelection,
            "the once-per-mount seed-applied flag must transfer so the seed doesn't re-fire and clobber the preserved scroll")
    }

    #if DEBUG
    func test_probes_countStashesHitsMissesTextRejectionsEvictions() {
        let cache = WarmEditorWebViewCache(capacity: 1)
        cache.resetProbes()
        cache.stash(makeWebView(), coordinator: makeCoordinator(), text: "1", forKey: "k1")
        cache.stash(makeWebView(), coordinator: makeCoordinator(), text: "2", forKey: "k2")  // evicts k1
        _ = cache.retrieve(forKey: "k2", expectedText: "2")   // hit
        _ = cache.retrieve(forKey: "k1", expectedText: "1")   // miss (evicted)
        cache.stash(makeWebView(), coordinator: makeCoordinator(), text: "3", forKey: "k3")
        _ = cache.retrieve(forKey: "k3", expectedText: "STALE")  // text rejection

        XCTAssertEqual(cache.stashes, 3)
        XCTAssertEqual(cache.evictions, 1)
        XCTAssertEqual(cache.hits, 1)
        XCTAssertEqual(cache.misses, 1)
        XCTAssertEqual(cache.textRejections, 1,
            "a divergent-text retrieve is counted as a text rejection, not a plain miss")
    }
    #endif
}
