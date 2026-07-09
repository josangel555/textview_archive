import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1448 — host tests for the first-run sample glue: openFirstRunSample writes
/// the tour doc + opens it. The one-shot latch, the sample content, and the
/// collision-safe write are pinned by FirstRunExperienceTests; these pin the
/// model wiring (inject a temp dir so the real App Support Samples dir is untouched).
@MainActor
final class DocumentModelFirstRunTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirstRun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeModel() -> DocumentModel {
        let defaults = UserDefaults(suiteName: "FirstRun-\(UUID().uuidString)")!
        return DocumentModel(
            history: HistoryStore(storeURL: tmp.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
    }

    func test_openFirstRunSample_writesTheTour_andOpensIt() {
        let model = makeModel()
        let url = model.openFirstRunSample(dir: tmp)
        let opened = try? XCTUnwrap(url)
        XCTAssertEqual(opened?.lastPathComponent, "Welcome to TextView.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: opened!.path), "the sample was written")
        let content = try? String(contentsOf: opened!, encoding: .utf8)
        XCTAssertEqual(content, FirstRunExperience.sampleDocument, "content is the tour document")
        XCTAssertTrue(model.tabs.tabs.contains { $0.url?.standardizedFileURL == opened!.standardizedFileURL },
                      "the sample is opened in a tab")
    }

    func test_openFirstRunSample_neverOverwritesAUsersOwnFile() throws {
        // A user's own "Welcome to TextView.md" already at the target.
        let mine = tmp.appendingPathComponent("Welcome to TextView.md")
        try "MY notes — keep me\n".write(to: mine, atomically: true, encoding: .utf8)
        let model = makeModel()
        let url = model.openFirstRunSample(dir: tmp)
        XCTAssertNotEqual(url?.standardizedFileURL, mine.standardizedFileURL,
                          "the sample lands on a non-colliding sibling")
        XCTAssertEqual(try String(contentsOf: mine, encoding: .utf8), "MY notes — keep me\n",
                       "the user's file is untouched (U5)")
    }

    // MARK: - TSK-1575: Help ▸ Capabilities

    func test_openCapabilities_writesTheGuide_andOpensIt() throws {
        let model = makeModel()
        // No bundled resource under test ⇒ the fallback content is used.
        let url = try XCTUnwrap(model.openCapabilities(dir: tmp))
        XCTAssertEqual(url.lastPathComponent, "Capabilities.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       CapabilitiesDocument.markdown(in: .main),
                       "the opened file carries the capabilities content")
        XCTAssertTrue(model.tabs.tabs.contains { $0.url?.standardizedFileURL == url.standardizedFileURL },
                      "capabilities opens in a tab")
    }

    func test_openCapabilities_overwritesItsOwnCopy_noProliferation() throws {
        let model = makeModel()
        let first = try XCTUnwrap(model.openCapabilities(dir: tmp))
        let second = try XCTUnwrap(model.openCapabilities(dir: tmp))
        XCTAssertEqual(first.standardizedFileURL, second.standardizedFileURL,
                       "re-opening reuses the same Capabilities.md (no Capabilities-2.md)")
    }
}
