import AppKit
import Foundation
import WebKit

/// Perf P1 (TSK-1042) — app-level warm-WKWebView cache that survives a session
/// switch, so a returning rendered-Markdown tab RE-ATTACHES its existing
/// `WKWebView` instead of rebuilding it (which re-pays ~94% of a rendered-MD
/// open — TSK-598 / the TSK-1040 audit).
///
/// ## Why this exists
/// `MountedPanesLRU` pane retention (TSK-108) is keyed by `Tab.id` and lives on
/// the *single shared* `DocumentModel`. A session switch drains every tab
/// (`closeAllTabsPreservingDirty` → `retainOnly({})` drops every pane) and the
/// incoming session's tabs are rebuilt with **brand-new `Tab.id`s** (the
/// persisted snapshot stores the file PATH, not the id). So the LRU can never
/// match a returning tab and its `WKWebView` is built from scratch.
///
/// This cache sits ABOVE the SwiftUI `NSViewRepresentable` lifecycle, keyed on
/// the **file path** (stable across the switch — that's exactly what the
/// snapshot persists). `dismantleNSView` stashes the WebView + its coordinator
/// state here instead of letting WebKit tear the WebContent process down;
/// `makeNSView` dequeues a cached WebView for the same path and re-points its
/// navigation delegate to the fresh coordinator, copying the in-flight state
/// (`lastHTML`, `currentURL`, mermaid/scroll/scale flags) across. Because
/// `lastHTML == html` after the copy, `updateNSView`'s reload gate is a no-op —
/// no `loadHTMLString`, no `didFinish` round-trip, no WebKit first-open cost.
///
/// ## Correctness invariants
///   * **Take-once.** A retrieved entry is removed from the cache immediately,
///     so two live panes can never share one WebView.
///   * **Never hand out a parented WebView.** A guard rejects (and drops) any
///     cached WebView that still has a `superview` — defends against a make for
///     path P racing a not-yet-dismantled live pane for P.
///   * **Bounded.** An LRU cap (default 4, matching `MountedPanesLRU.capacity`)
///     evicts the least-recently-stashed entry — its WebView is then released
///     normally (the WebContent process tears down). The whole-app surface is a
///     handful of warm WebViews, not an unbounded leak.
///   * **Path-keyed, not id-keyed.** Survives the fresh-`Tab.id` rebuild AND
///     works cross-session (two sessions with the same file → same warm pane,
///     same HTML → no reload).
///   * **Opt-in per call site.** Only call sites that pass a non-nil cache key
///     participate. The split pane (`fileURL == nil`) deliberately does NOT, so
///     a split showing the same file as the main pane can never collide.
///
/// Lives on the main actor (WebKit views are main-actor-only) and is a process
/// singleton. DEBUG exposes counters so a host test can prove a stash→retrieve
/// round-trips an entry (the host-testable kernel of the no-rebuild win;
/// `MountProbe.webViewMakes` proves the end-to-end zero-rebuild on the VM lane).
@MainActor
final class WarmWebViewCache {

    /// Process-wide instance the representables share.
    static let shared = WarmWebViewCache()

    /// One stashed entry: the parked WebView plus the navigation-delegate
    /// state needed to re-attach it WITHOUT a reload.
    struct Entry {
        let webView: WKWebView
        let coordinator: MarkdownRenderedView.Coordinator
    }

    /// MRU-first insertion order of cache keys (front = most-recently stashed).
    /// Parallel to `entries`; drives bounded eviction.
    private var order: [String] = []
    private var entries: [String: Entry] = [:]

    /// Max parked WebViews. Matches `MountedPanesLRU.capacity` so the warm set
    /// and the mounted set are the same order of magnitude.
    let capacity: Int

    init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    #if DEBUG
    /// Total successful `stash` calls (DEBUG-only host-test probe).
    private(set) var stashes = 0
    /// Total successful (non-nil) `retrieve` calls (DEBUG-only host-test probe).
    private(set) var hits = 0
    /// Total `retrieve` calls that returned nil — miss or rejected-parented
    /// (DEBUG-only host-test probe).
    private(set) var misses = 0
    /// Entries evicted by the LRU cap (DEBUG-only host-test probe).
    private(set) var evictions = 0

    func resetProbes() {
        stashes = 0; hits = 0; misses = 0; evictions = 0
    }
    #endif

    /// Number of currently parked WebViews.
    var count: Int { entries.count }

    /// True iff a usable (un-parented) entry is parked for `key`.
    func contains(_ key: String) -> Bool { entries[key] != nil }

    /// Park `webView` + its `coordinator` under `key` so a later `makeNSView`
    /// for the same path can re-attach it. Replaces any prior entry for the key
    /// (the old one is dropped → its WebView releases). Evicts the LRU tail
    /// beyond `capacity`.
    func stash(_ webView: WKWebView, coordinator: MarkdownRenderedView.Coordinator, forKey key: String) {
        // A WebView that's still on screen must never be parked — the caller is
        // dismantling, so it should already be detached, but be defensive.
        webView.removeFromSuperview()
        webView.stopLoading()
        order.removeAll { $0 == key }
        order.insert(key, at: 0)
        entries[key] = Entry(webView: webView, coordinator: coordinator)
        #if DEBUG
        stashes += 1
        #endif
        evictBeyondCapacity()
    }

    /// Dequeue (take-once) the parked entry for `key`, or nil if none / unusable.
    /// Removes the entry on hit so it can't be handed out twice.
    func retrieve(forKey key: String) -> Entry? {
        guard let entry = entries[key] else {
            #if DEBUG
            misses += 1
            #endif
            return nil
        }
        // Defensive: never re-attach a WebView that's still parented (a live
        // pane for the same path that hasn't dismantled yet). Drop it.
        guard entry.webView.superview == nil else {
            remove(key)
            #if DEBUG
            misses += 1
            #endif
            return nil
        }
        remove(key)
        #if DEBUG
        hits += 1
        #endif
        return entry
    }

    /// Drop the entry for `key` (no-op if absent). The dropped WebView releases.
    func remove(_ key: String) {
        entries.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    /// Drop every parked entry (e.g. File → Reset, or a teardown). Their
    /// WebViews release.
    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    private func evictBeyondCapacity() {
        while order.count > capacity, let victim = order.popLast() {
            entries.removeValue(forKey: victim)
            #if DEBUG
            evictions += 1
            #endif
        }
    }
}
