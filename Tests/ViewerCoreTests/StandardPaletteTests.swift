import XCTest
@testable import ViewerCore

/// TSK-1070 — teeth for the default image-editor palette.
final class StandardPaletteTests: XCTestCase {

    func test_palette_hasColorsIncludingBlackWhitePrimaries() {
        let c = StandardPalette.colors
        XCTAssertGreaterThanOrEqual(c.count, 16, "a usable palette")
        XCTAssertTrue(c.contains(.black))
        XCTAssertTrue(c.contains(.white))
        XCTAssertTrue(c.contains(.red))
        XCTAssertTrue(c.contains(.blue))
    }

    func test_palette_allOpaque() {
        for color in StandardPalette.colors {
            XCTAssertEqual(color.a, 255, "palette swatches are opaque")
        }
    }
}
