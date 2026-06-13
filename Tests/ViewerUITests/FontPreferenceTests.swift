import XCTest
import AppKit
import ViewerCore
@testable import ViewerUI

/// TSK-259 slice 1 — the font picker's headless half: fail-safe
/// resolution, the fixed-pitch family filter, persistence, and the two
/// traps the plan named (repaint key + gutter metrics). Pixels = glance.
@MainActor
final class FontPreferenceTests: HeadlessUITestCase {

    func test_resolution_isFailSafe() {
        // nil → system monospaced.
        let sys = FontPreference.resolvedFont(name: nil, size: 13)
        XCTAssertTrue(sys.isFixedPitch)
        // A real family resolves to itself.
        let menlo = FontPreference.resolvedFont(name: "Menlo", size: 13)
        XCTAssertEqual(menlo.familyName, "Menlo")
        // A deleted/unknown font DEGRADES to the system font — never nil,
        // never a crash (the user can remove a font while it's selected).
        let gone = FontPreference.resolvedFont(name: "No-Such-Font-XYZ", size: 13)
        XCTAssertTrue(gone.isFixedPitch)
        XCTAssertEqual(gone.fontName, sys.fontName)
        // Empty string behaves like nil.
        XCTAssertEqual(FontPreference.resolvedFont(name: "", size: 13).fontName,
                       sys.fontName)
    }

    func test_familyFilter_isFixedPitchOnly() {
        let families = FontPreference.monospaceFamilies()
        XCTAssertTrue(families.contains("Menlo"), "Menlo ships on every macOS")
        XCTAssertFalse(families.contains("Helvetica"),
                       "proportional families must never be offered")
        XCTAssertEqual(families, families.sorted(), "picker list is sorted")
    }

    func test_preference_persists_andModelWritesThrough() {
        let suite = "FontPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = PreferencesStore(defaults: defaults)
        XCTAssertNil(prefs.sourceFontName, "default is nil = system")
        prefs.sourceFontName = "Menlo"
        XCTAssertEqual(PreferencesStore(defaults: defaults).sourceFontName, "Menlo",
                       "survives a fresh store (relaunch)")
        prefs.sourceFontName = nil
        XCTAssertNil(PreferencesStore(defaults: defaults).sourceFontName,
                     "clearing restores the system default")
    }

    /// The gutter trap: line height must derive from the RESOLVED family.
    /// Monaco's metrics differ from SF Mono's at the same point size — if
    /// lineHeight ignored the name, the gutter would misalign (the
    /// long-standing doc-comment warning in TextDisplayView).
    func test_lineHeight_followsTheResolvedFamily() {
        let sys = SourceTextController.lineHeight(forFontSize: 13)
        let monaco = SourceTextController.lineHeight(forFontSize: 13, fontName: "Monaco")
        XCTAssertNotEqual(sys, monaco,
                          "a family with different metrics must change the row height")
        XCTAssertEqual(SourceTextController.lineHeight(forFontSize: 13, fontName: "No-Such"),
                       sys, "unknown family degrades to the system metrics")
    }

    /// The repaint trap: the source pin that fontName participates in the
    /// paint cache key and the view pass-through exists — without these a
    /// family change silently never repaints (the stale-render class).
    func test_repaintKey_andPassThrough_areWired() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let tdv = try String(
            contentsOf: root.appendingPathComponent("Sources/ViewerUI/TextDisplayView.swift"),
            encoding: .utf8)
        XCTAssertTrue(tdv.contains("""
            fontSize: fontSize, fontName: fontName,
            theme: theme.name, runCount: runs.count
"""),
                      "AttrKey must include fontName (repaint on family change)")
        XCTAssertTrue(tdv.contains("FontPreference.resolvedFont(name: fontName, size: fontSize)"),
                      "the paint must use the resolved preference font")
        let cv = try String(
            contentsOf: root.appendingPathComponent("Sources/ViewerUI/ContentView.swift"),
            encoding: .utf8)
        XCTAssertTrue(cv.contains("fontName: model.sourceFontName"),
                      "ContentView must feed the preference (dead-channel guard)")
    }
}
