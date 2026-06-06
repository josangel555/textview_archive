import XCTest
@testable import ViewerCore

/// Pure-logic coverage for `TerminalCell.swift` — the SGR colour mapping,
/// the `CellAttributes` inverse-swap + bold→bright promotion, and
/// `TerminalCell.blank`/`isBlank`. Was untested; complements the
/// `TerminalScreen` grid tests.
final class TerminalCellTests: XCTestCase {

    // MARK: - TerminalColor.fromSGR

    func test_fromSGR_baseForeground() {
        XCTAssertEqual(TerminalColor.fromSGR(30, base: 30, bright: false), .black)
        XCTAssertEqual(TerminalColor.fromSGR(31, base: 30, bright: false), .red)
        XCTAssertEqual(TerminalColor.fromSGR(34, base: 30, bright: false), .blue)
        XCTAssertEqual(TerminalColor.fromSGR(37, base: 30, bright: false), .white)
    }

    func test_fromSGR_baseBackground() {
        XCTAssertEqual(TerminalColor.fromSGR(40, base: 40, bright: false), .black)
        XCTAssertEqual(TerminalColor.fromSGR(46, base: 40, bright: false), .cyan)
    }

    func test_fromSGR_brightFamily() {
        XCTAssertEqual(TerminalColor.fromSGR(90, base: 90, bright: true), .brightBlack)
        XCTAssertEqual(TerminalColor.fromSGR(91, base: 90, bright: true), .brightRed)
        XCTAssertEqual(TerminalColor.fromSGR(97, base: 90, bright: true), .brightWhite)
    }

    func test_fromSGR_outOfRange_returnsNil() {
        // 38/48 are the 256-/true-colour introducers (idx 8) → rejected, not garbled.
        XCTAssertNil(TerminalColor.fromSGR(38, base: 30, bright: false))
        XCTAssertNil(TerminalColor.fromSGR(48, base: 40, bright: false))
        // Below the base.
        XCTAssertNil(TerminalColor.fromSGR(29, base: 30, bright: false))
    }

    // MARK: - CellAttributes defaults / reset

    func test_default_isAllDefaults() {
        let d = CellAttributes.default
        XCTAssertEqual(d.fg, .default)
        XCTAssertEqual(d.bg, .default)
        XCTAssertFalse(d.bold)
        XCTAssertFalse(d.underline)
        XCTAssertFalse(d.inverse)
        XCTAssertEqual(d, CellAttributes())
    }

    func test_reset_restoresDefault() {
        var a = CellAttributes(fg: .red, bg: .blue, bold: true, underline: true, inverse: true)
        a.reset()
        XCTAssertEqual(a, .default)
    }

    // MARK: - effectiveFg / effectiveBg

    func test_effectiveFg_plain_isForeground() {
        XCTAssertEqual(CellAttributes(fg: .red).effectiveFg, .red)
    }

    func test_effectiveFg_boldPromotesBaseToBright() {
        XCTAssertEqual(CellAttributes(fg: .red, bold: true).effectiveFg, .brightRed)
        XCTAssertEqual(CellAttributes(fg: .white, bold: true).effectiveFg, .brightWhite)
    }

    func test_effectiveFg_boldLeavesDefaultAndBrightUntouched() {
        XCTAssertEqual(CellAttributes(fg: .default, bold: true).effectiveFg, .default)
        XCTAssertEqual(CellAttributes(fg: .brightRed, bold: true).effectiveFg, .brightRed)
    }

    func test_inverse_swapsFgAndBg() {
        let a = CellAttributes(fg: .red, bg: .blue, inverse: true)
        XCTAssertEqual(a.effectiveFg, .blue, "inverse uses bg as the fg")
        XCTAssertEqual(a.effectiveBg, .red, "inverse uses fg as the bg")
    }

    func test_inverse_withBold_promotesSwappedColor() {
        // inverse → base fg becomes bg (.blue); bold → promote to brightBlue.
        let a = CellAttributes(fg: .white, bg: .blue, bold: true, inverse: true)
        XCTAssertEqual(a.effectiveFg, .brightBlue)
        XCTAssertEqual(a.effectiveBg, .white)
    }

    func test_effectiveBg_plain_isBackground() {
        XCTAssertEqual(CellAttributes(bg: .green).effectiveBg, .green)
    }

    // MARK: - TerminalCell.blank / isBlank

    func test_blank_isSpaceWithDefaultAttributes() {
        XCTAssertEqual(TerminalCell.blank.char, " ")
        XCTAssertEqual(TerminalCell.blank.attributes, .default)
        XCTAssertTrue(TerminalCell.blank.isBlank)
    }

    func test_isBlank_falseForNonSpaceChar() {
        XCTAssertFalse(TerminalCell(char: "x").isBlank)
    }

    func test_isBlank_falseForSpaceWithNonDefaultAttributes() {
        XCTAssertFalse(TerminalCell(char: " ", attributes: CellAttributes(bg: .red)).isBlank,
                       "a styled space (e.g. coloured background) is not blank")
    }
}
