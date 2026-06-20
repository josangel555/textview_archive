import AppKit
import Foundation
import WebKit

/// Perf P1-followup (TSK-1047) — the EDITOR twin of `WarmWebViewCache`: an
/// app-level warm-WKWebView cache that survives a session/tab switch so a
/// returning CM6 editor tab RE-ATTACHES its existing `WKWebView` (with the loaded
/// CodeMirror document, undo history, caret, and SCROLL position all intact)
/// instead of rebuilding it from scratch (which reloads CM6 at the top of the
/// file — the owner-reported editor-scroll-resets-on-switch bug).
///
/// ## Why a SIBLING cache, not the shared `WarmWebViewCache`
/// `WarmWebViewCache` parks a `MarkdownRenderedView.Coordinator`; the editor
/// parks a `CodeMirrorEditorView.Coordinator` (a different type, different
/// adopt-state surface). A single cache can't hold both without erasing the
/// coordinator type. Keying is identical (resolved file path, stable across the
/// `Tab.id` churn a session switch causes — see `WarmWebViewCache` header), so a
/// dedicated mirror is the clean split. The two caches never collide because
/// they're keyed by the SAME path but consulted by DIFFERENT representables: an
/// editor `makeNSView` only ever asks this cache; a rendered `makeNSView` only
/// ever asks `WarmWebViewCache`.
///
/// ## The LIVE-STATE invariant (this is the crux — see `Entry.parkedText`)
/// Unlike the read-only rendered preview, the editor holds the user's LIVE,
/// possibly-DIRTY document. Re-attaching a parked editor WebView blindly would
/// risk resurrecting STALE text (e.g. the file changed on disk, or a session
/// drain re-hydrated the buffer differently, or the same path is open elsewhere
/// and was edited) — a hot-exit data-loss class.
///
/// The guard: an entry remembers the exact text the parked CM6 currently holds
/// (`parkedText`). A retrieve REQUIRES the caller to pass the text the model is
/// about to feed the fresh representable; the entry is handed back ONLY when the
/// two are byte-identical. On any mismatch the parked WebView is DROPPED (real
/// teardown) and the caller builds fresh, seeding scroll via the existing belt
/// (`editorMountSelectionSeed` / `seedEditorScroll`). This makes re-attach a pure
/// optimization that can NEVER change what text the user sees: a re-attach only
/// happens when the parked DOM already equals the model's text — and in-progress
/// edits live in BOTH (CM6 posts every change back into `editorBuffers`, which is
/// what the model feeds), so a genuine edit-in-flight ALWAYS matches and
/// re-attaches with the edits intact; anything that would differ falls to the
/// fresh build where the model's text (the edit's true home) wins.
///
/// ## Correctness invariants (mirrors `WarmWebViewCache`)
///   * **Take-once.** A retrieved entry is removed immediately — two live panes
///     can never share one editor WebView.
///   * **Text-consistent re-attach only.** `retrieve(forKey:expectedText:)`
///     returns nil (and drops the entry) when the parked text ≠ expected.
///   * **Never hand out a parented WebView.** A still-`superview`'d cached
///     WebView (a not-yet-dismantled live pane racing a make for the same path)
///     is rejected and dropped.
///   * **Bounded.** An LRU cap evicts the least-recently-stashed entry; its
///     WebView then releases (the WebContent process tears down).
///   * **Path-keyed.** Survives the fresh-`Tab.id` rebuild AND works
///     cross-session (same file ⇒ same warm editor pane).
///   * **Opt-in per call site.** Only call sites passing a non-nil key
///     participate. The split pane / preview-slot opt out (nil key).
///
/// Main-actor (WebKit views are main-actor-only), process singleton. DEBUG
/// exposes counters so a host test proves a stash→retrieve round-trips an entry
/// AND that a text mismatch is rejected (the host-testable kernel of the
/// no-rebuild win + the live-state safety guard).
@MainActor
final class WarmEditorWebViewCache {

