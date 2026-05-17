import XCTest
@testable import ViewerCore

/// Tests assume `/usr/bin/jq` ships on the test host (true for
/// macOS 15+). On older hosts the entire suite is auto-skipped.
final class JQRunnerTests: XCTestCase {

    override func setUpWithError() throws {
        guard JQRunner.isAvailable else {
            throw XCTSkip("jq not installed at /usr/bin/jq or /opt/homebrew/bin/jq")
        }
    }

    func test_identity_filter_returns_input() throws {
        let out = try JQRunner.run(filter: ".", json: "{\"a\":1}")
        XCTAssertTrue(out.contains("\"a\""))
        XCTAssertTrue(out.contains("1"))
    }

    func test_field_access() throws {
        let out = try JQRunner.run(filter: ".name", json: "{\"name\":\"jos\",\"age\":40}")
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "\"jos\"")
    }

    func test_array_index_chain() throws {
        let out = try JQRunner.run(
            filter: ".users[0].id",
            json: "{\"users\":[{\"id\":7},{\"id\":8}]}"
        )
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "7")
    }

    func test_invalid_filter_throws() {
        XCTAssertThrowsError(
            try JQRunner.run(filter: "this is not jq", json: "{}")
        ) { err in
            guard case JQRunner.Error.filterError(_, let msg) = err else {
                XCTFail("expected filterError, got \(err)"); return
            }
            XCTAssertFalse(msg.isEmpty, "stderr should be surfaced")
        }
    }

    func test_invalid_input_json_throws() {
        XCTAssertThrowsError(
            try JQRunner.run(filter: ".", json: "{not json")
        ) { err in
            guard case JQRunner.Error.filterError = err else {
                XCTFail("expected filterError, got \(err)"); return
            }
        }
    }

    func test_large_input_does_not_deadlock() throws {
        // Build ~200 KB of JSON — past the ~64 KB pipe buffer that
        // would deadlock a single-thread read of stderr (the bug
        // GitService.run already documents). Verifies our concurrent
        // pipe drain.
        let large = (0..<5000).map { "\"k\($0)\":\($0)" }.joined(separator: ",")
        let json = "{\(large)}"
        XCTAssertGreaterThan(json.count, 60_000)
        let out = try JQRunner.run(filter: "keys | length", json: json)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "5000")
    }
}
