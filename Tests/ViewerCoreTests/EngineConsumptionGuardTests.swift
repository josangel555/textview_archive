import XCTest
@testable import ViewerCore

/// TSK-1217 (partial): regression guard for the test-suite-audit finding that an
/// engine can ship with zero view consumers (TSK-788). Each rust-core engine that
/// ships ON by default must have ≥1 reference in app Source code OUTSIDE its own
/// adapter file — so a gated-ON engine that loses ALL its app consumers fails loudly.
///
/// SCOPE / LIMIT (important): this checks textual references, NOT view-reachability.
/// An engine referenced only by view-UNREACHABLE code still passes — e.g. the
/// formula case (RustFormulaAdapter is referenced by EditableCSVModel.recalcAllFormulas,
/// which itself has no view caller). Catching that needs call-graph reachability,
/// which grep/textual scanning cannot do (RustMarkdownAdapter is genuinely consumed
/// via a ViewerCore path with zero ViewerUI references, so a "must appear in
/// ViewerUI" rule would false-fail it). Formula is gated OFF + tracked by TSK-1215;
/// the deeper reachability guard is noted on TSK-1217.
final class EngineConsumptionGuardTests: XCTestCase {
    /// Adapter symbols for the engines whose `RustCoreCapability.defaultEnabled`
    /// is ON. Keep in sync when an engine's gate flips (add formula on TSK-1215).
    private let onEngineAdapters = [
        "RustCSVAdapter", "RustHexAdapter", "RustHexSearchAdapter",
        "RustFuzzyAdapter", "RustFindAdapter", "RustTranscriptAdapter",
        "RustMarkdownAdapter", "RustCMEditAdapter", "RustHighlightAdapter",
        "RustFoldAdapter",
    ]

    func test_default_on_engines_have_app_consumers() {
        let sources = packageRoot().appendingPathComponent("Sources")
        let swiftFiles = enumerateSwift(sources)
        XCTAssertFalse(swiftFiles.isEmpty, "could not enumerate Sources at \(sources.path)")
        for adapter in onEngineAdapters {
            let defFile = "\(adapter).swift"
            let hasConsumer = swiftFiles.contains { url in
                guard url.lastPathComponent != defFile else { return false }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
                return text.contains(adapter)
            }
            XCTAssertTrue(
                hasConsumer,
                "\(adapter) ships ON but has no app consumer outside its own file — a ported-but-unwired regression (TSK-1217)"
            )
        }
    }

    /// Stage-B no-resurrection tooth (TSK-649, B4): the deleted Swift twins
    /// must STAY deleted — nobody re-adds a "small Swift fallback" for a
    /// surface whose only engine is rust-core. These are the algorithm entry
    /// symbols that died in B3; any reappearance in Sources is red. (The
    /// TYPE shells — FuzzyMatcher.Match, CSVParser.Result, ClaudeEvent,
    /// HTMLVisitor's utility fns — are alive by design and not listed.)
    func test_deletedTwins_stayDeleted() {
        let deadSymbols = [
            "FuzzyMatcher.match(",            // fuzzy algorithm (rust fuzzy.rs)
            "FuzzyMatcher.filterWithMatches(", // fuzzy batch rank
            "CSVParser.parse(",               // CSV tokenizer (rust csv.rs)
            "ClaudeLogParser().parse",        // transcript projection (rust transcript.rs)
            "parseRedacted(",                 // transcript redacting projection
            "CMEditApplier",                  // CM edit reducer (rust cm_edit.rs)
            "renderSwiftPath(",               // markdown visitor (rust markdown.rs)
            "computeFolds",                   // fold engine (rust folds.rs)
        ]
        let sources = packageRoot().appendingPathComponent("Sources")
        for url in enumerateSwift(sources) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // CODE-only scan: strip //-comment content per line so doc notes
            // ("the twin X is deleted") don't trip their own tooth.
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    if let slashes = line.range(of: "//") { return line[..<slashes.lowerBound] }
                    return line
                }
                .joined(separator: "\n")
            for symbol in deadSymbols where code.contains(symbol) {
                XCTFail(
                    "\(url.lastPathComponent) references the DELETED twin symbol "
                    + "'\(symbol)' — Stage-B (TSK-649) removed it; route through "
                    + "the rust adapter instead of resurrecting Swift fallbacks."
                )
            }
        }
    }

    /// Package root, derived from this test file's location (Tests/ViewerCoreTests/…)
    /// so it is independent of the test runner's working directory.
    private func packageRoot() -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewerCoreTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // <root>/
    }

    private func enumerateSwift(_ dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
