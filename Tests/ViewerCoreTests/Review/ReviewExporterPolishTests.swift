import XCTest
@testable import ViewerCore

/// Two explicit contract tests for the polish items flagged in
/// commit d2f8a50's CR notes:
///
///   1. Date encoded with `.iso8601` strategy is **whole-second** —
///      sub-second precision is dropped by design. We pin this so a
///      future switch to `.iso8601withFractionalSeconds` doesn't
///      silently break existing review JSON files on disk.
///
///   2. `headSha == nil` for `.workingTree` scope must emit explicit
///      `null` in exported JSON (not omit the key). Round-tripping
///      back through `JSONFileStore.decoder` must recover nil — so
///      external Claude/agent consumers see uncommitted scope
///      unambiguously.
final class ReviewExporterPolishTests: XCTestCase {

    private let pinnedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let exportedAt = Date(timeIntervalSince1970: 1_747_490_528)

    // MARK: - 1. Sub-second date drift is dropped by ISO-8601

    func test_dateSubSecondPrecision_droppedOnRoundTrip_byDesign() throws {
        // A date with fractional seconds. The encoded string must
        // serialize as a whole-second ISO-8601 timestamp (no fraction).
        let withFraction = Date(timeIntervalSince1970: 1_700_000_000.456)
        let r = Review(
            id: "01HXY0000000000000000000P1",
            createdAt: withFraction,
            updatedAt: withFraction,
            title: "T",
            scope: .commit(sha: "abc"),
            repoRoot: "/tmp",
            baseSha: nil, headSha: nil,
            comments: [],
            author: ReviewAuthor(name: "Jos", email: "x")
        )

        // Encode + decode via the canonical pipeline.
        let data = try JSONFileStore.encoder.encode(r)
        let decoded = try JSONFileStore.decoder.decode(Review.self, from: data)

        // Sub-second component is dropped.
        let drift = decoded.createdAt.timeIntervalSince(withFraction)
        XCTAssertEqual(drift, -0.456, accuracy: 0.001,
                       "ISO-8601 strategy is whole-second; sub-second precision must drop")

        // And no fractional component appears in the wire format.
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("2023-11-14T22:13:20Z"),
                      "createdAt should encode as whole-second ISO-8601, got: \(json)")
        XCTAssertFalse(json.contains("22:13:20.4"),
                       "no fractional-seconds — would indicate strategy drift")
    }

    // MARK: - 2. Null headSha round-trips through the DTO

    func test_nullHeadSha_roundTripsThroughDecoder() throws {
        let r = Review(
            id: "01HXY0000000000000000000P2",
            createdAt: pinnedDate, updatedAt: pinnedDate,
            title: "Working tree review",
            scope: .workingTree(base: "HEAD"),
            repoRoot: "/tmp",
            baseSha: "abc",
            headSha: nil,
            comments: [],
            author: ReviewAuthor(name: "Jos", email: "x")
        )
        let data = try ReviewExporter.export(r, exportedAt: exportedAt)

        // Wire format: headSha key present, value null (not omitted).
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains("\"headSha\""),
                      "headSha key must be present in wire format")
        XCTAssertTrue(s.contains("\"headSha\" : null") || s.contains("\"headSha\":null"),
                      "headSha value must be explicit null for working-tree scope")

        // Decoded DTO recovers nil — symmetry test (the consumer
        // side, e.g. an agent reading the export, sees nil/None).
        let dto = try JSONFileStore.decoder.decode(ExportDTO.self, from: data)
        XCTAssertNil(dto.review.repo.headSha,
                     "decoder must round-trip explicit null → nil")
        XCTAssertEqual(dto.review.repo.baseSha, "abc")
    }
}
