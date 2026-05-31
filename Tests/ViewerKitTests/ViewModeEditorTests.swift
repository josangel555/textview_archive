import XCTest
@testable import ViewerKit

final class ViewModeEditorTests: XCTestCase {
    private func modes(_ path: String) -> [ViewMode] {
        ViewModeOptions.availableModes(for: URL(fileURLWithPath: path))
    }

    // MARK: - Inclusion (text-shaped files)

    func test_includesEditor_forPlainText() {
        XCTAssertTrue(modes("/tmp/notes.txt").contains(.editor))
        XCTAssertTrue(modes("/tmp/server.log").contains(.editor))
    }

    func test_includesEditor_forMarkdown() {
        XCTAssertTrue(modes("/tmp/README.md").contains(.editor))
    }

    func test_includesEditor_forCode() {
        XCTAssertTrue(modes("/tmp/main.swift").contains(.editor))
        XCTAssertTrue(modes("/tmp/server.py").contains(.editor))
        XCTAssertTrue(modes("/tmp/config.json").contains(.editor))
    }

    func test_includesEditor_forHTML() {
        XCTAssertTrue(modes("/tmp/page.html").contains(.editor))
    }

    func test_includesEditor_forCSV() {
        // CSV / TSV get the default `.table` view but can still be
        // round-tripped as text, so editor is legal.
        XCTAssertTrue(modes("/tmp/data.csv").contains(.editor))
    }

    func test_includesEditor_forExtensionlessText() {
        XCTAssertTrue(modes("/tmp/LICENSE").contains(.editor))
        XCTAssertTrue(modes("/tmp/Makefile").contains(.editor))
    }

    // MARK: - Exclusion (binary / non-editable categories)

    func test_excludesEditor_forImage() {
        XCTAssertFalse(modes("/tmp/pic.png").contains(.editor))
        XCTAssertFalse(modes("/tmp/pic.jpg").contains(.editor))
    }

    func test_excludesEditor_forAudio() {
        XCTAssertFalse(modes("/tmp/song.mp3").contains(.editor))
    }

    func test_excludesEditor_forVideo() {
        XCTAssertFalse(modes("/tmp/clip.mp4").contains(.editor))
    }

    func test_excludesEditor_forPDF() {
        XCTAssertFalse(modes("/tmp/doc.pdf").contains(.editor))
    }

    func test_excludesEditor_forSQLite() {
        XCTAssertFalse(modes("/tmp/db.sqlite").contains(.editor))
    }

    func test_excludesEditor_forDiff() {
        // Diffs render as side-by-side hunks; editing the rendered
        // form would silently desync from the real repo state.
        XCTAssertFalse(modes("/tmp/patch.diff").contains(.editor))
        XCTAssertFalse(modes("/tmp/change.patch").contains(.editor))
    }

    // MARK: - Position in picker

    func test_editor_slotsImmediatelyAfterSource() {
        let m = modes("/tmp/foo.txt")
        guard let s = m.firstIndex(of: .source),
              let e = m.firstIndex(of: .editor) else {
            return XCTFail("expected both .source and .editor: \(m)")
        }
        XCTAssertEqual(e, s + 1, "editor should slot directly after source; got \(m)")
    }

    func test_defaultMode_isNotEditor() {
        // Adding `.editor` to the picker must not change the
        // default-on view mode for any existing file type.
        XCTAssertNotEqual(ViewModeOptions.defaultMode(for: URL(fileURLWithPath: "/tmp/x.txt")), .editor)
        XCTAssertNotEqual(ViewModeOptions.defaultMode(for: URL(fileURLWithPath: "/tmp/r.md")), .editor)
        XCTAssertNotEqual(ViewModeOptions.defaultMode(for: URL(fileURLWithPath: "/tmp/d.csv")), .editor)
    }

    // MARK: - supportsEditor introspection

    func test_supportsEditor_predicate() {
        XCTAssertTrue(ViewModeOptions.supportsEditor(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertTrue(ViewModeOptions.supportsEditor(URL(fileURLWithPath: "/tmp/a.swift")))
        XCTAssertFalse(ViewModeOptions.supportsEditor(URL(fileURLWithPath: "/tmp/a.png")))
        XCTAssertFalse(ViewModeOptions.supportsEditor(URL(fileURLWithPath: "/tmp/a.diff")))
    }

    // MARK: - Source gating for binary / unknown / media (bug3)

    // An unknown-extension file (e.g. `mydb.db.bak`) lands as `.unknown` and is
    // shown in HexView; offering "Source" was a dead control. The picker must
    // be HEX-only and the default must be HEX, not an unreachable Source.
    func test_unknownExtension_isHexOnly() {
        let m = modes("/tmp/mydb.db.bak")
        XCTAssertEqual(m, [.hex], "unknown/binary-shaped files must offer HEX only; got \(m)")
        XCTAssertFalse(m.contains(.source), "Source must be gated out for unknown files (bug3)")
    }

    func test_unknownExtension_defaultsToHex() {
        XCTAssertEqual(ViewModeOptions.defaultMode(for: URL(fileURLWithPath: "/tmp/x.bak")), .hex)
        XCTAssertEqual(ViewModeOptions.defaultMode(for: URL(fileURLWithPath: "/tmp/blob.xyzzy")), .hex)
    }

    // Media / preview categories render via the `.preview` document state and
    // have no text representation — Source must not appear in their picker.
    func test_mediaCategories_excludeSource() {
        for path in ["/tmp/pic.png", "/tmp/song.mp3", "/tmp/clip.mp4",
                     "/tmp/doc.pdf", "/tmp/db.sqlite"] {
            let m = modes(path)
            XCTAssertFalse(m.contains(.source), "Source must be gated out for \(path); got \(m)")
            XCTAssertTrue(m.contains(.hex), "HEX must remain available for \(path); got \(m)")
        }
    }

    // Text-shaped files keep Source (no over-gating regression).
    func test_textFiles_keepSource() {
        XCTAssertTrue(modes("/tmp/notes.txt").contains(.source))
        XCTAssertTrue(modes("/tmp/main.swift").contains(.source))
        XCTAssertTrue(modes("/tmp/README.md").contains(.source))
        XCTAssertTrue(modes("/tmp/LICENSE").contains(.source), "extensionless text is .plainText, keeps Source")
    }

    // The empty-tab placeholder relies on the nil-URL baseline staying
    // [.source, .hex] — keep that contract intact.
    func test_nilURL_baselineUnchanged() {
        XCTAssertEqual(ViewModeOptions.availableModes(for: nil), [.source, .hex])
        XCTAssertEqual(ViewModeOptions.defaultMode(for: nil), .source)
    }
}
