import XCTest
@testable import ViewerCore

/// TSK-694 — auto-cluster recurring log patterns. Pure-logic foundation slice:
/// masking-then-bucketing. These pin the masking rules AND the cluster ranking
/// so a regression in either fails the host gate.
final class LogPatternClustererTests: XCTestCase {

    // MARK: - templatize: masking rules

    func test_templatize_masksGenericNumbers() {
        XCTAssertEqual(
            LogPatternClusterer.templatize("Request 42 took 13ms"),
            "Request <NUM> took <NUM>ms"
        )
    }

    func test_templatize_masksDecimalAndSignedNumbers() {
        XCTAssertEqual(
            LogPatternClusterer.templatize("delta -3.14 ratio +0.5"),
            "delta <NUM> ratio <NUM>"
        )
    }

    func test_templatize_doesNotMaskNumbersInsideWords() {
        // x86_64 / sha1 are identifiers, not variable numeric fields.
        XCTAssertEqual(
            LogPatternClusterer.templatize("arch x86_64 algo sha1"),
            "arch x86_64 algo sha1"
        )
    }

    func test_templatize_masksISOTimestamp() {
        XCTAssertEqual(
            LogPatternClusterer.templatize("2026-06-18T12:34:56.789Z INFO ready"),
            "<TIMESTAMP> INFO ready"
        )
    }

    func test_templatize_masksSpaceSeparatedTimestamp() {
        XCTAssertEqual(
            LogPatternClusterer.templatize("2026-06-18 12:34:56 WARN slow"),
            "<TIMESTAMP> WARN slow"
        )
    }

    func test_templatize_masksBareClockTime() {
        XCTAssertEqual(
            LogPatternClusterer.templatize("at 09:15:00 server started"),
            "at <TIMESTAMP> server started"
        )
    }

    func test_templatize_masksUUID() {
        XCTAssertEqual(
            LogPatternClusterer.templatize("session 550e8400-e29b-41d4-a716-446655440000 open"),
            "session <UUID> open"
        )
    }

    func test_templatize_masksIPv4WithPort() {
        XCTAssertEqual(
            LogPatternClusterer.templatize("conn from 192.168.1.42:5050 accepted"),
            "conn from <IP> accepted"
        )
    }

