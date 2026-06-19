import CoreGraphics
import XCTest
@testable import ViewerCore

/// Pure-logic coverage for the markdown overview / minimap model (TSK-305):
/// the doc-text → segment split (heading boundaries + density), the
/// segment → canvas-band projection, and the click→line / line→y geometry.
/// The SwiftUI overview view is a thin wrapper; its render/click is the VM
/// tail, so these tests pin the behavior the view depends on.
final class MarkdownOverviewTests: XCTestCase {

    // MARK: - segments()

    func test_emptyText_noSegments() {
        XCTAssertTrue(MarkdownOverview.segments(in: "").isEmpty)
    }

    func test_blankText_noSegments() {
        // A single whitespace-only line maps to nothing meaningful.
        XCTAssertTrue(MarkdownOverview.segments(in: "   ").isEmpty)
    }

    func test_noHeadings_singleLeadInSegmentSpanningWholeDoc() {
        let text = "para one\npara two\npara three"
        let segs = MarkdownOverview.segments(in: text)
        XCTAssertEqual(segs.count, 1)
        XCTAssertNil(segs[0].heading)
        XCTAssertEqual(segs[0].startLine, 1)
        XCTAssertEqual(segs[0].endLine, 3)
        XCTAssertEqual(segs[0].density, 1.0, accuracy: 0.0001) // no blank lines
    }

    func test_headingsSplitIntoSections_withLeadIn() {
        // Lead-in (lines 1-2), then two H-bounded sections.
        let text = [
            "intro line",     // 1
            "more intro",     // 2
            "# First",        // 3
            "body a",         // 4
            "body b",         // 5
            "## Second",      // 6
            "body c",         // 7
        ].joined(separator: "\n")
        let segs = MarkdownOverview.segments(in: text)
        XCTAssertEqual(segs.count, 3)

        XCTAssertNil(segs[0].heading)
        XCTAssertEqual(segs[0].startLine, 1)
        XCTAssertEqual(segs[0].endLine, 2)

        XCTAssertEqual(segs[1].heading?.title, "First")
        XCTAssertEqual(segs[1].heading?.level, 1)
        XCTAssertEqual(segs[1].startLine, 3)
        XCTAssertEqual(segs[1].endLine, 5)

        XCTAssertEqual(segs[2].heading?.title, "Second")
        XCTAssertEqual(segs[2].heading?.level, 2)
        XCTAssertEqual(segs[2].startLine, 6)
        XCTAssertEqual(segs[2].endLine, 7)
    }

