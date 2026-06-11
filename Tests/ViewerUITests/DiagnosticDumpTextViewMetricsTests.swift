import XCTest
@testable import ViewerUI

/// TSK-172 — DiagnosticDump must report the O(1) UTF-16 length
/// (`(tv.string as NSString).length`), never `tv.string.count`: the
/// latter forces a full grapheme walk over the entire backing store on
/// EVERY dump (per-step/SIGUSR1), which is exactly the audited cost.
///
/// The pin exploits the semantic difference: for an emoji-laden string
/// the UTF-16 unit count differs from the grapheme count, so a revert
/// to `tv.string.count` flips the reported number and goes red. Pure
/// NSTextView — no window, no WKWebView, host-safe (unlike the #192-
/// gated DiagnosticDumpTests, which hosts full ContentViews).
@MainActor
final class DiagnosticDumpTextViewMetricsTests: XCTestCase {

    func test_stringLength_isUTF16Units_notGraphemeCount() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        // "a👍" = 2 graphemes but 3 UTF-16 units (👍 is a surrogate pair).
        let doc = String(repeating: "a👍", count: 50)
        tv.string = doc
        let utf16Units = (doc as NSString).length      // 150
        let graphemes = doc.count                      // 100
        XCTAssertNotEqual(utf16Units, graphemes, "fixture must discriminate")

        let dump = DiagnosticDump.describeView(tv, depth: 0, includeRecursive: false)
        let info = dump["nsTextView"] as? [String: Any]
        XCTAssertNotNil(info, "NSTextView must produce an nsTextView dump entry")
        XCTAssertEqual(info?["string_length"] as? Int, utf16Units,
            "string_length must be the O(1) NSString UTF-16 length — a "
            + "grapheme count here means tv.string.count is back (TSK-172)")
    }

    /// The bounded head must stay bounded — the other half of the same
    /// audit finding (no full-document copies into the dump).
    func test_stringHead_isBoundedTo120() {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        tv.string = String(repeating: "x", count: 10_000)
        let dump = DiagnosticDump.describeView(tv, depth: 0, includeRecursive: false)
        let head = (dump["nsTextView"] as? [String: Any])?["string_head"] as? String
        XCTAssertEqual(head?.count, 120, "string_head must clamp to 120 chars")
    }
}
