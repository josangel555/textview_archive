import AppKit
import Foundation
import WebKit

/// Perf (TSK-1190) — app-level warm-WKWebView cache for the RAW-HTML render
/// pane (`HTMLRenderedView`), the exact analogue of `WarmWebViewCache` for the
/// rendered-Markdown pane (TSK-1042). A returning HTML render pane RE-ATTACHES
/// its existing `WKWebView` instead of rebuilding it + re-running
/// `loadHTMLString` on the (potentially multi-MB) sanitized document.
///
/// ## Why a SEPARATE cache from `WarmWebViewCache`
/// The two render panes park DIFFERENT coordinator types (this one parks
/// `HTMLRenderedView.Coordinator`; `WarmWebViewCache` parks
/// `MarkdownRenderedView.Coordinator`) and the WebViews are configured under
/// DIFFERENT security postures — the raw-HTML WebView's JS engine is
/// default-DENY (`HTMLDocumentPolicy`), the markdown WebView's is on (for the
/// injected find runtime). Keeping the caches disjoint guarantees a markdown
/// WebView can NEVER be handed to the raw-HTML pane (or vice-versa) — a
/// path-key collision between an `a.md` and an `a.html` in the same directory
/// can't cross the two stores, so the security envelope of each pane is never
/// adopted by the other.
///
/// ## Why this is needed (the bug it fixes)
/// `HTMLRenderedView` is selected by `ContentView` only in `viewMode ==
/// .rendered`; toggling the tab to Editor (source) flips the SwiftUI branch and
/// DISMANTLES the representable, and toggling back MAKES a fresh one. Without a
/// warm cache, every Editor↔Render switch rebuilds the `WKWebView` and re-runs
/// `loadHTMLString` on the full sanitized envelope — re-sanitize + re-parse +
/// re-DOM-materialize. On a 1.48 MB bundled document that is the slow switch the
/// owner felt. With this cache the WebView (and its loaded DOM) survives the
/// toggle and re-attaches with NO reload (`updateNSView`'s `lastDocument ==
/// document` gate is a no-op after the parked coordinator's state is adopted).
///
/// ## Correctness invariants (identical to `WarmWebViewCache`)
///   * **Take-once.** A retrieved entry is removed immediately, so two live
///     panes can never share one WebView.
///   * **Never hand out a parented WebView.** A guard rejects (and drops) any
///     cached WebView still on screen.
///   * **Bounded.** LRU cap (default 4) evicts the least-recently-stashed
///     entry; its WebView then releases (WebContent process tears down).
///   * **Path-keyed**, so it survives the fresh-`Tab.id` rebuild AND works
///     cross-session.
///
/// Lives on the main actor (WebKit views are main-actor-only) and is a process
/// singleton. DEBUG exposes counters so a host test can prove a stash→retrieve
/// round-trips an entry (the host-testable kernel of the no-rebuild win).
@MainActor
final class WarmHTMLWebViewCache {

    /// Process-wide instance the `HTMLRenderedView` representables share.
    static let shared = WarmHTMLWebViewCache()

    /// One stashed entry: the parked WebView plus the navigation-delegate
    /// state needed to re-attach it WITHOUT a reload.
    struct Entry {
        let webView: WKWebView
        let coordinator: HTMLRenderedView.Coordinator
    }

    /// MRU-first insertion order of cache keys (front = most-recently stashed).
    /// Parallel to `entries`; drives bounded eviction.
    private var order: [String] = []
    private var entries: [String: Entry] = [:]

    /// Max parked WebViews. Matches `WarmWebViewCache.capacity` /
    /// `MountedPanesLRU.capacity` so the warm set is the same order of magnitude.
    let capacity: Int

    init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    #if DEBUG
    /// Total successful `stash` calls (DEBUG-only host-test probe).
    private(set) var stashes = 0
    /// Total successful (non-nil) `retrieve` calls (DEBUG-only host-test probe).
    private(set) var hits = 0
    /// Total `retrieve` calls that returned nil — miss or rejected-parented.
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
    func stash(_ webView: WKWebView, coordinator: HTMLRenderedView.Coordinator, forKey key: String) {
        // A WebView that's still on screen must never be parked.
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
