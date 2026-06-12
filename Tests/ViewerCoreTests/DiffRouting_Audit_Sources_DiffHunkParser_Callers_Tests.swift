import XCTest
@testable import ViewerCore

/// TSK-561 routing guard. The audit found the rust `hunk_marks` engine was
/// DEAD CODE on the hottest diff path: `DocumentModel.refreshDiffMarks` /
/// `refreshSplitDiffMarks` and `DiffGutterFeeder.markers(fromDiff:)` called
/// the Swift `DiffHunkParser` directly, bypassing `RustDiffAdapter` — so the
/// default-ON `.diff` capability never saw gutter traffic.
///
/// Two layers:
///  1. A SOURCE audit: the only production caller of `DiffHunkParser.parse(`
///     and `DiffParser.parse(` is `RustDiffAdapter.swift` (the adapter's
///     gate-off/fault fallback closure). A new direct call anywhere else in
///     `Sources/` re-opens the bypass and fails here, naming the file.
///  2. A behavior pin: the routed feeder output equals the adapter's marks
///     (the adapter's own A/B parity suite pins rust ≡ Swift, so this
///     composes into full equivalence).
final class DiffRouting_Audit_Sources_DiffHunkParser_Callers_Tests: XCTestCase {

    private static let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ViewerCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("Sources")

    /// The single file allowed to call the Swift twins directly: the adapter
    /// itself, whose `swift:` closures ARE the fallback path.
    private static let allowedFile = "RustDiffAdapter.swift"

    func test_swiftDiffParsers_haveNoDirectProductionCallers_outsideTheAdapter() throws {
        let fm = FileManager.default
        var offenders: [String] = []
        let enumerator = try XCTUnwrap(
            fm.enumerator(at: Self.sourcesRoot, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard url.lastPathComponent != Self.allowedFile else { continue }
            // The parsers' own definition files don't *call* parse; a
            // self-recursive call would be caught by their unit suites.
            guard !["DiffHunkParser.swift", "DiffParser.swift"]
                .contains(url.lastPathComponent) else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            for needle in ["DiffHunkParser.parse(", "DiffParser.parse("]
            where text.contains(needle) {
                offenders.append("\(url.lastPathComponent): \(needle)")
            }
        }
        XCTAssertEqual(
            offenders, [],
            "Production code must route diff parsing through RustDiffAdapter "
            + "(parse / hunkMarks) — a direct Swift-twin call bypasses the "
            + ".diff capability gate and resurrects the TSK-561 dead-engine "
            + "bypass. Offenders: \(offenders)")
    }

    func test_gutterFeeder_convenience_matchesTheRoutedAdapterMarks() {
        let diff = """
        diff --git a/f.txt b/f.txt
        index 0000000..1111111 100644
        --- a/f.txt
        +++ b/f.txt
        @@ -1,3 +1,4 @@
         keep
        -old
        +new
        +added
         tail
        """
        let viaFeeder = DiffGutterFeeder.markers(fromDiff: diff)
        let viaAdapter = DiffGutterFeeder.markers(from: RustDiffAdapter.hunkMarks(diff))
        XCTAssertEqual(viaFeeder, viaAdapter,
                       "markers(fromDiff:) must be exactly the routed adapter result")
        XCTAssertFalse(viaFeeder.isEmpty, "fixture must produce marks — an empty "
                       + "result would make the equality vacuous")
    }
}
