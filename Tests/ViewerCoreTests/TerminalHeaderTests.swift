import XCTest
@testable import ViewerCore

/// TSK-1249 — the terminal header formatter: composition + home abbreviation.
final class TerminalHeaderTests: XCTestCase {

    private let home = "/Users/tester"

    func test_fullHeader() {
        XCTAssertEqual(
            TerminalHeader.format(name: "build", cwd: "/Users/tester/proj", pid: 4242, home: home),
            "Terminal — build [~/proj, pid 4242]")
    }

    func test_homeAbbreviation() {
        XCTAssertEqual(TerminalHeader.abbreviateHome("/Users/tester", home: home), "~")
        XCTAssertEqual(TerminalHeader.abbreviateHome("/Users/tester/a/b", home: home), "~/a/b")
        XCTAssertEqual(TerminalHeader.abbreviateHome("/etc/hosts", home: home), "/etc/hosts")
        // A trailing-slash home is normalized.
        XCTAssertEqual(TerminalHeader.abbreviateHome("/Users/tester/x", home: "/Users/tester/"), "~/x")
        // A prefix that isn't a path boundary must NOT abbreviate.
        XCTAssertEqual(TerminalHeader.abbreviateHome("/Users/vm-tester/x", home: home),
                       "/Users/vm-tester/x")
    }

    func test_missingFields() {
        // No cwd yet, no pid → bare title.
        XCTAssertEqual(TerminalHeader.format(name: "shell", cwd: nil, pid: nil, home: home),
                       "Terminal — shell")
        // Empty name → just "Terminal" + bracket.
        XCTAssertEqual(TerminalHeader.format(name: "  ", cwd: "/tmp", pid: 9, home: home),
                       "Terminal [/tmp, pid 9]")
        // pid only.
        XCTAssertEqual(TerminalHeader.format(name: "x", cwd: nil, pid: 100, home: home),
                       "Terminal — x [pid 100]")
        // cwd only.
        XCTAssertEqual(TerminalHeader.format(name: "x", cwd: "/tmp", pid: nil, home: home),
                       "Terminal — x [/tmp]")
        // Nothing at all.
        XCTAssertEqual(TerminalHeader.format(name: "", cwd: nil, pid: nil, home: home),
                       "Terminal")
    }
}
