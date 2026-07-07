import XCTest
import SwiftUI
@testable import ViewerCore
@testable import ViewerUI

/// TSK-1439 — the SQLite browser's Export menu wiring. The pure serialization is
/// covered by `SQLiteResultExportTests`; this pins the exact code the menu items
/// run: `exportedText(_:)` / `copyResult(_:to:)` on the view model. Drives a
/// scratch pasteboard so the developer's real clipboard is never clobbered.
@MainActor
final class SQLiteBrowserExportTests: XCTestCase {

    private func makeModel(withResult: Bool) -> SQLiteBrowserModel {
        // init(url:) only stores the URL; load() (which opens the DB) is never
        // called, so no file is touched — this exercises the export seam alone.
        let m = SQLiteBrowserModel(url: URL(fileURLWithPath: "/nonexistent.sqlite"))
        if withResult {
            m.queryResult = SQLiteReader.QueryResult(
                columns: ["id", "name"],
                rows: [["1", "alice"], ["2", nil]],
                truncated: false)
        }
        return m
    }

    func test_exportedText_nilWhenNoResult() {
        let m = makeModel(withResult: false)
        XCTAssertFalse(m.canExport)
        XCTAssertNil(m.exportedText(.csv))
        XCTAssertNil(m.exportedText(.markdown))
        XCTAssertNil(m.exportedText(.json))
    }

    func test_exportedText_csvMatchesSerializer() {
        let m = makeModel(withResult: true)
        XCTAssertTrue(m.canExport)
        XCTAssertEqual(m.exportedText(.csv), "id,name\n1,alice\n2,")
    }

    func test_copyResult_writesSerializedTextToPasteboard() {
        let m = makeModel(withResult: true)
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        m.copyResult(.csv, to: pb)
        XCTAssertEqual(pb.string(forType: .string), "id,name\n1,alice\n2,")
    }

    func test_copyResult_noResult_leavesPasteboardEmpty() {
        let m = makeModel(withResult: false)
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("sentinel", forType: .string)
        m.copyResult(.csv, to: pb)
        // No result → we never touch the pasteboard (the sentinel survives).
        XCTAssertEqual(pb.string(forType: .string), "sentinel")
    }
}
