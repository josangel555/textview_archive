import Foundation

/// Lightweight fuzzy matcher. Returns a score for how well `query` matches
/// `target`, or nil if no match. Higher score = better. Pure logic.
///
/// Rules:
/// - Empty query matches everything with score 0.
/// - All query characters must appear in `target` in order (case-insensitive).
/// - Consecutive matches and matches at word boundaries (after `/_- ` or at
///   start) score higher.
/// - Earlier matches in the string score slightly higher.
public enum FuzzyMatcher {

    public struct Match: Equatable, Sendable {
        public let score: Int
        public let matchedIndices: [Int]
    }

    public static func match(_ query: String, against target: String) -> Match? {
        if query.isEmpty {
            return Match(score: 0, matchedIndices: [])
        }
        let q = Array(query.lowercased())
        let t = Array(target.lowercased())
        guard !t.isEmpty else { return nil }

        var qi = 0
        var matched: [Int] = []
        var score = 0
        var lastMatchedAt = -2

        for (ti, ch) in t.enumerated() where qi < q.count {
            if ch == q[qi] {
                matched.append(ti)
                var bonus = 1
                if ti == 0 || isBoundary(t[ti - 1]) {
                    bonus += 6  // word-boundary bonus
                }
                if ti == lastMatchedAt + 1 {
                    bonus += 4  // consecutive bonus
                }
                if ti == 0 {
                    bonus += 3  // strong prefix bonus
                } else if ti < 5 {
                    bonus += 1  // prefer matches near the start
                }
                score += bonus
                lastMatchedAt = ti
                qi += 1
            }
        }

        guard qi == q.count else { return nil }
        return Match(score: score, matchedIndices: matched)
    }

    private static func isBoundary(_ ch: Character) -> Bool {
        ch == "/" || ch == "_" || ch == "-" || ch == "." || ch == " "
    }

    /// Returns the items in `items` whose displayable string fuzzy-matches the
    /// query, sorted by best score with **stable** tie-breaking on input order
    /// (B13/A10 — Swift's `sorted(by:)` is not guaranteed stable, which made
    /// the palette flicker when two recents had the same score).
    public static func filter<T>(
        _ items: [T],
        query: String,
        by key: (T) -> String
    ) -> [T] {
        if query.isEmpty { return items }
        // Pair each match with its original index; on score ties, the lower
        // index wins so input order is preserved.
        let scored: [(index: Int, item: T, score: Int)] =
            items.enumerated().compactMap { (i, item) in
                guard let m = match(query, against: key(item)) else { return nil }
                return (i, item, m.score)
            }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.index < rhs.index
        }
        return sorted.map { $0.item }
    }
}
