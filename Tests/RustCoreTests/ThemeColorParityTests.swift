import XCTest
import AppKit
import ViewerCore

/// A/B parity (TSK-379, Rust-core migration parity slice): the macOS host's
/// Swift `ViewerCore.ThemeColor.parse` (the VS Code theme-import / color-token
/// oracle) vs the Rust core's `theme::parse_rgba` accept/reject + RGBA contract.
///
/// `theme::parse_rgba` is a SHARED-CONTRACT helper (the core owns the palette
/// values for the TUI/web front-ends) and is NOT bridged through the FFI, so
/// this is a **golden-parity** test, not a live FFI round-trip: the EXPECTED
/// RGBA values below are the values the Rust unit tests pin
/// (`rust-core/crates/core/src/theme.rs`), and this suite proves the Swift
/// oracle produces the SAME accept/reject decisions and the SAME RGBA bytes for
/// each form. Drift on EITHER side trips a gate — the Rust unit test if the Rust
/// parser changes, this test if the Swift oracle changes.
///
/// Gap this slice closed: the Rust `parse_hex` previously accepted ONLY the
/// 6-digit `#rrggbb` form, so a theme using the `#abc` shorthand or an
/// `#rrggbbaa` alpha color parsed in Swift yet returned nil in Rust.
final class ThemeColorParityTests: XCTestCase {

    /// (input, expected RGBA as the Rust `parse_rgba` pins it) — `nil` = both
    /// sides must REJECT. Covers every form + the boundary rejects.
    private let cases: [(String, (UInt8, UInt8, UInt8, UInt8)?)] = [
        // 3-digit shorthand — each nibble doubled.
        ("#abc", (0xaa, 0xbb, 0xcc, 255)),
        ("fff", (255, 255, 255, 255)),
        ("#000", (0, 0, 0, 255)),
        ("#1A2", (0x11, 0xaa, 0x22, 255)),
        // 6-digit.
        ("#56b6c2", (0x56, 0xb6, 0xc2, 255)),
        ("#56B6C2", (0x56, 0xb6, 0xc2, 255)),   // uppercase
        ("000000", (0, 0, 0, 255)),
        ("#ffffff", (255, 255, 255, 255)),
        // 8-digit with alpha.
        ("#11223344", (0x11, 0x22, 0x33, 0x44)),
        ("#00000000", (0, 0, 0, 0)),
        ("#000000ff", (0, 0, 0, 255)),
        // Surrounding whitespace is trimmed.
        ("  #56b6c2  ", (0x56, 0xb6, 0xc2, 255)),
        ("\t#abc\t", (0xaa, 0xbb, 0xcc, 255)),
        // Rejects (both sides → nil).
        ("", nil),
        ("#", nil),
        ("#ff", nil),         // 2-digit
        ("#fffff", nil),      // 5-digit
        ("#1234567", nil),    // 7-digit (between 6 and 8)
        ("#123456789", nil),  // 9-digit
        ("#gggggg", nil),     // non-hex
        ("#12g", nil),        // 3-digit with a non-hex nibble
        ("#12 456", nil),     // interior space → non-hex body
    ]

    /// Extract a parsed `NSColor`'s sRGB channels as 0..=255 bytes — the unit
    /// the Rust `Rgba` uses. Rounds (Swift stores `CGFloat($0)/255`, so the
    /// round-trip is exact for any byte input).
    private func rgba(of color: NSColor) -> (UInt8, UInt8, UInt8, UInt8) {
        let c = color.usingColorSpace(.sRGB) ?? color
        func byte(_ f: CGFloat) -> UInt8 { UInt8((f * 255).rounded()) }
        return (byte(c.redComponent), byte(c.greenComponent),
                byte(c.blueComponent), byte(c.alphaComponent))
    }

    func test_swift_oracle_matches_the_rust_parity_table() {
        for (input, expected) in cases {
            let parsed = ThemeColor.parse(input)
            switch expected {
            case .none:
                XCTAssertNil(parsed,
                    "Swift accepted '\(input.debugDescription)' that the Rust parser rejects")
            case .some(let want):
                guard let color = parsed else {
                    XCTFail("Swift rejected '\(input.debugDescription)' that the Rust parser accepts")
                    continue
                }
                let got = rgba(of: color)
                XCTAssertEqual(got.0, want.0, "R mismatch for \(input.debugDescription)")
                XCTAssertEqual(got.1, want.1, "G mismatch for \(input.debugDescription)")
                XCTAssertEqual(got.2, want.2, "B mismatch for \(input.debugDescription)")
                XCTAssertEqual(got.3, want.3, "A (alpha) mismatch for \(input.debugDescription)")
            }
        }
    }

    /// The headline gap: the shorthand + alpha forms a VS Code theme / CSS token
    /// commonly uses now parse on BOTH sides (Swift here; the Rust unit tests
    /// pin the Rust side). Before this slice the Rust `parse_hex` returned nil
    /// for these while Swift accepted them.
    func test_shorthand_and_alpha_forms_are_accepted_by_the_oracle() {
        XCTAssertNotNil(ThemeColor.parse("#abc"), "3-digit shorthand must parse")
        XCTAssertNotNil(ThemeColor.parse("#11223344"), "8-digit alpha must parse")
        // The shorthand expands by nibble-doubling, not zero-padding.
        XCTAssertEqual(rgba(of: ThemeColor.parse("#abc")!).0, 0xaa,
                       "#abc red is 0xaa (a→aa), not 0xa0")
    }
}
