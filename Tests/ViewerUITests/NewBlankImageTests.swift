import XCTest
import ImageIO
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1054 — teeth for File ▸ New Image at the model layer: createNewBlankImage
/// writes a valid PNG to the target directory and uniquely names repeats. (The
/// menu/command entry + opening it in the editor are the review-ceiling render
/// bits; the blank-PNG bytes are covered by BlankImageCreatorTests.)
@MainActor
final class NewBlankImageTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("NewImage-\(UUID().uuidString)")
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
                suiteName: "NewImage-\(UUID().uuidString)")!))
    }

    func test_createNewBlankImage_writesValidPNG() throws {
        let url = try XCTUnwrap(makeModel().createNewBlankImage(in: tmp))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "png")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47], "valid PNG bytes")
    }

    func test_createNewBlankImage_honorsCustomDimensions() throws {
        // TSK-1208: the size dialog's values plumb through to the written PNG.
        let url = try XCTUnwrap(makeModel().createNewBlankImage(in: tmp, width: 120, height: 80))
        let data = try Data(contentsOf: url)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(cg.width, 120)
        XCTAssertEqual(cg.height, 80)
    }

    func test_createNewBlankImage_uniquesRepeats() throws {
        let model = makeModel()
        let a = try XCTUnwrap(model.createNewBlankImage(in: tmp))
        let b = try XCTUnwrap(model.createNewBlankImage(in: tmp))
        XCTAssertNotEqual(a, b, "a second new image must not overwrite the first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }
}
