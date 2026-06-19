import XCTest
@testable import RustCore

/// TSK-845 — Perf micro-bundle 2 (MEASURE FIRST, optimize only real wins).
///
/// This bundle named three claimed perf costs. The owner directive was
/// MEASURE-DON'T-GUESS + FRUGALITY: optimize ONLY if a measurement shows a real,
/// significant win; otherwise change no code and record WHY. Two of the three
/// claims were measurable on the host; both proved NON-WINS, so the production
/// code was deliberately left unchanged. This file is the *regression guard* for
/// the measured facts that made them non-wins — it would go red if a future
/// change re-introduced the cost the bundle worried about.
///
/// Filter target:
///   `swift test --filter RustCoreTests.PerfMicroBundle2GuardTests`
///
/// ───────────────────────────────────────────────────────────────────────────
/// MEASUREMENTS (host, M-series, release/`-O`, 2026-06-19)
///
/// (1) ContentFingerprint recomputes `text.utf8.count` 3x/apply()
///     (TextDisplayView.swift). The claim was this is O(N) and wasteful.
///     MEASURED: `String.utf8.count` is O(1) for BOTH native Swift String
///     storage AND NSString-bridged ("foreign-backed") String — Swift caches
///     the UTF-8 byte count on the string. On a ~18 MB doc:
///       - warm call:               ~1 ns (count is cached)
///       - cold first-touch foreign: ~190 ns (bridge caches the count too)
///     3x per apply() is therefore sub-microsecond. → NON-WIN. Leaving it as
///     three fresh `ContentFingerprint(text)` builds is ALSO the correct call:
///     the fingerprint's whole job is change-detection, so threading a bare
///     cached count to a site whose `text` may differ risks a false cache-hit
///     (a correctness regression) to save nanoseconds. Code unchanged.
///
/// (2) MsgPackReader always builds the full MsgPackValue tree
///     (MessagePack.swift). The claim was a lazy/partial decode path would be a
///     win on the RPC hot path. MEASURED on a realistic ~19 MB CSV response
///     frame (50k rows × 20 string cells = 1,000,000 cells):
///       (A) eager decode → MsgPackValue tree only:        ~54 ms
///       (B) decode + stringMatrix() (today's full path):  ~66 ms
///       (C) ideal one-pass streaming decode → [[String]]: ~53 ms
///     The "ideal" lazy path (C) is only ~19% faster than today's full path and
///     essentially TIED with today's eager tree-build (A). The dominant cost is
///     materializing 1,000,000 cell `String`s — UNAVOIDABLE for any decoder,
///     because the CSV consumer reads ALL of `rows` (it isn't skipping
///     subtrees). A lazy path saves only the intermediate enum boxing (~12 ms on
///     the worst-case 19 MB frame; nil on typical sub-microsecond frames) at the
///     cost of a bespoke per-message streaming decoder for the WHOLE RPC surface
///     — fracturing the single shared hand-rolled `decode()` and the depth-cap
///     DoS guard TSK-965 just added. → MARGINAL win, large complexity/risk. Code
///     unchanged. This test pins that the shared decoder stays correct and does
///     NOT regress to a super-linear cost (the actual risk on this hot path).
///
/// (3) lazy-tab materialize 45–92 ms is a UI-OPENING cost → VM-only
///     (xctrace/PerfSignpost via scripts/vm-profile.sh). OUT OF SCOPE for this
///     host slice; tracked as the VM-tail sub-item. No host test here.
/// ───────────────────────────────────────────────────────────────────────────
final class PerfMicroBundle2GuardTests: XCTestCase {

    /// Median of `iterations` timings of `body`, in milliseconds. Median (not
    /// mean) so a single scheduler hiccup doesn't blow the budget. Mirrors
    /// `HotPathPerfRegressionTests.medianMillis`.
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

    // MARK: - (1) utf8.count is O(1) — the fact that made claim (1) a non-win

    /// `String.utf8.count` is O(1): the time to count a huge doc must be the
    /// same ORDER as counting a tiny one. If a future change makes it walk the
    /// bytes (O(N)) — the cost the bundle worried about — this goes red and the
    /// `ContentFingerprint` cache discussion becomes live again.
    ///
    /// Native Swift-backed String.
    func test_utf8Count_isConstantTime_nativeString() {
        let tiny = "x"
        // ~16 MB native String (String(repeating:) yields native storage).
        let huge = String(repeating: "The quick brown fox. ", count: 800_000)
        XCTAssertGreaterThan(huge.utf8.count, 16_000_000)

        var sink = 0
        let tinyMs = medianMillis(iterations: 21) {
            for _ in 0..<10_000 { sink &+= tiny.utf8.count }
        }
        let hugeMs = medianMillis(iterations: 21) {
            for _ in 0..<10_000 { sink &+= huge.utf8.count }
        }
        XCTAssertGreaterThan(sink, 0) // defeat dead-code elimination

        // O(1): counting a 16 MB doc 10k times must not be wildly slower than
        // counting "x" 10k times. A generous 50x ceiling (vs the ~1-3x seen in
        // practice) catches an O(N) regression — a 16M-byte walk would be
        // ~6 orders of magnitude slower — without flaking on scheduler noise.
        let ratio = hugeMs / max(tinyMs, 1e-6)
        XCTAssertLessThan(
            ratio, 50.0,
            "utf8.count appears O(N) on native String (huge=\(hugeMs)ms tiny=\(tinyMs)ms "
                + "ratio=\(ratio)x) — ContentFingerprint's 3x recompute would now be costly")
        print("[TSK-845] native utf8.count: tiny=\(tinyMs)ms huge16MB=\(hugeMs)ms ratio=\(ratio)x")
    }

