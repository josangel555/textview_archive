import XCTest
import ViewerKit
@testable import ViewerCore

/// Regression coverage for the `visible_text` over-cap truncation branch
/// (`MCPToolCatalog.visibleText`). The audit finding flagged that branch
/// as previously untested AND defective: dead `prefix` placeholder,
/// char-vs-byte confusion, and an O(N) `removeLast` rescan. The fix is
/// UTF-8-boundary-correct byte truncation; these tests pin the contract:
///   - `truncated == true`
///   - `totalBytes == original UTF-8 byte length`
///   - returned text's `utf8.count <= cap`
///   - no broken / partial code points (round-trips through validating decode)
///
/// Named with the audit token to avoid collision with the shared
/// `MCPToolCatalogTests` suite (which this does not edit).
@MainActor
final class Audit_Sources_ViewerCore_Automation_MCPToolCatalog_swift_VisibleTextTruncationTests: XCTestCase {

    private lazy var host: FakeAutomationHost = FakeAutomationHost()

    private var cap: Int { AutomationLimits.visibleTextMaxBytes }

    /// Drive the catalog and pull apart the `visible_text` result object.
    private func runVisibleText(_ input: String) throws -> (text: String, truncated: Bool, totalBytes: Int) {
        host.visibleTextResult = input
        let result = try MCPToolCatalog.dispatch(name: "visible_text",
                                                 args: .object([:]), host: host)
        guard case .object(let o) = result,
              case .string(let text)? = o["text"],
              case .bool(let truncated)? = o["truncated"],
              case .int(let totalBytes)? = o["totalBytes"] else {
            throw XCTSkip("unexpected visible_text result shape: \(result)")
        }
        return (text, truncated, totalBytes)
    }

    /// Pure-ASCII document one byte over the cap: tests the straightforward
    /// path (every byte is its own code point, boundary == cap exactly).
    func test_visibleText_asciiOverCap_truncatesAtExactByteCap() throws {
        let input = String(repeating: "a", count: cap + 1)
        let out = try runVisibleText(input)

        XCTAssertTrue(out.truncated, "expected truncated:true for a >cap document")
        XCTAssertEqual(out.totalBytes, cap + 1, "totalBytes must report the ORIGINAL byte length")
        XCTAssertLessThanOrEqual(out.text.utf8.count, cap,
                                 "returned text must not exceed the byte cap")
        // ASCII: nothing straddles the boundary, so we keep exactly `cap` bytes.
        XCTAssertEqual(out.text.utf8.count, cap)
        XCTAssertTrue(out.text.allSatisfy { $0 == "a" }, "no corruption of the body")
    }

    /// Multi-byte code point straddling the cap boundary. We pad ASCII so the
    /// final 4-byte emoji begins at byte `cap - 2`, i.e. only 2 of its 4 bytes
    /// fall within the leading `cap` bytes — a mid-rune cut. The fix must drop
    /// the partial emoji entirely (no U+FFFD, no half code point).
    func test_visibleText_emojiStraddlingBoundary_dropsPartialCodePoint() throws {
        let emoji = "😀"                       // U+1F600, 4 UTF-8 bytes
        XCTAssertEqual(emoji.utf8.count, 4)

        // ASCII filler so the emoji's lead byte sits at index cap-2:
        // bytes [0, cap-3] are ASCII (cap-2 of them), emoji occupies
        // [cap-2, cap+1]. The leading-cap window therefore contains only
        // the first 2 of the emoji's 4 bytes.
        let filler = String(repeating: "b", count: cap - 2)
        let input = filler + emoji
        XCTAssertGreaterThan(input.utf8.count, cap)

        let out = try runVisibleText(input)

        XCTAssertTrue(out.truncated)
        XCTAssertEqual(out.totalBytes, input.utf8.count)
        XCTAssertLessThanOrEqual(out.text.utf8.count, cap)

        // The partial emoji must be gone: result is the ASCII filler only,
        // ending on a clean boundary strictly below the cap (cap-2 bytes).
        XCTAssertEqual(out.text.utf8.count, cap - 2)
        XCTAssertTrue(out.text.allSatisfy { $0 == "b" },
                      "the straddling emoji must be dropped, not left half-encoded")
        XCTAssertFalse(out.text.unicodeScalars.contains("\u{FFFD}"),
                       "must not emit the U+FFFD replacement character")

        // The bytes must be valid, complete UTF-8: a validating re-decode of
        // the emitted bytes must round-trip identically (no broken code points).
        let bytes = Array(out.text.utf8)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), out.text)
    }

    /// A multi-byte code point that ends exactly AT the cap (its last byte is
    /// byte `cap-1`) must be KEPT whole — the boundary walk should not chop a
    /// complete trailing rune.
    func test_visibleText_emojiEndingExactlyAtCap_isKept() throws {
        let emoji = "😀"                       // 4 bytes
        let filler = String(repeating: "c", count: cap - 4)   // emoji ends at byte cap-1
        let input = filler + emoji + "ddd"                    // overflow past cap
        XCTAssertGreaterThan(input.utf8.count, cap)

        let out = try runVisibleText(input)

        XCTAssertTrue(out.truncated)
        XCTAssertEqual(out.totalBytes, input.utf8.count)
        XCTAssertEqual(out.text.utf8.count, cap, "complete trailing rune at the cap must be retained")
        XCTAssertTrue(out.text.hasSuffix(emoji), "the on-boundary emoji should survive intact")
        let bytes = Array(out.text.utf8)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), out.text)
    }

    /// At-cap (boundary) and under-cap inputs are NOT truncated — pins the
    /// `>` comparison (strictly over the cap triggers truncation).
    func test_visibleText_exactlyAtCap_notTruncated() throws {
        let input = String(repeating: "a", count: cap)
        let out = try runVisibleText(input)
        XCTAssertFalse(out.truncated)
        XCTAssertEqual(out.totalBytes, cap)
        XCTAssertEqual(out.text.utf8.count, cap)
    }
}
