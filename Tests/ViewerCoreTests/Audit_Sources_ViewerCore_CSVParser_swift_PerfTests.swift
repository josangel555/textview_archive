import XCTest
@testable import ViewerCore

/// Regression for the [S2/perf] audit finding on
/// `Sources/ViewerCore/CSVParser.swift`: `appendToField` used to call
/// `field.unicodeScalars.count` on EVERY appended scalar. The scalar
/// view is not random-access and caches no length, so that check was
/// O(currentFieldLength) — building an N-scalar field was O(N²). The fix
/// tracks `fieldScalarCount` separately, restoring O(1) per scalar.
///
/// These are pure-logic headless-tier (T1) tests — host-safe, no GUI.
/// Filter target:
///   `swift test --filter ViewerCoreTests.Audit_Sources_ViewerCore_CSVParser_swift_PerfTests`
final class Audit_Sources_ViewerCore_CSVParser_swift_PerfTests: XCTestCase {

    /// A single ~64K-char unquoted cell must parse fast. Pre-fix this
    /// paid ~64K²/2 ≈ 2.1e9 scalar walks (measured ~2.3 s under -O); the
    /// O(1)-per-scalar fix lands in low single-digit ms. We assert a
    /// generous 1 s ceiling so CI on slow/debug hardware doesn't flap
    /// while still catching a regression to the quadratic cliff (which
    /// was ~2400x over budget), and log the actual number.
    func test_64K_char_cell_parses_without_quadratic_blowup() {
        let n = 64 * 1024
        // One header column + one body row whose single cell is `n`
        // scalars long. No delimiters/newlines inside the cell, so it
        // grows monotonically through `appendToField`.
        let bigCell = String(repeating: "x", count: n)
        let text = "h\n" + bigCell + "\n"

        let t0 = Date()
        let r = CSVParser.parse(text, delimiter: ",")
        let elapsedMs = Date().timeIntervalSince(t0) * 1000
        print("[CSVParserPerf] 64K-char cell parse: \(elapsedMs) ms")

        XCTAssertEqual(r.header, ["h"])
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertEqual(r.rows.first?.first?.count, n)
        XCTAssertFalse(r.truncated, "default maxCellChars (64K) must not clamp a 64K cell")
        XCTAssertLessThan(elapsedMs, 1000)
    }

    /// The separately-tracked counter must still enforce the per-cell
    /// cap exactly: a cell exceeding `maxCellChars` is clamped to the cap
    /// plus a single "…" marker and flips `truncated`.
    func test_cell_cap_still_fires_and_appends_ellipsis_marker() {
        let limits = CSVParser.Limits(maxCellChars: 8)
        let r = CSVParser.parse("h\n" + String(repeating: "a", count: 20) + "\n",
                                delimiter: ",", limits: limits)
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.rows.first?.first, String(repeating: "a", count: 8) + "…")
    }

    /// `commitField()` must reset the counter between fields so the cap
    /// is per-cell, not cumulative across a row.
    func test_counter_resets_per_field() {
        // Cap of 3; two fields each at the cap; neither should bleed into
        // the other's budget.
        let limits = CSVParser.Limits(maxCellChars: 3)
        let r = CSVParser.parse("h1,h2\naaaa,bbbb\n", delimiter: ",", limits: limits)
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.rows.first, ["aaa…", "bbb…"])
    }
}
