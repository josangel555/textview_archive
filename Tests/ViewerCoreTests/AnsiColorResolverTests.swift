import XCTest
@testable import ViewerCore

/// TSK-1175 — teeth for the pure ANSI colour resolver + themes. Includes a
/// color-PRESERVATION check: the default theme must equal the terminal's old
/// tuned values, so the TerminalPalette refactor changes nothing on screen.
final class AnsiColorResolverTests: XCTestCase {

    func test_defaultTheme_preservesTunedValues() {
        XCTAssertEqual(AnsiTheme.default.colors.count, 16)
        XCTAssertEqual(AnsiTheme.default.colors[1], AnsiRGB(0.80, 0.16, 0.13), "old tuned red")
        XCTAssertEqual(AnsiTheme.default.colors[4], AnsiRGB(0.16, 0.42, 0.85), "old tuned blue")
        XCTAssertEqual(AnsiTheme.default.colors[15], AnsiRGB(0.96, 0.96, 0.96), "old brightWhite")
    }

    func test_ansi_resolvesFromActiveTheme() {
        XCTAssertEqual(AnsiColorResolver.rgb(.ansi(1), theme: .default), AnsiRGB(0.80, 0.16, 0.13))
        XCTAssertEqual(AnsiColorResolver.rgb(.ansi(1), theme: .classic), AnsiRGB(205.0 / 255, 0, 0))
    }

    func test_cube_endpointsAndStep() {
        XCTAssertEqual(AnsiColorResolver.indexed(16), AnsiRGB(0, 0, 0), "first cube cell")
        XCTAssertEqual(AnsiColorResolver.indexed(231), AnsiRGB(1, 1, 1), "last cube cell")
        let c = AnsiColorResolver.indexed(52)   // idx 36 → red axis level 1
        XCTAssertEqual(c.r, 95.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(c.g, 0); XCTAssertEqual(c.b, 0)
    }

    func test_grayscaleRamp() {
        XCTAssertEqual(AnsiColorResolver.indexed(232).r, 8.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(AnsiColorResolver.indexed(255).r, 238.0 / 255, accuracy: 1e-9)
    }

    func test_rgbPassthrough_andDefaultIsNil() {
        XCTAssertEqual(AnsiColorResolver.rgb(.rgb(255, 128, 0)), AnsiRGB(1, 128.0 / 255, 0))
        XCTAssertNil(AnsiColorResolver.rgb(.default))
    }

    func test_indexedBelow16_usesTheme() {
        XCTAssertEqual(AnsiColorResolver.indexed(2, theme: .classic), AnsiRGB(0, 205.0 / 255, 0))
    }
}
