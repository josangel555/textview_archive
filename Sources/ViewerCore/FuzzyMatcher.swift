import Foundation

/// STAGE-B DELETED TWIN (TSK-649, 2026-07-07): the Swift fuzzy-ranking
/// ALGORITHM that lived here was deleted — the engine is rust-core's
/// `fuzzy.rs` (TSK-633 port; scoring table + stable ties pinned there), and
/// every runtime caller routes through `RustFuzzyAdapter`. Only the result
/// TYPE remains: it is the shared contract between the adapter and the UI
/// (palette/sidebar highlight the `matchedIndices` glyphs).
public enum FuzzyMatcher {

    public struct Match: Equatable, Sendable {
        public let score: Int
        public let matchedIndices: [Int]

        public init(score: Int, matchedIndices: [Int]) {
            self.score = score
            self.matchedIndices = matchedIndices
        }
    }
}