    func test_firstLineHeading_noLeadInSegment() {
        let text = "# Top\nbody\n## Next\nbody2"
        let segs = MarkdownOverview.segments(in: text)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].heading?.title, "Top")
        XCTAssertEqual(segs[0].startLine, 1)
        XCTAssertEqual(segs[0].endLine, 2)
        XCTAssertEqual(segs[1].heading?.title, "Next")
        XCTAssertEqual(segs[1].startLine, 3)
        XCTAssertEqual(segs[1].endLine, 4)
    }

    func test_density_reflectsBlankLines() {
        // Section: heading + 1 body + 2 blank lines → 2 non-blank / 4 = 0.5.
        let text = "# H\nbody\n\n   \n# Next\nx"
        let segs = MarkdownOverview.segments(in: text)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].startLine, 1)
        XCTAssertEqual(segs[0].endLine, 4)
        XCTAssertEqual(segs[0].density, 0.5, accuracy: 0.0001)
        // Second section is heading + one body line → fully dense.
        XCTAssertEqual(segs[1].density, 1.0, accuracy: 0.0001)
    }

    func test_segmentsCoverEveryLine_noGapsOrOverlaps() {
        let text = "lead\n# A\nx\ny\n## B\nz\n### C"
        let segs = MarkdownOverview.segments(in: text)
        XCTAssertEqual(segs.first?.startLine, 1)
        // Last segment ends on the document's last line.
        XCTAssertEqual(segs.last?.endLine, 7)
        // Contiguous: each segment starts exactly where the last ended + 1.
        for i in 1..<segs.count {
            XCTAssertEqual(segs[i].startLine, segs[i - 1].endLine + 1)
        }
    }

    func test_crlfLineEndings_countedCorrectly() {
        // CRLF must not collapse to one line (the Character.split trap).
        let text = "# A\r\nbody\r\n## B\r\nmore"
        let segs = MarkdownOverview.segments(in: text)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].startLine, 1)
        XCTAssertEqual(segs[0].endLine, 2)
        XCTAssertEqual(segs[1].startLine, 3)
        XCTAssertEqual(segs[1].endLine, 4)
        // The lone trailing \r on each line is treated as blank-ish whitespace
        // but the text content keeps the line non-blank.
        XCTAssertEqual(segs[0].density, 1.0, accuracy: 0.0001)
    }

    // MARK: - bands()

    func test_bands_emptyForNoSegments() {
        XCTAssertTrue(MarkdownOverview.bands(for: [], canvasHeight: 100).isEmpty)
    }

    func test_bands_emptyForZeroCanvas() {
        let segs = MarkdownOverview.segments(in: "# A\nb")
        XCTAssertTrue(MarkdownOverview.bands(for: segs, canvasHeight: 0).isEmpty)
    }

    func test_bands_tileCanvasProportionalToLineSpan() {
        // Section A is 1 line, section B is 3 lines → B's band is 3x taller.
        let segs = [
            MarkdownOverviewSegment(
                heading: MarkdownHeading(level: 1, title: "A", line: 1),
                startLine: 1, endLine: 1, density: 1),
            MarkdownOverviewSegment(
                heading: MarkdownHeading(level: 1, title: "B", line: 2),
                startLine: 2, endLine: 4, density: 1),
        ]
        let bands = MarkdownOverview.bands(for: segs, canvasHeight: 400)
        XCTAssertEqual(bands.count, 2)
        // 4 total lines → A spans 1/4 = 100pt, B spans 3/4 = 300pt.
        XCTAssertEqual(bands[0].y0, 0, accuracy: 0.01)
        XCTAssertEqual(bands[0].y1, 100, accuracy: 0.01)
        XCTAssertEqual(bands[1].y0, 100, accuracy: 0.01)
        XCTAssertEqual(bands[1].y1, 400, accuracy: 0.01)
        // No gap: band[1].y0 == band[0].y1.
        XCTAssertEqual(bands[1].y0, bands[0].y1, accuracy: 0.01)
        // Covers the full canvas.
        XCTAssertEqual(bands.last?.y1 ?? -1, 400, accuracy: 0.01)
    }

    // MARK: - line(atY:)

    func test_lineAtY_nilForEmptyBands() {
        XCTAssertNil(MarkdownOverview.line(atY: 10, bands: []))
    }

    func test_lineAtY_clampsAboveTopToFirstLine() {
        let segs = MarkdownOverview.segments(in: "# A\nb\nc\n# B\nd")
        let bands = MarkdownOverview.bands(for: segs, canvasHeight: 100)
        XCTAssertEqual(MarkdownOverview.line(atY: -50, bands: bands), 1)
    }

    func test_lineAtY_clampsBelowBottomToLastLine() {
        let text = "# A\nb\nc\n# B\nd"          // 5 lines
        let segs = MarkdownOverview.segments(in: text)
        let bands = MarkdownOverview.bands(for: segs, canvasHeight: 100)
        XCTAssertEqual(MarkdownOverview.line(atY: 999, bands: bands), 5)
    }

    func test_lineAtY_mapsProportionallyWithinBand() {
        // Single section, lines 1...11 over a 100pt canvas. Click at the
        // vertical middle (y=50) should land near the middle line (~6).
        let segs = [
            MarkdownOverviewSegment(
                heading: nil, startLine: 1, endLine: 11, density: 1),
        ]
        let bands = MarkdownOverview.bands(for: segs, canvasHeight: 100)
        let line = MarkdownOverview.line(atY: 50, bands: bands)
        XCTAssertEqual(line, 6) // 1 + round(0.5 * 10) = 6
    }

    func test_lineAtY_picksCorrectBand() {
        // Two equal-size sections. A click in the lower half lands in the
        // second section.
        let segs = [
            MarkdownOverviewSegment(
                heading: MarkdownHeading(level: 1, title: "A", line: 1),
                startLine: 1, endLine: 5, density: 1),
            MarkdownOverviewSegment(
                heading: MarkdownHeading(level: 1, title: "B", line: 6),
                startLine: 6, endLine: 10, density: 1),
        ]
        let bands = MarkdownOverview.bands(for: segs, canvasHeight: 100)
        // y=75 is in the lower band [50,100].
        let line = MarkdownOverview.line(atY: 75, bands: bands)
        XCTAssertNotNil(line)
        XCTAssertGreaterThanOrEqual(line!, 6)
        XCTAssertLessThanOrEqual(line!, 10)
    }

    // MARK: - y(forLine:)

    func test_yForLine_nilForEmptyBands() {
        XCTAssertNil(MarkdownOverview.y(forLine: 3, bands: []))
    }

    func test_yForLine_roundTripsWithLineAtY() {
        // For a single dense section, y(forLine:) and line(atY:) are inverses
        // (up to rounding) — pin that the viewport marker lands where a click
        // on the same line would.
        let segs = [
            MarkdownOverviewSegment(
                heading: nil, startLine: 1, endLine: 21, density: 1),
        ]
        let bands = MarkdownOverview.bands(for: segs, canvasHeight: 200)
        for line in [1, 6, 11, 16, 21] {
            guard let y = MarkdownOverview.y(forLine: line, bands: bands) else {
                return XCTFail("nil y for line \(line)")
            }
            let back = MarkdownOverview.line(atY: y, bands: bands)
            XCTAssertEqual(back, line, "round-trip mismatch at line \(line)")
        }
    }

    func test_yForLine_clampsOutOfRange() {
        let segs = [
            MarkdownOverviewSegment(
                heading: nil, startLine: 1, endLine: 10, density: 1),
        ]
        let bands = MarkdownOverview.bands(for: segs, canvasHeight: 100)
        // Past EOF → bottom of last band.
        XCTAssertEqual(MarkdownOverview.y(forLine: 999, bands: bands),
                       bands.last?.y1)
        // Before line 1 → top.
        XCTAssertEqual(MarkdownOverview.y(forLine: 0, bands: bands),
                       bands.first?.y0)
    }

    // MARK: - blankDensity() helper

    func test_blankDensity_allBlank_isZero() {
        let lines = ["", "  ", "\t"]
        XCTAssertEqual(
            MarkdownOverview.blankDensity(lines: lines, startLine: 1, endLine: 3),
            0, accuracy: 0.0001)
    }

    func test_blankDensity_noBlank_isOne() {
        let lines = ["a", "b", "c"]
        XCTAssertEqual(
            MarkdownOverview.blankDensity(lines: lines, startLine: 1, endLine: 3),
            1, accuracy: 0.0001)
    }
}
