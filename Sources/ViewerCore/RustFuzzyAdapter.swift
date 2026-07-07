import Foundation
import RustCore

/// The BATCH fuzzy-ranking API over the rust-core engine (port TSK-633).
///
/// STAGE-B (TSK-649, 2026-07-07): the Swift twin (`FuzzyMatcher`'s algorithm)
/// is DELETED — rust is the only engine, routed via
/// `RustCoreFallback.runRustOnly`. A bridge fault DEGRADES to the unranked
/// input (every item, score 0, input order — the same shape as the empty
/// query) and logs observably; it can no longer fall back to Swift.
///
/// Documented index semantics: the core's `matchedIndices` are Unicode-SCALAR
/// offsets (grapheme-cluster-heavy strings may shift highlight glyphs, never
/// crash). Scores and ordering are pinned by the rust engine's suites.
public enum RustFuzzyAdapter {

    /// Rank + filter `items` against `query`, best first, stable ties.
    public static func filterWithMatches<T: Sendable>(
        _ items: [T],
        query: String,
        by key: (T) -> String
    ) -> [(item: T, match: FuzzyMatcher.Match)] {
        outcome(items, query: query, by: key).value
    }

    /// Same, but also reporting the result's provenance.
    public static func outcome<T: Sendable>(
        _ items: [T],
        query: String,
        by key: (T) -> String
    ) -> CoreOutcome<[(item: T, match: FuzzyMatcher.Match)]> {
        // Empty query: every item, score 0, in input order — by contract;
        // skip the bridge round trip entirely.
        if query.isEmpty {
            return CoreOutcome(value: unranked(items), source: .rust)
        }
        return RustCoreFallback.runRustOnly(
            .fuzzy,
            rust: {
                let ranked = try mdvCoreFuzzyRank(query: query, candidates: items.map(key))
                return ranked.compactMap { r in
                    guard r.index >= 0, r.index < items.count else { return nil }
                    return (
                        items[r.index],
                        FuzzyMatcher.Match(score: r.score, matchedIndices: r.matchedIndices)
                    )
                }
            },
            degraded: unranked(items)
        )
    }

    /// The degraded/empty-query shape: everything matches, score 0, input order.
    private static func unranked<T>(_ items: [T]) -> [(item: T, match: FuzzyMatcher.Match)] {
        items.map { ($0, FuzzyMatcher.Match(score: 0, matchedIndices: [])) }
    }
}
