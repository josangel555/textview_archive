import XCTest
@testable import ViewerCore

/// TSK-1448 — the first-run one-shot + the sample document.
final class FirstRunExperienceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        suite = "mdv-firstrun-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func test_offer_isOneShot() {
        XCTAssertTrue(FirstRunExperience.shouldOffer(defaults: defaults),
                      "a fresh install offers the sample")
        FirstRunExperience.markShown(defaults: defaults)
        XCTAssertFalse(FirstRunExperience.shouldOffer(defaults: defaults),
                       "shown/dismissed once → never offered again")
    }

    func test_sampleDocument_exercisesTheLenses() {
        let doc = FirstRunExperience.sampleDocument
        XCTAssertTrue(doc.hasPrefix("# Welcome to TextView"), "title heading")
        XCTAssertTrue(doc.contains("```swift"), "a highlighted code fence")
        XCTAssertTrue(doc.contains("```mermaid"), "a mermaid diagram block")
        XCTAssertTrue(doc.contains("| Lens"), "a table")
        XCTAssertTrue(doc.contains("- [ ]"), "a task list")
        XCTAssertGreaterThanOrEqual(
            doc.components(separatedBy: "\n## ").count - 1, 4,
            "several sections so the outline panel has something to show")
    }

    func test_sample_parsesToARealOutline() {
        // The sample must actually feed the outline panel it advertises.
        let headings = MarkdownOutline.headings(in: FirstRunExperience.sampleDocument)
        XCTAssertGreaterThanOrEqual(headings.count, 5)
        XCTAssertEqual(headings.first?.title, "Welcome to TextView")
    }

    func test_writeSample_writesAndNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-1448-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try FirstRunExperience.writeSample(to: dir)
        XCTAssertEqual(first.lastPathComponent, "Welcome to TextView.md")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8),
                       FirstRunExperience.sampleDocument)

        // A file already at the name (e.g. the user's own) is NEVER
        // overwritten — the second write lands on a sibling.
        try "user's own precious file".write(to: first, atomically: true, encoding: .utf8)
        let second = try FirstRunExperience.writeSample(to: dir)
        XCTAssertEqual(second.lastPathComponent, "Welcome to TextView-2.md")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8),
                       "user's own precious file", "the existing file is untouched")
    }
}