    /// Process-wide instance the editor representable shares.
    static let shared = WarmEditorWebViewCache()

    /// One stashed entry: the parked editor WebView, its coordinator (carrying
    /// the CM6 navigation/ready state to re-adopt), and the text the parked CM6
    /// currently holds (the live-state consistency key).
    struct Entry {
        let webView: WKWebView
        let coordinator: CodeMirrorEditorView.Coordinator
        /// The exact document text the parked CM6 holds. A retrieve is granted
        /// only when this equals the text the model will feed the new pane — so a
        /// re-attach can never resurrect stale text or silently drop edits.
        let parkedText: String
    }

    /// MRU-first insertion order of cache keys (front = most-recently stashed).
    private var order: [String] = []
    private var entries: [String: Entry] = [:]

    /// Max parked editor WebViews. Matches `WarmWebViewCache.capacity` /
    /// `MountedPanesLRU.capacity` so the warm set is the same order of magnitude.
    let capacity: Int

    init(capacity: Int = 4) {
        self.capacity = max(1, capacity)
    }

    #if DEBUG
    /// DEBUG-only host-test probes.
    private(set) var stashes = 0
    /// Successful (text-consistent) re-attach hits.
    private(set) var hits = 0
    /// Plain misses (no entry parked for the key).
    private(set) var misses = 0
    /// Retrieves rejected because the parked text ≠ expected (the live-state
    /// guard fired). Counted separately from `misses` so a test can prove the
    /// guard, not just absence.
    private(set) var textRejections = 0
    /// Entries evicted by the LRU cap.
    private(set) var evictions = 0

    func resetProbes() {
        stashes = 0; hits = 0; misses = 0; textRejections = 0; evictions = 0
    }
    #endif

    /// Number of currently parked editor WebViews.
    var count: Int { entries.count }

    /// True iff an entry is parked for `key` (regardless of text consistency).
    func contains(_ key: String) -> Bool { entries[key] != nil }

    /// Park `webView` + its `coordinator` under `key`, recording the `text` the
    /// parked CM6 holds (the consistency key for a later re-attach). Replaces any
    /// prior entry for the key. Evicts the LRU tail beyond `capacity`.
    func stash(
        _ webView: WKWebView,
        coordinator: CodeMirrorEditorView.Coordinator,
        text: String,
        forKey key: String
    ) {
        // A WebView still on screen must never be parked — the caller is
        // dismantling, so it should already be detached, but be defensive.
        webView.removeFromSuperview()
        order.removeAll { $0 == key }
        order.insert(key, at: 0)
        entries[key] = Entry(webView: webView, coordinator: coordinator, parkedText: text)
        #if DEBUG
        stashes += 1
        #endif
        evictBeyondCapacity()
    }

    /// Dequeue (take-once) the parked entry for `key`, BUT ONLY when its parked
    /// text equals `expectedText` (the text the model is about to feed the fresh
    /// representable). Returns nil — and drops the entry — on miss, on a parented
    /// WebView, or on a text mismatch (the live-state safety guard). On a hit the
    /// entry is removed so it can't be handed out twice.
    func retrieve(forKey key: String, expectedText: String) -> Entry? {
        guard let entry = entries[key] else {
            #if DEBUG
            misses += 1
            #endif
            return nil
        }
        // Live-state guard: NEVER re-attach a parked editor whose document no
        // longer matches what the model expects — that would resurrect stale
        // text (or, in the worst case, mask in-progress edits the model holds).
        // Drop the entry (its WebView releases) and let the caller build fresh.
        guard entry.parkedText == expectedText else {
            remove(key)
            #if DEBUG
            textRejections += 1
            #endif
            return nil
        }
        // Defensive: never re-attach a WebView that's still parented (a live pane
        // for the same path that hasn't dismantled yet). Drop it.
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

    /// Drop every parked entry (e.g. File → Reset, or a teardown).
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
