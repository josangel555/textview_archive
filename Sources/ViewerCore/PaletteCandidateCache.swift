import Foundation

/// TSK-1179 — the command palette's bare/file-mode candidate list (bookmarks
/// ⧺ non-duplicate recents) is QUERY-INDEPENDENT, yet `CommandPaletteView`
/// rebuilds it on every keystroke (a Set-build + map + filter per character).
/// This is the pure, host-tested core: `merge` is the dedup logic (was an
/// untested private view method) and `PaletteCandidateCache` memoizes it on a
/// generation token the view bumps only when the inputs actually change
/// (palette open, or bookmarks/recents mutate) — so typing reuses the cached
/// list instead of recomputing it. The felt latency win is the VM/owner check;
/// the cache correctness is host-pinned here.
public enum PaletteCandidates {

    /// Bookmarks first (as history entries), then recents that AREN'T already
    /// a bookmark (deduped by URL). Order within each group is preserved.
    public static func merge(
        bookmarkEntries: [HistoryEntry], recents: [HistoryEntry]
    ) -> [HistoryEntry] {
        let bookmarkURLs = Set(bookmarkEntries.map(\.url))
        let extraRecents = recents.filter { !bookmarkURLs.contains($0.url) }
        return bookmarkEntries + extraRecents
    }
}

/// A generation-keyed memo for a query-independent value. `candidates(...)`
/// runs `build` only when `generation` differs from the last cached one;
/// otherwise it returns the cached result. The owner of this cache bumps the
/// generation when (and only when) the inputs change — decoupling the
/// expensive rebuild from per-keystroke calls.
public struct PaletteCandidateCache {
    private var cachedGeneration: Int?
    private var cached: [HistoryEntry] = []

    public init() {}

    /// The cached candidates for `generation`, rebuilding via `build` on a
    /// generation change (or first call). Pure w.r.t. `generation`: repeated
    /// calls at the same generation never re-run `build`.
    public mutating func candidates(
        generation: Int, build: () -> [HistoryEntry]
    ) -> [HistoryEntry] {
        if cachedGeneration != generation {
            cached = build()
            cachedGeneration = generation
        }
        return cached
    }

    /// Force the next `candidates(...)` call to rebuild regardless of
    /// generation (e.g. after an in-place mutation the generation didn't
    /// capture). Cheap escape hatch; prefer bumping the generation.
    public mutating func invalidate() {
        cachedGeneration = nil
    }
}
