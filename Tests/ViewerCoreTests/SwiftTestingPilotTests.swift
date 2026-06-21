import Testing
@testable import ViewerCore

/// TSK-1130 / TSK-787 — Swift Testing hybrid PILOT. A first suite using the
/// `swift-testing` framework (`@Test`/`#expect`, parameterized cases) alongside
/// the existing XCTest suites — both run under `swift test`. Pure-logic only
/// (no UI / no tiers); see the CLAUDE.md "Testing rules" convention note.
@Suite("Swift Testing pilot (pure logic)")
struct SwiftTestingPilot {

    @Test("StandardPalette carries the primaries and is opaque")
    func paletteBasics() {
        #expect(StandardPalette.colors.count >= 16)
        #expect(StandardPalette.colors.contains(.black))
        #expect(StandardPalette.colors.contains(.white))
        #expect(StandardPalette.colors.allSatisfy { $0.a == 255 })
    }

    /// Parameterized — Swift Testing's headline win over XCTest: one test, many cases.
    @Test("ANSI 256-cube endpoints resolve", arguments: [
        (UInt8(16), AnsiRGB(0, 0, 0)),       // first cube cell
        (UInt8(231), AnsiRGB(1, 1, 1)),      // last cube cell
    ])
    func cubeEndpoints(_ tc: (index: UInt8, expected: AnsiRGB)) {
        #expect(AnsiColorResolver.indexed(tc.index) == tc.expected)
    }

    @Test("default theme preserves the tuned palette values")
    func defaultThemePreserved() {
        #expect(AnsiTheme.default.colors[1] == AnsiRGB(0.80, 0.16, 0.13))   // red
        #expect(AnsiTheme.default.colors[15] == AnsiRGB(0.96, 0.96, 0.96))  // bright white
    }
}
