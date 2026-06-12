import Foundation
import RustCore

/// Routes the BATCH fuzzy-ranking API through the Rust core (TSK-646;
/// engine port TSK-633) when the `.fuzzy` gate is on, falling back to the
/// Swift `FuzzyMatcher` otherwise.
///
/// Scope: `filterWithMatches` (the command-palette batch rank) only. The
/// per-node `FuzzyMatcher.match` used by `FileTreeFilter` deliberately
/// stays Swift — one bridge round trip per tree node is wire-hostile; tree
/// filtering migrates with the fs.tree family instead (TSK-654).
///
/// Documented divergence (identical on ASCII): the Rust core's
/// `matchedIndices` are Unicode-SCALAR offsets, the Swift matcher's are
/// grapheme (`Character`) indices — a highlight on a grapheme-cluster-heavy
/// string may shift glyphs, never crash. Scores and ordering are exact
/// (the engine port pins the scoring table + stable ties).
public enum RustFuzzyAdapter {

    /// `FuzzyMatcher.filterWithMatches` routed per the `.fuzzy` gate.
    public static func filterWithMatches<T: Sendable>(
        _ items: [T],
        query: String,
        by key: (T) -> String
    ) -> [(item: T, match: FuzzyMatcher.Match)] {
        outcome(items, query: query, by: key).value
    }

    /// Same, but also reporting which engine produced the result.
    public static func outcome<T: Sendable>(
        _ items: [T],
        query: String,
        by key: (T) -> String,
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CoreOutcome<[(item: T, match: FuzzyMatcher.Match)]> {
        // Empty query: every item, score 0, in input order — identical on
        // both engines by contract; skip the bridge round trip entirely.
        if query.isEmpty {
            return CoreOutcome(
                value: items.map { ($0, FuzzyMatcher.Match(score: 0, matchedIndices: [])) },
                source: .swiftBecauseGateOff)
        }
        return RustCoreFallback.run(
            .fuzzy, defaults: defaults, environment: environment,
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
            swift: { FuzzyMatcher.filterWithMatches(items, query: query, by: key) }
        )
    }
}