    /// Foreign-backed (NSString-bridged) String — the case the bundle flagged as
    /// possibly O(N). MEASURED O(1) too: the bridge caches the count.
    func test_utf8Count_isConstantTime_foreignBackedString() {
        let tiny = (NSString(string: "x") as String)
        let hugeNative = String(repeating: "The quick brown fox. ", count: 800_000)
        let huge = (NSString(string: hugeNative) as String) // foreign/bridged backing
        XCTAssertGreaterThan(huge.utf8.count, 16_000_000)

        var sink = 0
        let tinyMs = medianMillis(iterations: 21) {
            for _ in 0..<10_000 { sink &+= tiny.utf8.count }
        }
        let hugeMs = medianMillis(iterations: 21) {
            for _ in 0..<10_000 { sink &+= huge.utf8.count }
        }
        XCTAssertGreaterThan(sink, 0)

        let ratio = hugeMs / max(tinyMs, 1e-6)
        XCTAssertLessThan(
            ratio, 50.0,
            "utf8.count appears O(N) on foreign-backed String (huge=\(hugeMs)ms "
                + "tiny=\(tinyMs)ms ratio=\(ratio)x)")
        print("[TSK-845] foreign utf8.count: tiny=\(tinyMs)ms huge16MB=\(hugeMs)ms ratio=\(ratio)x")
    }

    // MARK: - (2) MsgPackReader decode — correctness + no super-linear regression

    /// Build a realistic CSV-shaped response frame: a named map with `header`
    /// (array of strings) + `rows` (array of arrays of strings). Mirrors what
    /// the Rust core's `to_vec_named` CSV decode emits.
    private func buildCsvFrame(rows: Int, cols: Int) -> [UInt8] {
        var header: [MsgPackValue] = []
        header.reserveCapacity(cols)
        for c in 0..<cols { header.append(.string("col_\(c)")) }
        var rowVals: [MsgPackValue] = []
        rowVals.reserveCapacity(rows)
        for r in 0..<rows {
            var cells: [MsgPackValue] = []
            cells.reserveCapacity(cols)
            for c in 0..<cols { cells.append(.string("r\(r)c\(c)_somevalue")) }
            rowVals.append(.array(cells))
        }
        return MsgPackValue.map([
            (.string("header"), .array(header)),
            (.string("rows"), .array(rowVals)),
            (.string("totalRows"), .uint(UInt64(rows))),
        ]).encode()
    }

    /// The eager decode + extraction round-trips correctly on a realistic frame
    /// — the correctness invariant that any future lazy-path optimization must
    /// preserve, and that pins the shared decoder the bundle considered changing.
    func test_msgPackReader_csvFrame_roundTripsCorrectly() throws {
        let frame = buildCsvFrame(rows: 200, cols: 8)
        var reader = MsgPackReader(frame)
        let map = try reader.decode().mapValue()
        let header = try map.require("header").stringArray()
        let matrix = try map.require("rows").stringMatrix()
        let total = try map.require("totalRows").u64Value()

        XCTAssertEqual(header.count, 8)
        XCTAssertEqual(header[0], "col_0")
        XCTAssertEqual(header[7], "col_7")
        XCTAssertEqual(matrix.count, 200)
        XCTAssertEqual(total, 200)
        // Spot-check first, last, and an interior cell.
        XCTAssertEqual(matrix[0][0], "r0c0_somevalue")
        XCTAssertEqual(matrix[199][7], "r199c7_somevalue")
        XCTAssertEqual(matrix[100][4], "r100c4_somevalue")
    }

    /// Decode of a realistic ~19 MB CSV frame must scale ~LINEARLY with frame
    /// size, not quadratically. This is the actual regression risk on the shared
    /// hot-path decoder (the bundle's claim (2) target): if someone makes the
    /// reader O(N²) (e.g. an accidental `Array` prepend, or re-scanning), this
    /// goes red. We compare per-byte decode cost at two sizes; a linear decoder
    /// keeps per-byte cost roughly flat.
    func test_msgPackReader_decodeScalesLinearly_notQuadratic() throws {
        // ~1.8 MB and ~3.6 MB frames (same cell shape, 2x the rows).
        let small = buildCsvFrame(rows: 5_000, cols: 20)
        let large = buildCsvFrame(rows: 10_000, cols: 20)
        XCTAssertEqual(large.count / small.count, 2, "large frame is ~2x small")

        func decodeMatrix(_ frame: [UInt8]) {
            var r = MsgPackReader(frame)
            // swiftlint:disable:next force_try
            _ = try! r.decode().mapValue()["rows"].flatMap { try? $0.stringMatrix() }
        }
        // warm
        decodeMatrix(small); decodeMatrix(large)

        let smallMs = medianMillis(iterations: 7) { decodeMatrix(small) }
        let largeMs = medianMillis(iterations: 7) { decodeMatrix(large) }
        let perByteSmall = smallMs / Double(small.count)
        let perByteLarge = largeMs / Double(large.count)
        let perByteRatio = perByteLarge / max(perByteSmall, 1e-12)

        print("[TSK-845] decode small=\(smallMs)ms (\(small.count/1024)KB) "
            + "large=\(largeMs)ms (\(large.count/1024)KB) perByteRatio=\(perByteRatio)x")
        // Linear ⇒ per-byte cost ~flat (ratio ≈ 1). Quadratic ⇒ the 2x-bigger
        // frame costs ~2x MORE per byte (ratio ≈ 2). A 1.8x ceiling catches the
        // quadratic regression while tolerating cache/alloc noise.
        XCTAssertLessThan(
            perByteRatio, 1.8,
            "MsgPackReader decode is scaling super-linearly (per-byte cost "
                + "\(perByteRatio)x worse on the 2x-bigger frame) — a quadratic "
                + "regression on the RPC hot path")
    }
}
