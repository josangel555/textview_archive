import XCTest
import ViewerCore

/// TSK-1326 — the in-app "New Walkthrough" seed. The starter template must be a
/// valid walkthrough, and `create` must write a parseable file with collision-safe
/// names so a second "New Walkthrough" never overwrites an existing tour, and a
/// hostile base name can't escape the library directory.
final class WalkthroughCatalogCreateTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WT-Create-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func test_starterTemplate_isAValidWalkthrough() {
        let data = Data(WalkthroughCatalog.starterTemplateJSON.utf8)
        guard case .success(let script) = WalkthroughLoader.load(data: data) else {
            return XCTFail("the starter template must parse as a valid walkthrough")
        }
        XCTAssertGreaterThanOrEqual(script.steps.count, 3, "the starter shows a few steps")
        XCTAssertEqual(Set(script.steps.map(\.id)).count, script.steps.count, "step IDs unique")
    }

    func test_create_writesAParseableFile() throws {
        let url = try XCTUnwrap(WalkthroughCatalog.create(baseName: "My Walkthrough", in: dir))
        XCTAssertEqual(url.pathExtension, "json")
        let data = try Data(contentsOf: url)
        guard case .success = WalkthroughLoader.load(data: data) else {
            return XCTFail("create() must write a parseable walkthrough file")
        }
    }

    func test_create_twice_doesNotOverwrite_collisionSafeNames() throws {
        let a = try XCTUnwrap(WalkthroughCatalog.create(baseName: "Tour", in: dir))
        let b = try XCTUnwrap(WalkthroughCatalog.create(baseName: "Tour", in: dir))
        XCTAssertNotEqual(a, b, "a second New Walkthrough must NOT reuse/overwrite the first file")
        XCTAssertEqual(a.lastPathComponent, "Tour.json")
        XCTAssertEqual(b.lastPathComponent, "Tour 2.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func test_create_sanitizesTraversalBaseName_staysInDirectory() throws {
        let url = try XCTUnwrap(WalkthroughCatalog.create(baseName: "../evil", in: dir))
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL,
                       dir.standardizedFileURL,
                       "a traversal base name must not escape the target directory")
        XCTAssertEqual(url.lastPathComponent, "My Walkthrough.json", "falls back to the safe default")
    }
}
