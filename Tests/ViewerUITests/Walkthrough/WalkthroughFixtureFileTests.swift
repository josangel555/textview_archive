import XCTest
@testable import ViewerUI
import ViewerCore

/// Smoke-tests the on-disk fixture at
/// `Tests/Fixtures/walkthroughs/sample.json`. The fixture is the
/// shape an external agent would produce, so verifying it parses
/// catches drift between the doc'd shape and the implemented schema.
///
/// Skips gracefully when the fixture isn't present (it ships with the
/// repo but may be absent from a stripped distribution).
@MainActor
final class WalkthroughFixtureFileTests: XCTestCase {

    func test_diskFixture_loadsAndHasExpectedSteps() throws {
        // SwiftPM doesn't bundle Tests/Fixtures unless we declare a
        // resource — we don't, so the runtime path is via #file +
        // relative path. That's intentional: keeps the fixture as
        // plain JSON that humans can edit, no bundle indirection.
        let here = URL(fileURLWithPath: #filePath)
        let fixture = here
            .deletingLastPathComponent()
            .deletingLastPathComponent()   // ViewerUITests/Walkthrough
            .deletingLastPathComponent()   // ViewerUITests
            .appendingPathComponent("Fixtures/walkthroughs/sample.json")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            // Don't fail — the test is a smoke check, not a gate.
            // Print the path so the dev knows where it should live.
            print("[skip] fixture missing: \(fixture.path)")
            return
        }
        switch WalkthroughLoader.load(fileAt: fixture) {
        case .success(let script):
            XCTAssertEqual(script.id, "sample")
            XCTAssertEqual(script.steps.count, 3)
        case .failure(let err):
            XCTFail("fixture failed to load: \(err)")
        }
    }
}
