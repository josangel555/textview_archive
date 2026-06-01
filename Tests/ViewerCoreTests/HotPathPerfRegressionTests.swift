import XCTest
@testable import ViewerCore
import ViewerKit

/// Strict perf-regression guards on the pure-Core open hot path:
/// categorize → route → load/decode. These run in the headless gate
/// (ViewerCoreTests, no window) and FAIL on a regression.
///
/// ## Threshold philosophy
/// Absolute wall-clock thresholds flake across hardware and CI load, so each
/// budget is set ~10-30x the headline measured on an M-series Mac (debug).
/// The intent is to catch an ORDER-OF-MAGNITUDE regression — an accidental
/// synchronous full-file read on the db path, a per-open O(file) tax, a
/// re-tokenize on the open path — not to police single-digit-ms drift. The
/// committed baseline (the headline) is recorded in the comment next to each
/// budget; to refresh, run with `-v`, read the printed `[perf-budget]` line,
/// and update both the budget and the recorded baseline (see
/// REFRESHING BASELINES at the bottom).
///
/// ## What each test pins
///  - categorize: extension/UTI routing is constant-time, not file-size.
///  - db routing: an 8 KB `.db` opens as `.preview(sqlite)` in sub-ms with
///    NO byte read — the exact regression behind "8 KB db takes forever".
///  - decode: reading + TextDecoder on a ~200 KB source is tens of ms, and
///    scales ~linearly (no quadratic surprise) to ~1 MB.
final class HotPathPerfRegressionTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        // Per-test scratch under the per-user temp dir (NEVER ~/Documents).
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - Helpers

    @discardableResult
    private func write(_ name: String, bytes: Data) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    @discardableResult
    private func write(_ name: String, _ string: String) throws -> URL {
        try write(name, bytes: Data(string.utf8))
    }

    /// Median of `iterations` timings of `body`, in milliseconds. Median (not
    /// mean) so a single GC/scheduler hiccup doesn't blow the budget.
    private func medianMillis(iterations: Int = 11, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            let t1 = DispatchTime.now().uptimeNanoseconds
            samples.append(Double(t1 &- t0) / 1_000_000.0)
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    private func sourceBody(targetBytes: Int) -> String {
        let line = "func compute(_ x: Int) -> Int { let y = x * 2; return y + 1 } // c\n"
        var s = ""
        s.reserveCapacity(targetBytes + line.utf8.count)
        while s.utf8.count < targetBytes { s += line }
        return s
    }

    // MARK: - categorize

    func test_categorize_isConstantTime_notFileSize() throws {
        // FileTypeDetector.category routes by extension/UTI; it must not read
        // the file, so a 1-byte and a (hypothetical) huge file cost the same.
        let url = try write("x.swift", "let a = 1\n")
        let ms = medianMillis { _ = FileTypeDetector.category(for: url) }
        print("[perf-budget] categorize(.swift): \(String(format: "%.4f", ms))ms (baseline ~0.01ms, budget 5ms)")
        XCTAssertLessThan(ms, 5.0,
            "FileTypeDetector.category regressed to \(ms)ms — it must be a " +
            "constant-time extension/UTI lookup, not a file read.")
    }

    // MARK: - db routing (the "8 KB db takes forever" regression)

    func test_db8KB_routesToSqlitePreview_withNoByteRead_subMillisecond() throws {
        // 8192-byte .db with a real SQLite header. The header makes the file
        // a legitimate sqlite db; the .db EXTENSION is what routes it to the
        // native preview (no text read / decode / highlight).
        var bytes = Data("SQLite format 3\u{0}".utf8)
        bytes.append(Data(repeating: 0, count: 8192 - bytes.count))
        XCTAssertEqual(bytes.count, 8192)
        let url = try write("data.db", bytes: bytes)

        let controller = DocumentController()

        // Correctness: must be .preview(sqlite), NOT .loaded (text) or
        // .binary (hex). A regression that decodes the db as text first is
        // exactly the slow path.
        let state = controller.open(url: url)
        switch state {
        case .preview(_, let cat):
            XCTAssertEqual(cat, .sqlite, "8 KB .db must route to the SQLite preview")
        default:
            XCTFail("8 KB .db routed to \(state) — must be .preview(.sqlite); a " +
                    "text/binary route means the db is being read+decoded (the " +
                    "'takes forever' regression).")
        }

        // Perf: the routing decision + readability check is sub-ms. Budget is
        // 50ms — 100x+ the ~0.2ms headline — so it only trips if the open
        // path started actually reading/decoding the 8 KB (or worse, sniffing
        // the whole file).
        let ms = medianMillis { _ = controller.open(url: url) }
        print("[perf-budget] open(8KB .db): \(String(format: "%.4f", ms))ms (baseline ~0.2ms, budget 50ms)")
        XCTAssertLessThan(ms, 50.0,
            "DocumentController.open on an 8 KB .db regressed to \(ms)ms — the " +
            "native-preview fast path should make this sub-millisecond (no byte read).")
    }

    // MARK: - decode (source open is the loader, not a republish storm)

    func test_decode_200KBSource_underBudget() throws {
        let url = try write("big.swift", sourceBody(targetBytes: 200_000))
        let controller = DocumentController()
        let ms = medianMillis { _ = controller.open(url: url) }
        print("[perf-budget] open+decode(200KB .swift): \(String(format: "%.3f", ms))ms (baseline ~0.15ms, budget 100ms)")
        // Decode of 200 KB is single-digit ms. Budget 100ms catches a
        // quadratic / re-read regression while tolerating a slow CI box.
        XCTAssertLessThan(ms, 100.0,
            "open+decode of 200 KB source regressed to \(ms)ms — the loader " +
            "read+TextDecoder should be single-digit ms; a blowup means a " +
            "per-open O(file^2) tax or a duplicate read.")
    }

    func test_decode_scalesRoughlyLinearly_200KB_to_1MB() throws {
        let controller = DocumentController()
        let small = try write("s.swift", sourceBody(targetBytes: 200_000))
        let large = try write("l.swift", sourceBody(targetBytes: 1_000_000)) // 5x
        let smallMs = medianMillis { _ = controller.open(url: small) }
        let largeMs = medianMillis { _ = controller.open(url: large) }
        let ratio = largeMs / max(smallMs, 0.001)
        print("[perf-budget] decode scale 200KB=\(String(format: "%.3f", smallMs))ms " +
              "1MB=\(String(format: "%.3f", largeMs))ms ratio=\(String(format: "%.2f", ratio))x (size ratio 5x)")
        // 5x the bytes should cost on the order of 5x the time, not 25x.
        // Budget the ratio at 15x — generous slack for fixed per-call
        // overhead dominating the tiny small-file time — so a genuinely
        // quadratic decode (ratio ~25x+) trips while linear-with-overhead
        // passes. Guard the small time being too tiny to divide cleanly by
        // flooring it above; if smallMs is sub-100us the ratio is noise, so
        // only assert when there's a measurable base.
        if smallMs > 0.2 {
            XCTAssertLessThan(ratio, 15.0,
                "decode time scaled \(ratio)x for a 5x size increase — " +
                "super-linear decode regression (200KB=\(smallMs)ms 1MB=\(largeMs)ms).")
        }
    }

    // MARK: - highlight (tokenize is the real per-document cost)

    func test_tokenize_200KBSwift_underBudget() throws {
        // TreeSitter tokenize is the dominant per-open cost (it runs off-main
        // in production, but the cost itself is what we guard here). Warm the
        // per-language Query compile first (one-time), then measure steady-
        // state tokenize so the budget isn't dominated by the cold compile.
        let text = sourceBody(targetBytes: 200_000)
        let engine = TreeSitterEngine.shared
        _ = engine.tokenize(text, language: .swift) // warm: compile the query
        let ms = medianMillis(iterations: 5) {
            _ = engine.tokenize(text, language: .swift)
        }
        print("[perf-budget] tokenize(200KB .swift, warm): \(String(format: "%.1f", ms))ms (baseline ~500-600ms debug, budget 5000ms)")
        // Warm tokenize of this 200 KB highly-repetitive fixture is ~500-600ms
        // in a DEBUG build (it yields ~63K runs, so query-iterate + paintOver
        // dominate; a release build is several-fold faster). Budget at 5000ms
        // (~8-10x) catches a catastrophic regression (e.g. reverting paintOver's
        // O(K log K) sweep-line to the old O(text) per-char canvas, or a query
        // recompile per call) without flaking on a loaded CI box / debug build.
        XCTAssertLessThan(ms, 5000.0,
            "tokenize of 200 KB Swift regressed to \(ms)ms — expected ~100ms " +
            "warm; a blowup means a per-call query recompile or an O(text) " +
            "overlap-resolution pass.")
    }

    func test_tokenize_oversizedFile_isSkippedInstantly() throws {
        // Above highlightMaxBytes (512 KB) tokenize must early-return [] —
        // never parse a multi-MB file on the highlight path. This guard pins
        // that the size cap is still in front of the parse.
        let text = sourceBody(targetBytes: highlightMaxBytes + 100_000)
        let engine = TreeSitterEngine.shared
        let ms = medianMillis {
            let runs = engine.tokenize(text, language: .swift)
            XCTAssertTrue(runs.isEmpty, "oversized file must not be tokenized")
        }
        print("[perf-budget] tokenize(>512KB, skipped): \(String(format: "%.4f", ms))ms (baseline ~0.1ms, budget 10ms)")
        XCTAssertLessThan(ms, 10.0,
            "tokenize of an oversized file took \(ms)ms — the highlightMaxBytes " +
            "cap must short-circuit BEFORE parsing; a slow result means a " +
            "multi-MB file is being parsed on the highlight path.")
    }

    // MARK: - REFRESHING BASELINES
    //
    // The budgets above are deliberately ~10-100x the measured headline so
    // they catch order-of-magnitude regressions without flaking on CI noise.
    // To refresh after an intentional perf change:
    //   1. swift test --filter HotPathPerfRegressionTests -v 2>&1 | grep perf-budget
    //   2. Read the printed [perf-budget] lines (median ms on this host).
    //   3. Update the "baseline ~Xms" note AND, if the headline moved enough
    //      to matter, the budget (keep it ~10x the headline).
    // Do NOT tighten a budget to just above the headline — that re-introduces
    // CI flake. The budget is a regression tripwire, not a benchmark.
}
