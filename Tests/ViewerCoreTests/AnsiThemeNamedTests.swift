import XCTest
@testable import ViewerCore

/// TSK-1312 — terminal ANSI colour-theme selection. `AnsiTheme.named` resolves a
/// built-in by name (the persisted preference value) with a safe fallback, and the
/// `.classic` (xterm) vs `.default` (muted) palettes genuinely differ at indices 0–15
/// (the whole point — claude-code colours "look off" under the muted default).
final class AnsiThemeNamedTests: XCTestCase {

    func test_named_resolvesBuiltIns() {
        XCTAssertEqual(AnsiTheme.named("Default").name, "Default")
        XCTAssertEqual(AnsiTheme.named("Classic (xterm)").name, "Classic (xterm)")
    }

    func test_named_unknownFallsBackToDefault() {
        XCTAssertEqual(AnsiTheme.named("no-such-theme").name, "Default")
    }

    func test_classicVsDefault_differAtAnsiRed() {
        // ANSI index 1 = red. Classic is vivid xterm (205,0,0 → green≈0); the muted
        // Default has green≈0.16. If these stop differing the feature is pointless.
        XCTAssertEqual(AnsiTheme.named("Classic (xterm)").colors[1].g, 0, accuracy: 0.02)
        XCTAssertGreaterThan(AnsiTheme.named("Default").colors[1].g, 0.10)
    }

    func test_indexed_resolvesPerTheme_atLowIndices() {
        XCTAssertEqual(AnsiColorResolver.indexed(1, theme: .classic).g, 0, accuracy: 0.02)
        XCTAssertGreaterThan(AnsiColorResolver.indexed(1, theme: .default).g, 0.10)
        // 16–255 are theme-independent (the cube/greyscale) — identical across themes.
        XCTAssertEqual(AnsiColorResolver.indexed(200, theme: .classic).r,
                       AnsiColorResolver.indexed(200, theme: .default).r, accuracy: 0.0001)
    }
}
