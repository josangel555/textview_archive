import AppKit
import XCTest
@testable import ViewerUI

/// TSK-1332 — the diagnostic dump reports a TextKit-2-safe populated-ness metric (`textLength` =
/// textStorage.length), so a UAT can tell a TK2 view is populated even though `numberOfGlyphs`
/// (a TK1 layout-manager count) stays ~0 for an unlaid-out TK2 view. Host-safe: a bare NSTextView,
/// no WebView, no window — so this is NOT a `#192` suite and runs in the headless gate.
@MainActor
final class DiagnosticDumpTextLengthTests: XCTestCase {

    func test_dumpReportsTextLength_evenWhenNumberOfGlyphsIsZero_TSK1332() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tv.string = "hello world"  // 11 characters

        let node = DiagnosticDump.describeView(tv, depth: 0, includeRecursive: false)
        let payload = node["nsTextView"] as? [String: Any]
        XCTAssertNotNil(payload, "the dump must describe an NSTextView as an nsTextView node")
        XCTAssertEqual(payload?["textLength"] as? Int, 11,
            "the dump must report textStorage.length (TK2-safe) — the metric UATs use so a populated "
            + "TextKit-2 view isn't false-flagged as blank (numberOfGlyphs can read 0 unlaid-out)")
    }
}
