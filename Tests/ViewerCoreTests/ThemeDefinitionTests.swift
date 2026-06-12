import XCTest
@testable import ViewerCore

/// Theme engine stage 1 (TSK-641): hex parsing, lossless incumbent
/// round-trip, tok-CSS generation, store persistence + fallbacks.
final class ThemeDefinitionTests: XCTestCase {

    // MARK: hex parsing

    func test_hexParsing_forms_and_failures() {
        XCTAssertNotNil(ThemeColor.parse("#AD3DA4"))
        XCTAssertNotNil(ThemeColor.parse("ad3da4"))
        XCTAssertNotNil(ThemeColor.parse("#FFF"))
        XCTAssertNotNil(ThemeColor.parse("#11223344"))
        XCTAssertNil(ThemeColor.parse("#GGHHII"))
        XCTAssertNil(ThemeColor.parse("#12345"))
        XCTAssertNil(ThemeColor.parse(""))
        // Round-trip: parse → hex → parse stays stable.
        let c = ThemeColor.parse("#AD3DA4")!
        XCTAssertEqual(ThemeColor.hex(c), "#AD3DA4")
        // Shorthand expands: #F00 == #FF0000.
        XCTAssertEqual(ThemeColor.hex(ThemeColor.parse("#F00")!), "#FF0000")
    }

    // MARK: lossless incumbents

    func test_builtins_roundTrip_to_the_hardcoded_themes() {
        for (def, incumbent) in [
            (ThemeDefinition.builtIns[0], SyntaxTheme.xcodeLight),
            (ThemeDefinition.builtIns[1], SyntaxTheme.xcodeDark),
        ] {
            let rebuilt = SyntaxTheme(from: def)
            for kind in TokenKind.allCases {
                XCTAssertEqual(
                    ThemeColor.hex(rebuilt.color(for: kind)),
                    ThemeColor.hex(incumbent.color(for: kind)),
                    "token \(kind) diverged for \(def.id)")
            }
            XCTAssertEqual(ThemeColor.hex(rebuilt.background),
                           ThemeColor.hex(incumbent.background), "\(def.id) background")
        }
    }

    // MARK: CSS generation

    func test_tokCSS_emits_only_defined_tokens_with_surface_colors() {
        let def = ThemeDefinition(
            id: "t", displayName: "T", isDark: false,
            background: "#FFFFFF", foreground: "#111111",
            gutterText: "#888888", gutterBackground: "#F0F0F0",
            tokens: ["keyword": "#AD3DA4", "string": "#C41A16"])
        let css = def.tokCSS()
        XCTAssertTrue(css.contains(".tok-keyword { color: #AD3DA4; }"))
        XCTAssertTrue(css.contains(".tok-string { color: #C41A16; }"))
        XCTAssertFalse(css.contains(".tok-comment"), "undefined tokens are omitted")
        XCTAssertTrue(css.contains("pre, code { background-color: #FFFFFF; color: #111111; }"))
    }

    // MARK: store

    func test_store_persistence_selection_and_fallback() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-themes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "ThemeStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ThemeStore(userDir: dir, defaults: defaults)

        // Built-ins only at first.
        XCTAssertEqual(store.all().map(\.id), ["xcode-light", "xcode-dark"])

        // Save a user theme → it appears; JSON round-trips.
        var custom = ThemeDefinition.builtIns[1]
        custom.id = "my-dark"
        custom.displayName = "My Dark"
        try store.saveUserTheme(custom)
        XCTAssertEqual(store.all().map(\.id), ["xcode-light", "xcode-dark", "my-dark"])

        // Selection: explicit id wins; unknown id falls back by appearance.
        store.selectedID = "my-dark"
        XCTAssertEqual(store.active(isDarkAppearance: false).id, "my-dark")
        store.selectedID = "deleted-theme"
        XCTAssertEqual(store.active(isDarkAppearance: true).id, "xcode-dark",
                       "unknown selection falls back to the appearance pair")
        store.selectedID = nil
        XCTAssertEqual(store.active(isDarkAppearance: false).id, "xcode-light")
    }

    func test_malformed_userTheme_json_is_skipped_not_fatal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-themes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "not json".write(to: dir.appendingPathComponent("broken.json"),
                             atomically: true, encoding: .utf8)
        let store = ThemeStore(userDir: dir, defaults: UserDefaults(suiteName: "t-\(UUID())")!)
        XCTAssertEqual(store.all().count, ThemeDefinition.builtIns.count,
                       "broken user theme files are skipped")
    }
}
