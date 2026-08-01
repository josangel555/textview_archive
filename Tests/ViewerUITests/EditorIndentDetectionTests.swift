import XCTest
import ViewerCore
@testable import ViewerUI

/// I-04 (owner intake 2026-08-01) — "indent markers on a file detected as 4SP
/// are 2 spaces apart": the detector's result never reached the editor, so the
/// CM6 `indentUnit` facet (guide pitch, Tab inserts, indent commands) always
/// used the global Settings preference. These tests pin the per-tab override:
/// parse → detect-on-seed → effective resolution → cleared with the buffer.
@MainActor
final class EditorIndentDetectionTests: XCTestCase {
    private var tmpDir: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IndentDetect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Parser

    func test_parseDetected_matrix() {
        XCTAssertEqual(CMIndentation.parseDetected("Spaces (4)"), .spaces(4))
        XCTAssertEqual(CMIndentation.parseDetected("Spaces (2)"), .spaces(2))
        XCTAssertEqual(CMIndentation.parseDetected("Tabs", tabWidth: 4), .tabs(width: 4))
        XCTAssertNil(CMIndentation.parseDetected("—"), "unknown must not override")
        XCTAssertNil(CMIndentation.parseDetected(""), "empty must not override")
        XCTAssertNil(CMIndentation.parseDetected("Spaces (0)"), "0 is not a unit")
        XCTAssertNil(CMIndentation.parseDetected("Spaces (99)"), "clamped out")
    }

    // MARK: - Coordinator behavior

    /// Deeply 4-space-indented content, enough lines for the detector.
    private var fourSpaceBody: String {
        (1...20).map { i in
            "func f\(i)() {\n    let a = 1\n    if a > 0 {\n        use(a)\n    }\n}"
        }.joined(separator: "\n") + "\n"
    }

    private func openTab(_ contents: String, name: String = "a.swift") throws -> (DocumentModel, UUID) {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        let model = DocumentModel()
        model.open(url: url)
        let id = model.tabs.selected!.id
        return (model, id)
    }

    func test_fourSpaceFile_overridesTheGlobalTwoSpaceDefault() throws {
        let (model, id) = try openTab(fourSpaceBody)
        XCTAssertEqual(model.editor.editorIndentation, .spaces(2), "precondition: global default")

        _ = model.editor.editorBuffer(forTabID: id)          // seeds + schedules detection
        drainMainQueue()

        XCTAssertEqual(model.editor.editorIndentationOverrides[id], .spaces(4),
            "the detected 4-space indent must be recorded for the tab")
        XCTAssertEqual(model.editor.effectiveIndentation(forTabID: id), .spaces(4),
            "the editor must USE the file's detected indent")
    }

    func test_tabWithoutDetection_usesTheGlobalPreference() throws {
        let (model, id) = try openTab("no indentation here\nplain lines\n", name: "flat.txt")
        _ = model.editor.editorBuffer(forTabID: id)
        drainMainQueue()

        XCTAssertNil(model.editor.editorIndentationOverrides[id],
            "an unindented file must not manufacture an override")
        XCTAssertEqual(model.editor.effectiveIndentation(forTabID: id),
                       model.editor.editorIndentation)
        XCTAssertEqual(model.editor.effectiveIndentation(forTabID: nil),
                       model.editor.editorIndentation, "nil tab = global")
    }

    func test_discardBuffer_clearsTheOverride_andRedetectsOnReseed() throws {
        let (model, id) = try openTab(fourSpaceBody)
        model.editor.applyDetectedIndentation(text: fourSpaceBody, forTabID: id)
        XCTAssertEqual(model.editor.editorIndentationOverrides[id], .spaces(4))

        model.editor.discardEditorBuffer(forTabID: id)
        XCTAssertNil(model.editor.editorIndentationOverrides[id],
            "the override belongs to the buffer's content — discard clears it")

        // Re-seed → detection runs again (the attempted-set was cleared too).
        _ = model.editor.editorBuffer(forTabID: id)
        drainMainQueue()
        XCTAssertEqual(model.editor.editorIndentationOverrides[id], .spaces(4),
            "a re-seeded buffer re-detects")
    }

    func test_detectionMatchingTheGlobal_recordsNoOverride() {
        let model = DocumentModel()
        let id = UUID()
        model.editor.applyDetectedIndentation(
            text: "a\n  b\n  c\n    d\n  e\n", forTabID: id)   // 2-space content
        XCTAssertNil(model.editor.editorIndentationOverrides[id],
            "detected == global ⇒ no redundant override entry")
    }

    // MARK: - View wiring pin (source-level)

    func test_contentView_feedsTheEditor_thePerTabEffectiveIndentation() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()               // ViewerUITests/
            .deletingLastPathComponent()               // Tests/
            .deletingLastPathComponent()               // repo root
            .appendingPathComponent("Sources/ViewerUI/ContentView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            source.contains("effectiveIndentation(forTabID: tid)"),
            "the CM6 editor must receive the per-tab EFFECTIVE indentation (I-04)")
    }

    private func drainMainQueue() {
        let exp = expectation(description: "main-queue drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }
}
