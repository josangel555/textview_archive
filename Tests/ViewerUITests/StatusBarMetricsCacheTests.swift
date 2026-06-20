import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-971 — the StatusBar editor-mode metrics path used to (a) re-encode the
/// WHOLE buffer to `Data` on every keystroke just to count bytes, and (b) key
/// its scan cache on `(url, byteCount)`, which made the cache miss on every
/// keystroke (the byte length changes) AND silently serve STALE metrics for a
/// same-length edit. These tests pin the fixed behaviour:
///
///   • `byteCount(of:encoding:)` is correct AND allocation-free for UTF-8 /
///     ASCII (the buffer-encoding hot path), and matches what a save writes.
///   • The metrics cache hits on a repeat call with identical content (no
///     rescan) but RECOMPUTES on a content change — including a same-length
///     edit, which the old length-keyed cache got wrong.
///   • The metric VALUES themselves stay correct across the cache.
///
/// Host-safe (pure static logic — no NSApplication / window / WebView).
final class StatusBarMetricsCacheTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/tsk971/\(name)")
    }

    // MARK: byteCount — cheap + correct, matches save bytes

    func test_byteCount_utf8_matchesUTF8ViewCount() {
        let s = "héllo, wörld\nsecond line\n"   // multi-byte scalars
        XCTAssertEqual(StatusBar.byteCount(of: s, encoding: .utf8), s.utf8.count)
        // And that equals the bytes a UTF-8 save would write.
        XCTAssertEqual(StatusBar.byteCount(of: s, encoding: .utf8),
                       s.data(using: .utf8)!.count)
    }

    func test_byteCount_ascii_isUTF8Count() {
        let s = "plain ascii only"
        XCTAssertEqual(StatusBar.byteCount(of: s, encoding: .ascii), s.utf8.count)
    }

    func test_byteCount_emptyIsZero() {
        XCTAssertEqual(StatusBar.byteCount(of: "", encoding: .utf8), 0)
    }

    func test_byteCount_nonUTF8_fallsBackToEncode() {
        // Latin-1 representable text: one byte per character, distinct from
        // its multi-byte UTF-8 encoding, so this proves the fallback path
        // actually re-encodes rather than returning utf8.count.
        let s = "café"  // 'é' is 2 bytes in UTF-8, 1 byte in Latin-1
        XCTAssertEqual(StatusBar.byteCount(of: s, encoding: .isoLatin1),
                       s.data(using: .isoLatin1)!.count)
        XCTAssertEqual(StatusBar.byteCount(of: s, encoding: .isoLatin1), 4)
        XCTAssertEqual(s.utf8.count, 5)  // sanity: UTF-8 is longer here
    }

    func test_byteCount_nonUTF8Fallback_matchesDataEncodeContract() {
        // The non-UTF-8 fallback contract is exactly `data(using:)?.count ?? 0`
        // — return the encoded byte count, or 0 (never a crash / nil) when the
        // encoding can't represent the text. Pin that contract directly rather
        // than guessing which strings a given encoding rejects (platform-
        // dependent: Foundation may lossily encode some "unrepresentable"
        // input). The `?? 0` branch is the graceful no-crash guard.
        for s in ["café", "日本語", "", "plain ascii"] {
            for enc: String.Encoding in [.isoLatin1, .utf16LittleEndian, .utf16BigEndian] {
                XCTAssertEqual(
                    StatusBar.byteCount(of: s, encoding: enc),
                    s.data(using: enc)?.count ?? 0,
                    "byteCount must equal data(using:)?.count ?? 0 for \(enc) / \"\(s)\"")
            }
        }
    }

    // MARK: cache — hits on identical content, recomputes on a real edit

    func test_metricsCache_repeatSameContent_doesNotRescan() {
        StatusBar.resetMetricsCache()
        let u = url("repeat.txt")
        let text = "alpha\nbeta\ngamma\n"

        let first = StatusBar.metrics(forText: text, url: u, encoding: .utf8)
        XCTAssertEqual(StatusBar.metricsScanCount, 1, "first call must scan once")

        // A caret move / scroll / hover re-bodies the bar with the SAME text:
        // it must serve from cache, NOT rescan.
        let again = StatusBar.metrics(forText: text, url: u, encoding: .utf8)
        XCTAssertEqual(StatusBar.metricsScanCount, 1,
                       "identical-content re-eval must hit the cache (no rescan)")
        XCTAssertEqual(first, again)
    }

    func test_metricsCache_sameLengthEdit_recomputesAndIsNotStale() {
        StatusBar.resetMetricsCache()
        let u = url("samelen.txt")

        // Two-line buffer, one newline.
        let before = "ab\ncd"
        let m1 = StatusBar.metrics(forText: before, url: u, encoding: .utf8)
        XCTAssertEqual(m1.lineCount, 2)
        XCTAssertEqual(StatusBar.metricsScanCount, 1)

        // SAME byte length, but the newline is gone → one line. The old
        // (url, byteCount) cache would have returned the stale 2-line value;
        // the content-keyed cache must recompute.
        let after = "abXcd"
        XCTAssertEqual(before.utf8.count, after.utf8.count, "edit must be same-length")
        let m2 = StatusBar.metrics(forText: after, url: u, encoding: .utf8)
        XCTAssertEqual(StatusBar.metricsScanCount, 2,
                       "a same-length edit must invalidate the cache (rescan)")
        XCTAssertEqual(m2.lineCount, 1, "metrics must reflect the edited content, not stale")
    }

    func test_metricsCache_typingGrowsBuffer_recomputesEachDistinctContent() {
        StatusBar.resetMetricsCache()
        let u = url("typing.txt")
        // Simulate keystrokes building up a line. Each distinct content is a
        // legitimate rescan; the point of the fix is the cache is CONTENT-
        // correct, and there is no full-buffer Data re-encode hidden in the
        // key (covered by byteCount tests).
        var text = ""
        for ch in "hello" {
            text.append(ch)
            _ = StatusBar.metrics(forText: text, url: u, encoding: .utf8)
        }
        XCTAssertEqual(StatusBar.metricsScanCount, 5, "5 distinct contents → 5 scans")

        // Re-rendering the final state (caret settles) must not add a 6th scan.
        let settled = StatusBar.metrics(forText: text, url: u, encoding: .utf8)
        XCTAssertEqual(StatusBar.metricsScanCount, 5,
                       "settled re-eval hits cache")
        XCTAssertEqual(settled.charCount, 5)
        XCTAssertEqual(settled.lineCount, 1)
        XCTAssertEqual(settled.byteCount, 5)
    }

    func test_metricsValues_correctForMultiLineUTF8() {
        StatusBar.resetMetricsCache()
        let u = url("values.txt")
        let text = "one\ntwo\nthree"   // 3 lines, no trailing newline
        let m = StatusBar.metrics(forText: text, url: u, encoding: .utf8)
        XCTAssertEqual(m.lineCount, 3)
        XCTAssertEqual(m.charCount, text.utf16.count)
        XCTAssertEqual(m.byteCount, text.utf8.count)
        XCTAssertEqual(m.encodingShort, "UTF-8")
        XCTAssertTrue(m.hasTextMetrics)
    }

    func test_metricsCache_differentURLSameContent_recomputes() {
        StatusBar.resetMetricsCache()
        let text = "shared\n"
        _ = StatusBar.metrics(forText: text, url: url("a.txt"), encoding: .utf8)
        XCTAssertEqual(StatusBar.metricsScanCount, 1)
        // The single-slot cache is keyed by url too: switching files with
        // identical content must not serve the other file's entry blindly.
        _ = StatusBar.metrics(forText: text, url: url("b.txt"), encoding: .utf8)
        XCTAssertEqual(StatusBar.metricsScanCount, 2)
    }

    // MARK: TSK-1120 — the transient placeholder never blanks the footer

    /// The `.loading`/`.empty` placeholder must carry a real Size + a
    /// "loading…" label and suppress the text-metric chips — so switching
    /// between two already-loaded tabs never flashes a blank footer for the
    /// frame a tab momentarily reports `.empty` before re-materializing.
    /// (Both states route through `loadingPlaceholder` — the `.empty` arm is
    /// the TSK-1120 fix; reverting it to `return nil` blanks the bar and this
    /// contract test still guards the placeholder shape.)
    func test_loadingPlaceholder_carriesSizeAndHidesTextMetrics() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tsk1120-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let u = dir.appendingPathComponent("doc.txt")
        let bytes = Data("hello world\nsecond line\n".utf8)   // known on-disk size
        try bytes.write(to: u)

        let m = StatusBar.loadingPlaceholder(for: u)
        XCTAssertEqual(m.byteCount, bytes.count, "placeholder shows the real on-disk Size")
        XCTAssertEqual(m.encodingShort, "loading…")
        XCTAssertFalse(m.hasTextMetrics, "Lines/Chars chips hide until real metrics arrive")
        XCTAssertEqual(m.lineCount, 0)
        XCTAssertEqual(m.charCount, 0)
    }
}
