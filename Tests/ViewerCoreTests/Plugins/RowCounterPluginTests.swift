import XCTest
@testable import ViewerCore

@MainActor
final class RowCounterPluginTests: XCTestCase {

    func test_lineCount_empty_is_zero() {
        XCTAssertEqual(RowCounterPlugin.lineCount(of: ""), 0)
    }

    func test_lineCount_single_line_no_newline() {
        XCTAssertEqual(RowCounterPlugin.lineCount(of: "hello"), 1)
    }

    func test_lineCount_trailing_newline_counts_one_line() {
        XCTAssertEqual(RowCounterPlugin.lineCount(of: "hello\n"), 1)
    }

    func test_lineCount_two_lines_with_trailing_newline() {
        XCTAssertEqual(RowCounterPlugin.lineCount(of: "a\nb\n"), 2)
    }

    func test_lineCount_two_lines_without_trailing_newline() {
        XCTAssertEqual(RowCounterPlugin.lineCount(of: "a\nb"), 2)
    }

    /// TSK-612: the old grapheme loop compared each Character to "\n";
    /// "\r\n" is ONE grapheme that is not equal to "\n", so a CRLF file
    /// collapsed to 1 line. The UTF-8 byte scan counts it correctly.
    func test_lineCount_crlf_countsEveryLine() {
        XCTAssertEqual(RowCounterPlugin.lineCount(of: "a\r\nb\r\nc\r\n"), 3)
        XCTAssertEqual(RowCounterPlugin.lineCount(of: "a\r\nb"), 2)
    }

    /// TSK-612: the provider runs inside the sidebar's SwiftUI body on
    /// every re-evaluation — unchanged contents must NOT be rescanned.
    func test_rows_memoizesUnchangedContents() {
        let url = URL(fileURLWithPath: "/tmp/memo.txt")
        let snap = SidebarSectionRegistry.Snapshot(openFileContents: [url: "a\nb\nc"])

        RowCounterPlugin.coldCountComputations = 0
        _ = RowCounterPlugin.rows(for: snap)
        XCTAssertEqual(RowCounterPlugin.coldCountComputations, 1, "first call counts")

        _ = RowCounterPlugin.rows(for: snap)
        XCTAssertEqual(RowCounterPlugin.coldCountComputations, 1,
                       "re-render with unchanged contents must hit the memo")

        let changed = SidebarSectionRegistry.Snapshot(openFileContents: [url: "a\nb\nc\nd"])
        let rows = RowCounterPlugin.rows(for: changed)
        XCTAssertEqual(RowCounterPlugin.coldCountComputations, 2, "changed contents recount")
        XCTAssertEqual(rows[0].detail, "4 lines")
    }

    // Provider is pure: same snapshot in → same rows out, in sorted
    // order. Sorting matters because the host iterates a dict.
    func test_rows_are_sorted_by_path() {
        let u1 = URL(fileURLWithPath: "/tmp/zzz.txt")
        let u2 = URL(fileURLWithPath: "/tmp/aaa.txt")
        let snap = SidebarSectionRegistry.Snapshot(openFileContents: [
            u1: "x\ny\nz",
            u2: "only one line",
        ])
        let rows = RowCounterPlugin.rows(for: snap)
        XCTAssertEqual(rows.map(\.label), ["aaa.txt", "zzz.txt"])
        XCTAssertEqual(rows[0].detail, "1 lines")
        XCTAssertEqual(rows[1].detail, "3 lines")
    }

    func test_registers_one_sidebar_entry() {
        PluginRegistry.shared._resetForTests()
        RowCounterPlugin.register()
        let entries = PluginRegistry.shared.sidebarSections.all
            .filter { $0.pluginID == RowCounterPlugin.id }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].sectionID, "row-counts")
    }
}
