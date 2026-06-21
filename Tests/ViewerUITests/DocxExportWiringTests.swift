import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1144 — teeth for the "Export as Word" wiring: the active Markdown document
/// exports to a valid .docx (store-ZIP). The exporter itself is covered by
/// DocxExporterTests; this pins the model's active-doc → file path.
@MainActor
final class DocxExportWiringTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocxWiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: UserDefaults(
                suiteName: "Docx-\(UUID().uuidString)")!))
    }

    func test_exportActiveAsDocx_writesValidDocx() throws {
        let md = tmp.appendingPathComponent("doc.md")
        try "# Title\n\nHello **bold**".write(to: md, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.open(url: md)

        let out = tmp.appendingPathComponent("out.docx")
        XCTAssertTrue(model.exportActiveAsDocx(to: out))
        let data = try Data(contentsOf: out)
        XCTAssertEqual(Array([UInt8](data).prefix(4)), [0x50, 0x4b, 0x03, 0x04], "valid ZIP")
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("word/document.xml"))
        XCTAssertTrue(s.contains("Title"), "the heading text made it into the docx")
    }

    func test_exportActiveAsDocx_noActiveFile_isFalse() {
        let model = makeModel()
        XCTAssertFalse(model.exportActiveAsDocx(to: tmp.appendingPathComponent("x.docx")),
                       "no active text document → no export")
    }

    func test_exportActiveAsRTF_writesValidRTF() throws {
        let md = tmp.appendingPathComponent("doc.md")
        try "# Title\n\nHello **bold**".write(to: md, atomically: true, encoding: .utf8)
        let model = makeModel()
        model.open(url: md)

        let out = tmp.appendingPathComponent("out.rtf")
        XCTAssertTrue(model.exportActiveAsRTF(to: out))
        let rtf = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(rtf.hasPrefix("{\\rtf1"), "valid RTF header")
        XCTAssertTrue(rtf.contains("Title"))
        XCTAssertTrue(rtf.contains("\\b "), "bold control word")
    }

    func test_exportActiveAsRTF_noActiveFile_isFalse() {
        let model = makeModel()
        XCTAssertFalse(model.exportActiveAsRTF(to: tmp.appendingPathComponent("x.rtf")))
    }
}
