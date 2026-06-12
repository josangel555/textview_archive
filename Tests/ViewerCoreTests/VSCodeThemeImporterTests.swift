import XCTest
@testable import ViewerCore

/// VS Code theme import (TSK-642): JSONC tolerance, scope→TokenKind
/// specificity, dark/light inference, and the end-to-end install path
/// through the TSK-641 store.
final class VSCodeThemeImporterTests: XCTestCase {

    /// A realistic JSONC fixture: comments, trailing commas, a
    /// comment-looking URL inside a string, array + comma-separated scopes.
    private let fixture = """
    {
      // A Monokai-ish test theme
      "name": "Test Theme 2026",
      "type": "dark",
      "colors": {
        "editor.background": "#272822",
        "editor.foreground": "#F8F8F2",
        "editorLineNumber.foreground": "#90908A",
        "editor.selectionBackground": "#49483E",
        "homepage": "https://example.com/not-a-comment", /* block comment */
      },
      "tokenColors": [
        { "scope": "keyword", "settings": { "foreground": "#F92672" } },
        { "scope": "keyword.operator", "settings": { "foreground": "#AE81FF" } },
        { "scope": ["string", "string.quoted"], "settings": { "foreground": "#E6DB74" } },
        { "scope": "string.regexp", "settings": { "foreground": "#FD5FF0" } },
        { "scope": "comment, punctuation.definition.comment", "settings": { "foreground": "#75715E" } },
        { "scope": "constant.numeric", "settings": { "foreground": "#AE81FF" } },
        { "scope": "entity.name.function", "settings": { "foreground": "#A6E22E" } },
        { "scope": "markup.heading", "settings": { "foreground": "#A6E22E" } },
      ],
    }
    """

    func test_endToEnd_parse_fields_and_scopes() throws {
        let def = try VSCodeThemeImporter.parse(Data(fixture.utf8), fallbackName: "x")
        XCTAssertEqual(def.id, "test-theme-2026")
        XCTAssertEqual(def.displayName, "Test Theme 2026")
        XCTAssertTrue(def.isDark)
        XCTAssertEqual(def.background, "#272822")
        XCTAssertEqual(def.gutterText, "#90908A")
        XCTAssertEqual(def.selectionBackground, "#49483E")
        XCTAssertEqual(def.tokens["keyword"], "#F92672")
        XCTAssertEqual(def.tokens["string"], "#E6DB74")
        XCTAssertEqual(def.tokens["regex"], "#FD5FF0", "string.regexp beats string for regex")
        XCTAssertEqual(def.tokens["comment"], "#75715E")
        XCTAssertEqual(def.tokens["number"], "#AE81FF")
        XCTAssertEqual(def.tokens["function"], "#A6E22E")
        XCTAssertEqual(def.tokens["heading"], "#A6E22E")
        // Specificity: keyword.operator (more specific) owns .operator while
        // plain keyword keeps .keyword.
        XCTAssertEqual(def.tokens["operator"], "#AE81FF")
        // The definition converts into a working SyntaxTheme.
        let theme = SyntaxTheme(from: def)
        XCTAssertEqual(ThemeColor.hex(theme.color(for: .keyword)), "#F92672")
    }

    func test_specificity_lastLongestWins_regardlessOfOrder() throws {
        let json = """
        { "name": "S", "type": "dark",
          "colors": { "editor.background": "#000000", "editor.foreground": "#FFFFFF" },
          "tokenColors": [
            { "scope": "keyword.operator.special", "settings": { "foreground": "#111111" } },
            { "scope": "keyword.operator", "settings": { "foreground": "#222222" } }
          ] }
        """
        let def = try VSCodeThemeImporter.parse(Data(json.utf8), fallbackName: "s")
        // Both entries match the "keyword.operator" prefix with EQUAL
        // matched-prefix length — the first to claim it keeps it (no
        // flapping on equal specificity).
        XCTAssertEqual(def.tokens["operator"], "#111111")
    }

    func test_darkInference_fromLuminance_whenTypeMissing() throws {
        let dark = """
        { "colors": { "editor.background": "#101010", "editor.foreground": "#EEEEEE" } }
        """
        let light = """
        { "colors": { "editor.background": "#FAFAFA", "editor.foreground": "#111111" } }
        """
        XCTAssertTrue(try VSCodeThemeImporter.parse(Data(dark.utf8), fallbackName: "d").isDark)
        XCTAssertFalse(try VSCodeThemeImporter.parse(Data(light.utf8), fallbackName: "l").isDark)
    }

    func test_jsonc_stripper_preserves_strings() {
        let out = VSCodeThemeImporter.stripJSONC(
            #"{"url": "https://x/y", "a": 1, /* c */ "b": 2, } // tail"#)
        XCTAssertTrue(out.contains("https://x/y"), "string contents untouched")
        XCTAssertFalse(out.contains("/* c */"))
        XCTAssertFalse(out.contains("// tail"))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: Data(out.utf8)),
                        "result must be strict JSON")
    }

    func test_errors_are_typed() {
        XCTAssertThrowsError(
            try VSCodeThemeImporter.parse(Data("not json".utf8), fallbackName: "x")
        ) { e in
            guard case VSCodeThemeImporter.ImportError.notJSON = e else {
                return XCTFail("expected notJSON, got \(e)")
            }
        }
        XCTAssertThrowsError(
            try VSCodeThemeImporter.parse(Data(#"{"name":"n"}"#.utf8), fallbackName: "x")
        ) { e in
            XCTAssertEqual(e as? VSCodeThemeImporter.ImportError, .missingEditorColors)
        }
    }

    func test_importFile_installsIntoStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-vsimport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let themeFile = dir.appendingPathComponent("incoming.json")
        try fixture.write(to: themeFile, atomically: true, encoding: .utf8)
        let store = ThemeStore(
            userDir: dir.appendingPathComponent("Themes"),
            defaults: UserDefaults(suiteName: "vsimport-\(UUID())")!)
        let def = try VSCodeThemeImporter.importFile(at: themeFile, into: store)
        XCTAssertTrue(store.all().contains { $0.id == def.id },
                      "imported theme must appear in the store catalog")
        store.selectedID = def.id
        XCTAssertEqual(store.active(isDarkAppearance: false).displayName, "Test Theme 2026")
    }
}