    func test_templatize_masksQuotedStrings() {
        XCTAssertEqual(
            LogPatternClusterer.templatize(#"open file "report.csv" mode 'r'"#),
            "open file <STR> mode <STR>"
        )
    }

    func test_templatize_masksHexAndAddresses() {
        XCTAssertEqual(
            LogPatternClusterer.templatize("fault at 0xdeadbeef checksum a1b2c3d4e5"),
            "fault at <HEX> checksum <HEX>"
        )
    }

    func test_templatize_collapsesInternalWhitespace() {
        XCTAssertEqual(
            LogPatternClusterer.templatize("col1    val   end"),
            "col1 val end"
        )
    }

    func test_templatize_caseInsensitiveLowercases() {
        XCTAssertEqual(
            LogPatternClusterer.templatize("ERROR boom", caseInsensitive: true),
            "error boom"
        )
    }

    // MARK: - cluster: bucketing + ranking

    func test_cluster_collapsesVaryingNumbersIntoOnePattern() {
        let log = """
        Request 42 took 13ms
        Request 9001 took 4ms
        Request 7 took 250ms
        """
        let result = LogPatternClusterer.cluster(log)
        XCTAssertEqual(result.distinctPatterns, 1)
        XCTAssertEqual(result.totalLines, 3)
        XCTAssertEqual(result.clusters.first?.template, "Request <NUM> took <NUM>ms")
        XCTAssertEqual(result.clusters.first?.count, 3)
        // Example is the first original line, unmasked.
        XCTAssertEqual(result.clusters.first?.example, "Request 42 took 13ms")
        XCTAssertEqual(result.clusters.first?.lineIndices, [0, 1, 2])
    }

    func test_cluster_distinctPatternsKeptSeparate() {
        let log = """
        GET /users 200
        GET /users 200
        POST /login 401
        cache miss key=7
        """
        let result = LogPatternClusterer.cluster(log)
        // 3 templates: "GET /users <NUM>", "POST /login <NUM>", "cache miss key=<NUM>"
        XCTAssertEqual(result.distinctPatterns, 3)
        XCTAssertEqual(result.totalLines, 4)
    }

    func test_cluster_rankedByCountDescending() {
        let log = """
        beta event
        alpha event
        alpha event
        alpha event
        beta event
        """
        let result = LogPatternClusterer.cluster(log)
        XCTAssertEqual(result.clusters.count, 2)
        // "alpha event" (3) ranks above "beta event" (2).
        XCTAssertEqual(result.clusters[0].template, "alpha event")
        XCTAssertEqual(result.clusters[0].count, 3)
        XCTAssertEqual(result.clusters[1].template, "beta event")
        XCTAssertEqual(result.clusters[1].count, 2)
    }

    func test_cluster_tieBrokenByEarliestMember() {
        // Two patterns with equal counts — the one whose first member appears
        // earlier must rank first (deterministic ordering, no hash flicker).
        let log = """
        zzz first
        aaa second
        zzz first different 9
        aaa second different 9
        """
        // "zzz first" → templates: "zzz first" (1) and "zzz first different <NUM>" (1)
        // "aaa second" → "aaa second" (1) and "aaa second different <NUM>" (1)
        let result = LogPatternClusterer.cluster(log)
        XCTAssertEqual(result.clusters.count, 4)
        // All count==1, so order is by first-seen index: lines 0,1,2,3.
        XCTAssertEqual(result.clusters[0].template, "zzz first")
        XCTAssertEqual(result.clusters[1].template, "aaa second")
        XCTAssertEqual(result.clusters[2].template, "zzz first different <NUM>")
        XCTAssertEqual(result.clusters[3].template, "aaa second different <NUM>")
    }

    func test_cluster_dropsEmptyAndWhitespaceLines() {
        let log = "real line 1\n\n   \nreal line 2\n"
        let result = LogPatternClusterer.cluster(log)
        XCTAssertEqual(result.totalLines, 2)
        // Both collapse to "real line <NUM>".
        XCTAssertEqual(result.distinctPatterns, 1)
        XCTAssertEqual(result.clusters.first?.count, 2)
        // Indices are into the NON-EMPTY stream: 0 and 1, not 0 and 3.
        XCTAssertEqual(result.clusters.first?.lineIndices, [0, 1])
    }

    func test_cluster_crlfLineEndingsHandled() {
        let log = "Request 1 ok\r\nRequest 2 ok\r\n"
        let result = LogPatternClusterer.cluster(log)
        XCTAssertEqual(result.distinctPatterns, 1)
        XCTAssertEqual(result.clusters.first?.template, "Request <NUM> ok")
        XCTAssertEqual(result.clusters.first?.count, 2)
    }

    func test_cluster_realisticMixedLog() {
        let log = """
        2026-06-18T10:00:01Z INFO conn from 10.0.0.1:443 session 550e8400-e29b-41d4-a716-446655440000
        2026-06-18T10:00:02Z INFO conn from 10.0.0.2:8080 session 660e8400-e29b-41d4-a716-446655440001
        2026-06-18T10:00:03Z ERROR timeout after 30s
        2026-06-18T10:00:04Z ERROR timeout after 5s
        """
        let result = LogPatternClusterer.cluster(log)
        // 2 templates: the conn pattern (2) and the timeout pattern (2).
        XCTAssertEqual(result.distinctPatterns, 2)
        XCTAssertEqual(result.totalLines, 4)
        let templates = Set(result.clusters.map(\.template))
        XCTAssertTrue(templates.contains("<TIMESTAMP> INFO conn from <IP> session <UUID>"))
        XCTAssertTrue(templates.contains("<TIMESTAMP> ERROR timeout after <NUM>s"))
    }

    func test_cluster_emptyInput() {
        let result = LogPatternClusterer.cluster("")
        XCTAssertEqual(result.totalLines, 0)
        XCTAssertEqual(result.distinctPatterns, 0)
        XCTAssertTrue(result.clusters.isEmpty)
    }

    func test_cluster_maxLinesCapped() {
        let log = (0..<100).map { "event \($0)" }.joined(separator: "\n")
        let opts = LogPatternClusterer.Options(maxLines: 10)
        let result = LogPatternClusterer.cluster(log, options: opts)
        XCTAssertEqual(result.totalLines, 10)
        // All collapse to "event <NUM>".
        XCTAssertEqual(result.distinctPatterns, 1)
        XCTAssertEqual(result.clusters.first?.count, 10)
    }

    func test_cluster_caseInsensitiveOption() {
        let log = "ERROR boom\nerror boom\nError boom"
        let opts = LogPatternClusterer.Options(caseInsensitive: true)
        let result = LogPatternClusterer.cluster(log, options: opts)
        XCTAssertEqual(result.distinctPatterns, 1)
        XCTAssertEqual(result.clusters.first?.count, 3)
    }

    func test_cluster_caseSensitiveByDefaultKeepsLevelsDistinct() {
        let log = "ERROR boom\nerror boom"
        let result = LogPatternClusterer.cluster(log)
        XCTAssertEqual(result.distinctPatterns, 2)
    }
}
