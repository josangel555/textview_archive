import XCTest
@testable import ViewerCore

/// Host-testable teeth for `GitVersionSource` (TSK-1103). The git subprocess
/// methods (`listVersions`/`content`/`diff`) need a real repo and are exercised
/// in the VM/integration lane; here we pin the PURE pieces: the `%ai` date parse
/// (used for the list timestamp + range ordering) and the protocol defaults.
final class GitVersionSourceTests: XCTestCase {

    func test_parseGitDate_fullTimestampWithZone() {
        let d = GitVersionSource.parseGitDate("2026-05-31 08:12:03 -0700")
        XCTAssertNotNil(d)
        // -0700 → 15:12:03 UTC.
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyy-MM-dd HH:mm:ss"
        XCTAssertEqual(utc.string(from: d!), "2026-05-31 15:12:03")
    }

    func test_parseGitDate_malformed_nil() {
        XCTAssertNil(GitVersionSource.parseGitDate("not a date"))
        XCTAssertNil(GitVersionSource.parseGitDate(""))
    }

    func test_supportsRangeDiff_defaultsTrue() {
        let src = GitVersionSource(
            repoRoot: URL(fileURLWithPath: "/tmp/repo"),
            relativePath: "a.txt",
            displayName: "a.txt")
        XCTAssertTrue(src.supportsRangeDiff)
        XCTAssertEqual(src.displayName, "a.txt")
    }
}
