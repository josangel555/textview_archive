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
}
