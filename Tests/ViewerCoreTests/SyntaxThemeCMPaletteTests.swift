import XCTest
@testable import ViewerCore
import ViewerKit

/// TSK-602 — ViewOnly ↔ Editor highlight parity.
///
/// The CM6 editor builds its `HighlightStyle` from `SyntaxTheme.cmPalette`,
/// shipped over the `setTheme` bridge message. These tests pin the contract
/// the JS side depends on: complete token coverage, valid CSS hex, and the
/// exact hex values of the shipped Xcode themes — so a palette drift (or a
/// broken NSColor→hex conversion) fails HERE instead of as a subtle color
/// mismatch on screen.
final class SyntaxThemeCMPaletteTests: XCTestCase {

    private let themes: [SyntaxTheme] = [.xcodeLight, .xcodeDark]

    func test_everyTokenKindPresent_bothThemes() {
        for theme in themes {
            let palette = theme.cmPalette
            for kind in TokenKind.allCases {
                XCTAssertNotNil(palette[kind.rawValue],
                                "\(theme.name) palette missing token \(kind.rawValue)")
            }
        }
    }

    func test_chromeKeysPresent_bothThemes() {
        for theme in themes {
            let palette = theme.cmPalette
            for key in SyntaxTheme.CMPaletteChromeKey.allCases {
                XCTAssertNotNil(palette[key.rawValue],
                                "\(theme.name) palette missing chrome key \(key.rawValue)")
            }
        }
    }

    func test_everyValueIsCSSHex() {
        let pattern = "^#[0-9A-F]{6}$"
        for theme in themes {
            for (key, value) in theme.cmPalette {
                XCTAssertNotNil(value.range(of: pattern, options: .regularExpression),
                                "\(theme.name) \(key) not #RRGGBB: \(value)")
            }
        }
    }

    /// The PARITY pin: palette hex values are byte-identical to the
    /// SyntaxTheme constants the ViewOnly source view paints with.
    func test_paletteMatchesSourceViewColors_spotChecks() {
        let light = SyntaxTheme.xcodeLight.cmPalette
        XCTAssertEqual(light["keyword"], "#AD3DA4")
        XCTAssertEqual(light["string"], "#C41A16")
        XCTAssertEqual(light["comment"], "#53716A")
        XCTAssertEqual(light["number"], "#1C00CF")
        XCTAssertEqual(light["background"], "#FFFFFF")

        let dark = SyntaxTheme.xcodeDark.cmPalette
        XCTAssertEqual(dark["keyword"], "#FC5FA3")
        XCTAssertEqual(dark["string"], "#FC6A5D")
        XCTAssertEqual(dark["comment"], "#6C7986")
        XCTAssertEqual(dark["type"], "#9EF1DD")
    }

    /// Full-coverage parity (not just spot checks): every palette entry
    /// equals the hex of the color the source view uses for that kind.
    func test_paletteMatchesSourceViewColors_allKinds() {
        for theme in themes {
            let palette = theme.cmPalette
            for kind in TokenKind.allCases {
                XCTAssertEqual(palette[kind.rawValue],
                               SyntaxTheme.cssHex(theme.color(for: kind)),
                               "\(theme.name) \(kind.rawValue) diverged from source-view color")
            }
        }
    }
}
