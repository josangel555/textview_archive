import Foundation
import SwiftUI
import ViewerKit
import ViewerCore

/// PERF #5 (2026-05-25): per-tab syntax-highlight cache.
///
/// The previous design kept a single `@Published highlightCache:
/// [HighlightCacheKey: [HighlightRun]]` on `DocumentModel`. Every
/// tokenize completion wrote to that map, which fired
/// `DocumentModel.objectWillChange` and re-bodied every observing
/// view — including widgets that don't care about syntax (TabBar,
/// ModeBar, StatusBar, the sidebar). The cache was *supposed* to
/// skip work; in practice the publish negated the win.
///
/// New shape:
///   - One `HighlightCacheActor` per tab. It owns the cache, the
///     in-flight set, and the eviction policy for that tab only.
///   - The class is `@MainActor`-bound — "actor" here means
///     ownership boundary, not the Swift `actor` keyword. Cache
///     lookups are O(1) main-actor dict reads (safe from `body`);
///     the tokenize work itself runs on `Task.detached` and hops
///     back to the main actor to store.
///   - `@Published var version: Int` is the narrow notification
///     channel. When a tokenize completes the version bumps —
///     SwiftUI re-evals only views that observe `this` actor, which
///     is precisely the source-view subtree for the active tab.
///     DocumentModel observation chain is untouched.
@MainActor
public final class HighlightCacheActor: ObservableObject {
    /// Monotonically increasing counter; SwiftUI re-evals views that
    /// observe this object whenever a tokenize completion stores
    /// fresh runs. The integer value is irrelevant — observers
    /// re-read `runs(for:)` on every bump.
    @Published public private(set) var version: Int = 0

    private var cache: [HighlightCacheKey: [HighlightRun]] = [:]
    /// Insertion order, oldest first. Used by `prune()` for LRU-ish
    /// eviction (S2-G class: avoid `Dictionary.keys.prefix(N)` which
    /// can drop the entry we just inserted).
    private var order: [HighlightCacheKey] = []
    private var inFlight: Set<HighlightCacheKey> = []

    /// Per-tab cap. Smaller than the prior global `32` because each
    /// tab now has its own cache. A single tab typically only holds
    /// a couple of entries (current file × 1–2 sizes from
    /// edit-driven reloads); 8 is plenty of headroom.
    private static let maxEntries = 8

    public init() {}

    /// Synchronous cache lookup. Safe to call from a SwiftUI `body`.
    /// Returns `nil` on miss; the caller is expected to follow up
    /// with `ensureTokenized(key:text:)` to populate.
    public func runs(for key: HighlightCacheKey) -> [HighlightRun]? {
        cache[key]
    }

    /// Kick off tokenize for `text` if not already cached or in
    /// flight. Idempotent — repeated calls with the same key while a
    /// task is pending coalesce to a single TreeSitter invocation.
    /// Completion bumps `version`, driving re-eval of the subtree
    /// that observes this actor.
    ///
    /// `text` is captured by value into the detached task so the
    /// caller doesn't have to worry about mutation during tokenize.
    public func ensureTokenized(key: HighlightCacheKey, text: String) {
        if cache[key] != nil { return }
        if inFlight.contains(key) { return }
        inFlight.insert(key)
        let snapshot = text
        let lang = key.language
        Task.detached(priority: .userInitiated) { [weak self] in
            let runs = RustHighlightAdapter.tokenize(snapshot, language: lang)
            await MainActor.run { [weak self] in
                self?.store(runs, for: key)
            }
        }
    }

    /// Convenience: combined sync-read + async-populate that matches
    /// the prior `DocumentModel.highlightRuns(forURL:text:language:)`
    /// shape. Returns cached runs immediately, or `[]` + kicks off the
    /// populate if missing.
    public func runsOrEnqueue(
        key: HighlightCacheKey, text: String
    ) -> [HighlightRun] {
        if let hit = cache[key] { return hit }
        ensureTokenized(key: key, text: text)
        return []
    }

    /// Test-only seam: synchronously install pre-tokenized runs.
    /// Bumps the version so observers re-eval as if a real tokenize
    /// had completed.
    public func _testInstall(_ runs: [HighlightRun], for key: HighlightCacheKey) {
        store(runs, for: key)
    }

    /// Test-only: peek at the in-flight set so coalescing assertions
    /// can verify a second call didn't kick off a duplicate task.
    public var _testInFlightCount: Int { inFlight.count }

    /// Test-only: current cache entry count.
    public var _testCacheCount: Int { cache.count }

    private func store(_ runs: [HighlightRun], for key: HighlightCacheKey) {
        if cache[key] == nil {
            order.append(key)
        }
        cache[key] = runs
        inFlight.remove(key)
        prune()
        // Final step: announce. Observers re-eval and re-read via
        // `runs(for:)`. Wraparound is fine — SwiftUI diffs by value
        // inequality, not by ordering.
        version &+= 1
    }

    private func prune() {
        guard cache.count > Self.maxEntries else { return }
        // Drop down to ~2/3 capacity so we don't churn on every insert.
        let dropCount = cache.count - Self.maxEntries * 2 / 3
        let toDrop = order.prefix(dropCount)
        for key in toDrop {
            cache.removeValue(forKey: key)
        }
        order.removeFirst(toDrop.count)
    }
}

/// Cache key. Re-exported here as the canonical home now that the
/// cache lives per-tab. `DocumentModel.HighlightCacheKey` aliases this
/// for source compatibility with existing callers / tests.
///
/// RWC-1 (2026-05-30): `modifiedTime` joined the key so a same-byte
/// reload invalidates. The prior `(url, length, language)` key served
/// STALE syntax spans when the watcher (or an editor save) rewrote a
/// file to the exact same byte length (`let x = 1` → `let y = 2`):
/// `length` matched, so the cache returned the spans tokenized against
/// the OLD text. mtime is the same channel the rendered-HTML cache uses
/// (see `DocumentModel.RenderedHTMLKey`) — O(1) to read, captured at
/// load time, and nanosecond-resolution on APFS so back-to-back edits
/// produce distinct stamps. `length` stays in the key too: it cheaply
/// separates entries when mtime is nil (synthetic in-memory `TextFile`s
/// from tests), and is free to compare.
public struct HighlightCacheKey: Hashable, Sendable {
    public let url: URL
    public let length: Int
    public let language: HighlightLanguage
    /// `nil` only for synthetic `TextFile`s constructed without an
    /// mtime (in-memory tests). In production every `TextFile` from the
    /// loader carries one. Two same-url/same-length/nil-mtime keys
    /// collapse to one entry — acceptable for tests (no watcher reload
    /// races there).
    public let modifiedTime: Date?

    public init(
        url: URL,
        length: Int,
        language: HighlightLanguage,
        modifiedTime: Date? = nil
    ) {
        self.url = url
        self.length = length
        self.language = language
        self.modifiedTime = modifiedTime
    }
}
