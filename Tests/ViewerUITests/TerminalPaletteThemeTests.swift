import XCTest
import AppKit
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1312 — `TerminalPalette.activeThemeName` drives the resolved ANSI colours
/// (the foundation for a Settings terminal-colour-scheme picker), and the preference
/// round-trips. The Settings picker + the terminal-view wiring that sets
/// `activeThemeName` from the preference are the render tail.
@MainActor
final class TerminalPaletteThemeTests: XCTestCase {

    override func tearDown() {
        TerminalPalette.activeThemeName = "Default"   // restore global state
        super.tearDown()
    }

    func test_activeThemeName_drivesAnsiColors() throws {
        TerminalPalette.activeThemeName = "Classic (xterm)"
        let classicRed = try XCTUnwrap(TerminalPalette.nsColor(.ansi(1))?.usingColorSpace(.sRGB))
        XCTAssertLessThan(classicRed.greenComponent, 0.05, "classic red is vivid (≈0 green)")

        TerminalPalette.activeThemeName = "Default"
        let mutedRed = try XCTUnwrap(TerminalPalette.nsColor(.ansi(1))?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(mutedRed.greenComponent, 0.10, "muted default red has ≈0.16 green")
    }

    func test_unknownTheme_fallsBackToDefaultColors() throws {
        TerminalPalette.activeThemeName = "bogus-theme"
        let red = try XCTUnwrap(TerminalPalette.nsColor(.ansi(1))?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(red.greenComponent, 0.10, "unknown theme → muted Default palette")
    }

    func test_preference_roundTrips_defaultsToDefault() {
        let prefs = PreferencesStore(defaults: UserDefaults(suiteName: "TermTheme-\(UUID().uuidString)")!)
        XCTAssertEqual(prefs.terminalColorThemeName, "Default")
        prefs.terminalColorThemeName = "Classic (xterm)"
        XCTAssertEqual(prefs.terminalColorThemeName, "Classic (xterm)")
    }
}
