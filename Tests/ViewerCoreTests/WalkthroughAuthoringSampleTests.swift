import XCTest
import ViewerCore

/// TSK-1326 — guards the DOCUMENTED authoring example so the guide can't rot: the
/// `docs/examples/sample-walkthrough.json` that `docs/WALKTHROUGH_AUTHORING.md` tells authors to
/// copy must always parse as a valid walkthrough (every action kind it shows is real).
final class WalkthroughAuthoringSampleTests: XCTestCase {

    /// Repo root, derived from this test file's location (Tests/ViewerCoreTests/<this>.swift).
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewerCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
    }

    func test_documentedSample_parsesAsAValidWalkthrough() throws {
        let url = repoRoot.appendingPathComponent("docs/examples/sample-walkthrough.json")
        let data = try Data(contentsOf: url)
        let result = WalkthroughLoader.load(data: data)   // requireRootHint:false, trustedRoot:nil
        guard case .success(let script) = result else {
            return XCTFail("docs/examples/sample-walkthrough.json must parse as a walkthrough: \(result)")
        }
        XCTAssertEqual(script.id, "getting-started")
        XCTAssertEqual(script.title, "Getting Started — a sample walkthrough")
        XCTAssertGreaterThanOrEqual(script.steps.count, 4, "the sample demonstrates several steps")
        XCTAssertEqual(script.steps.first?.id, "intro")
        // Step IDs must be unique (the loader rejects dupes — pin that the sample is clean).
        XCTAssertEqual(Set(script.steps.map(\.id)).count, script.steps.count, "step IDs unique")
    }
}
