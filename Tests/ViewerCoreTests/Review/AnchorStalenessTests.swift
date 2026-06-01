import XCTest
@testable import ViewerCore

/// Stage 1 (§7): the §3.2 staleness truth table. `.current` on a blob match,
/// `.stale` on a mismatch, `.unknown` whenever either side is nil/empty
/// (no claim possible). Pure logic — no git process.
final class AnchorStalenessTests: XCTestCase {

    func test_current_whenBlobsMatch() {
        XCTAssertEqual(
            AnchorState.evaluate(capturedBlobSha: "deadbeef", liveBlobSha: "deadbeef"),
            .current
        )
    }

    func test_stale_whenBlobsDiffer() {
        XCTAssertEqual(
            AnchorState.evaluate(capturedBlobSha: "deadbeef", liveBlobSha: "cafebabe"),
            .stale
        )
    }

    func test_unknown_whenCapturedIsNil() {
        XCTAssertEqual(
            AnchorState.evaluate(capturedBlobSha: nil, liveBlobSha: "cafebabe"),
            .unknown
        )
    }

    func test_unknown_whenLiveIsNil() {
        XCTAssertEqual(
            AnchorState.evaluate(capturedBlobSha: "deadbeef", liveBlobSha: nil),
            .unknown
        )
    }

    func test_unknown_whenBothNil() {
        XCTAssertEqual(
            AnchorState.evaluate(capturedBlobSha: nil, liveBlobSha: nil),
            .unknown
        )
    }

    func test_unknown_treatsEmptyStringAsNoClaim() {
        // An empty SHA is degenerate — never claim `.current`/`.stale`.
        XCTAssertEqual(AnchorState.evaluate(capturedBlobSha: "", liveBlobSha: "x"), .unknown)
        XCTAssertEqual(AnchorState.evaluate(capturedBlobSha: "x", liveBlobSha: ""), .unknown)
    }

    func test_anchorConvenienceOverload_usesAnchorBlobSha() {
        let withSha = LineAnchor(side: .new, startLine: 1, endLine: 1, blobSha: "deadbeef")
        let noSha = LineAnchor(side: .new, startLine: 1, endLine: 1, blobSha: nil)
        XCTAssertEqual(AnchorState.evaluate(anchor: withSha, liveBlobSha: "deadbeef"), .current)
        XCTAssertEqual(AnchorState.evaluate(anchor: withSha, liveBlobSha: "other"), .stale)
        XCTAssertEqual(AnchorState.evaluate(anchor: noSha, liveBlobSha: "deadbeef"), .unknown)
    }
}
