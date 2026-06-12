import XCTest
@testable import RustCore
import ViewerCore

/// A/B parity (TSK-633): the Rust core's `mdvcore_fuzzy_rank` (via
/// `mdvCoreFuzzyRank`) vs the SHIPPING Swift `FuzzyMatcher`, over a corpus of
/// realistic file names and command titles. Exercises the whole pipeline:
/// MessagePack encode → FFI → rank → decode.
///
/// Parity contract (per the port's documented unit caveat):
/// - ASCII corpus: SCORES, ORDER, and MATCHED INDICES identical.
/// - Non-ASCII corpus: scores+order asserted; indices are scalar-vs-grapheme
///   and compared only where the string has no multi-scalar clusters.
final class FuzzyRankABTests: XCTestCase {

    /// Realistic ASCII corpus — file paths, command titles, the shapes the
    /// palette/GoTo actually rank.
    private let asciiCorpus = [
        "Sources/ViewerCore/FuzzyMatcher.swift",
        "Sources/ViewerUI/CommandPaletteView.swift",
        "Tests/RustCoreTests/FuzzyRankABTests.swift",
        "scripts/build-rust-core.sh",
        "docs/TASK_WORKFLOW.md",
        "README.md",
        "readme_backup.md",
        "Open in New Session",
        "Copy SHA-256 of Current File",
        "git: Show File History",
        "rust-core/crates/core/src/fuzzy.rs",
        "a_b_c.txt", "abc.txt", "xab.txt", "ab", "AB.md",
    ]

    private let queries = [
        "", "fz", "fuzzy", "rm", "readme", "RM", "cmd", "swift",
        "src/fz", "abc", "b c", "sha", "zzz_nomatch",
    ]

    func test_rust_matches_swift_scores_order_and_indices_on_ascii() throws {
        for query in queries {
            let swift = FuzzyMatcher.filterWithMatches(
                Array(asciiCorpus.indices), query: query, by: { asciiCorpus[$0] })
            let rust = try mdvCoreFuzzyRank(query: query, candidates: asciiCorpus)

            XCTAssertEqual(rust.map(\.index), swift.map { $0.item },
                "ORDER diverged for query '\(query)'")
            XCTAssertEqual(rust.map(\.score), swift.map { $0.match.score },
                "SCORES diverged for query '\(query)'")
            XCTAssertEqual(rust.map(\.matchedIndices), swift.map { $0.match.matchedIndices },
                "INDICES diverged for query '\(query)' (ASCII must be unit-identical)")
        }
    }

    func test_rust_matches_swift_on_singlescalar_unicode() throws {
        // é/ü as single scalars: char-walk and Character-walk agree.
        let corpus = ["résumé.md", "über_config.toml", "naïve.txt", "plain.txt"]
        for query in ["é", "ü", "naive", "résumé", "u"] {
            let swift = FuzzyMatcher.filterWithMatches(
                Array(corpus.indices), query: query, by: { corpus[$0] })
            let rust = try mdvCoreFuzzyRank(query: query, candidates: corpus)
            XCTAssertEqual(rust.map(\.index), swift.map { $0.item },
                "ORDER diverged for query '\(query)'")
            XCTAssertEqual(rust.map(\.score), swift.map { $0.match.score },
                "SCORES diverged for query '\(query)'")
        }
    }

    func test_empty_query_returns_all_in_input_order_score_zero() throws {
        let rust = try mdvCoreFuzzyRank(query: "", candidates: asciiCorpus)
        XCTAssertEqual(rust.map(\.index), Array(0..<asciiCorpus.count))
        XCTAssertTrue(rust.allSatisfy { $0.score == 0 && $0.matchedIndices.isEmpty })
    }

    func test_capability_bit_advertised() {
        // The port's capability bit flipped ON in the same change (TSK-634
        // contract: advertising and shipping are atomic).
        XCTAssertTrue(CoreABI.capabilities.contains(.fuzzy))
    }
}
