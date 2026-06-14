import XCTest
@testable import ViewerCore

/// TSK-360 — host coverage for the blame line-age heatmap colors. Pure: maps
/// per-line commit timestamps onto a dark→light blue gradient normalized across
/// the file's own history. The gutter render that applies the colors is CM6.
final class BlameHeatmapTests: XCTestCase {

    private func line(_ n: Int, _ ts: Int) -> GitClient.BlameLine {
        GitClient.BlameLine(line: n, sha: "abc1234", author: "A", timestamp: ts, summary: "s")
    }

    // MARK: - normalizedRecency

    func test_recency_spansOldestToNewest() {
        let r = BlameHeatmap.normalizedRecency(from: [line(1, 100), line(2, 200), line(3, 300)])
        XCTAssertEqual(r[1], 0.0, "oldest line → 0")
        XCTAssertEqual(r[2], 0.5, "midpoint")
        XCTAssertEqual(r[3], 1.0, "newest line → 1")
    }

    func test_recency_allEqualTimestamps_collapseToMid() {
        let r = BlameHeatmap.normalizedRecency(from: [line(1, 500), line(2, 500)])
        XCTAssertEqual(r[1], 0.5)
        XCTAssertEqual(r[2], 0.5)
    }

    func test_recency_empty() {
        XCTAssertTrue(BlameHeatmap.normalizedRecency(from: []).isEmpty)
    }

    // MARK: - hex gradient

    func test_hex_endpoints() {
        XCTAssertEqual(BlameHeatmap.hex(recency: 0), "#0a2a6b", "oldest = dark blue")
        XCTAssertEqual(BlameHeatmap.hex(recency: 1), "#bcd4f0", "newest = light blue")
    }

    func test_hex_clampsOutOfRange() {
        XCTAssertEqual(BlameHeatmap.hex(recency: -3), BlameHeatmap.hex(recency: 0))
        XCTAssertEqual(BlameHeatmap.hex(recency: 9), BlameHeatmap.hex(recency: 1))
    }

    func test_hex_blueChannelIsMonotonic() {
        // Older (lower t) must be darker → smaller blue channel than newer.
        func blue(_ t: Double) -> Int { Int(BlameHeatmap.hex(recency: t).suffix(2), radix: 16)! }
        XCTAssertLessThan(blue(0.0), blue(0.5))
        XCTAssertLessThan(blue(0.5), blue(1.0))
    }

    // MARK: - colors (combined)

    func test_colors_oldestDark_newestLight() {
        let c = BlameHeatmap.colors(from: [line(1, 100), line(2, 300)])
        XCTAssertEqual(c[1], "#0a2a6b", "oldest line is darkest")
        XCTAssertEqual(c[2], "#bcd4f0", "newest line is lightest")
    }

    // MARK: - feeder attaches the heat color

    func test_feeder_attachesHeatColorPerLine() {
        let blame = [line(1, 100), line(2, 300)]
        let markers = BlameGutterFeeder.markers(from: blame, now: Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(markers.first(where: { $0.line == 1 })?.color, "#0a2a6b")
        XCTAssertEqual(markers.first(where: { $0.line == 2 })?.color, "#bcd4f0")
        XCTAssertEqual(markers.map(\.kind), ["blame", "blame"], "still blame-kind markers")
    }
}
