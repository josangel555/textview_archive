import XCTest
@testable import ViewerCore
@testable import RustCore

/// Tests for `EditorPerfBench` — the repeatable CM6 editor perf harness
/// (TSK-791). The harness itself runs HOST (it exercises the bridge/FFI MODEL
/// path — the Swift reducer + the analytic wire-traffic model — not pixels);
/// the on-screen latency capture is the VM/xctrace tail.
///
/// The load-bearing assertions:
///   - the report carries ONE row per scripted workload (typing / drag-select /
///     page-up);
///   - the `ffiBytesPerEdit` metric is CAPTURED and reflects today's full-doc
///     resend (≈ document size) — i.e. THE NUMBER TSK-543 MUST MOVE;
///   - the analytic wire model matches the REAL MessagePack encoder byte-for-
///     byte (so the metric isn't a fiction that drifts from the wire);
///   - the report serializes to stable JSON + CSV.
///
/// Filter target:
///   `swift test --filter ViewerCoreTests.EditorPerfBenchTests`
final class EditorPerfBenchTests: XCTestCase {

    // MARK: - Report shape: one row per workload

    func test_report_hasOneRowPerWorkload() {
        let report = EditorPerfBench.run(ops: 20, docLines: 100, lineWidth: 40)

        XCTAssertEqual(report.schemaVersion, EditorPerfBench.reportSchemaVersion)
        // One row per workload, no dupes, no omissions.
        XCTAssertEqual(report.results.count, EditorPerfBench.Workload.allCases.count)
        let labels = Set(report.results.map { $0.workload })
        XCTAssertEqual(labels, Set(EditorPerfBench.Workload.allCases))

        // Every workload addressable by name.
        for w in EditorPerfBench.Workload.allCases {
            XCTAssertNotNil(report.result(for: w), "missing row for \(w.rawValue)")
        }
    }

    func test_everyWorkload_recordsOpsAndTiming() {
        let ops = 30
        let report = EditorPerfBench.run(ops: ops, docLines: 200, lineWidth: 50)
        for r in report.results {
            XCTAssertEqual(r.ops, ops, "\(r.workload.rawValue) ran the requested op count")
            XCTAssertGreaterThan(r.docLengthUTF16, 0)
            XCTAssertGreaterThanOrEqual(r.totalMs, 0)
            // perOpMs is the mean; bestOpMs the min — min must not exceed mean.
            XCTAssertLessThanOrEqual(r.bestOpMs, r.perOpMs + 1e-6)
            print("[EditorPerfBench] \(r.workload.rawValue): ops=\(r.ops) "
                + "doc=\(r.docLengthUTF16) perOp=\(r.perOpMs)ms best=\(r.bestOpMs)ms "
                + "ffiBytes/edit=\(r.ffiBytesPerEdit)")
        }
    }

    // MARK: - The FFI-bytes-per-edit metric (the number 543 must move)

    func test_ffiBytesPerEdit_isCaptured_andReflectsFullDocResend() {
        // A non-trivial doc so the per-edit FFI cost is dominated by the
        // re-sent document, not the framing overhead.
        let report = EditorPerfBench.run(ops: 50, docLines: 1_000, lineWidth: 80)

        for r in report.results {
            // Captured (not zero/garbage).
            XCTAssertGreaterThan(r.ffiBytesTotal, 0)
            XCTAssertGreaterThan(r.ffiBytesPerEdit, 0)
            XCTAssertEqual(r.ffiBytesPerEdit, r.ffiBytesTotal / r.ops)

            // THE TSK-543 SIGNAL: under today's design every edit re-sends the
            // whole document, so per-edit FFI bytes must be AT LEAST the
            // document's UTF-8 size (≈ docLength for ASCII). When 543 lands
            // (edit-delta wire), this collapses to ~the delta — and THIS
            // assertion is what will flip, proving the win is measurable.
            //
            // docLengthUTF16 is in UTF-16 code units; the body is UTF-8 — for
            // the ASCII synthetic doc they're equal, and the frame adds the
            // map/array/key headers + edit payloads on top, so per-edit bytes
            // strictly exceed docLength.
            XCTAssertGreaterThan(
                r.ffiBytesPerEdit, r.docLengthUTF16,
                "\(r.workload.rawValue): today every edit re-sends the whole "
                + "doc, so FFI bytes/edit must exceed doc size — when TSK-543 "
                + "lands, THIS is the number that drops")
        }
    }

    // MARK: - Analytic wire model matches the REAL MessagePack encoder

    func test_wireModel_matchesRealEncoder_typingEdit() {
        // Build the exact `{base, edits:[{from,to,insert}]}` value the FFI sends
        // (mirrors `mdvCoreApplyCMEdits`) and frame it with the real encoder,
        // then assert our analytic estimate equals the actual wire byte count.
        let base = String(repeating: "lorem ipsum dolor\n", count: 300)
        let edit = CMEdit(from: base.utf16.count / 2, to: base.utf16.count / 2, insert: "a")

        let real = realCMApplyFrameByteCount(base: base, edits: [edit])
        let estimate = EditorPerfBench.cmApplyRequestFrameBytes(base: base, edits: [edit])
        XCTAssertEqual(estimate, real,
            "analytic wire model must match the real MessagePack encoder")
    }

    func test_wireModel_matchesRealEncoder_multiEditAndUnicode() {
        // Larger doc → str16/str32 header transitions; a multi-byte UTF-8 insert
        // → exercises the UTF-8 byte count (not UTF-16) in the string sizer; and
        // an offset > 127 → exercises the int8→int16/int32 header transitions.
        let base = String(repeating: "αβγ δεζ — unicode line\n", count: 5_000)
        let edits = [
            CMEdit(from: 0, to: 0, insert: "新しい"),
            CMEdit(from: 1_000, to: 1_010, insert: "réplace"),
            CMEdit(from: 200_000, to: 200_000, insert: "z"),
        ]
        let real = realCMApplyFrameByteCount(base: base, edits: edits)
        let estimate = EditorPerfBench.cmApplyRequestFrameBytes(base: base, edits: edits)
        XCTAssertEqual(estimate, real)
    }

    func test_wireModel_emptyEdits_matchesEncoder() {
        let base = "short"
        let real = realCMApplyFrameByteCount(base: base, edits: [])
        let estimate = EditorPerfBench.cmApplyRequestFrameBytes(base: base, edits: [])
        XCTAssertEqual(estimate, real)
    }

    // MARK: - Workload scripts are deterministic + apply cleanly

    func test_scripts_areDeterministic() {
        for w in EditorPerfBench.Workload.allCases {
            let a = EditorPerfBench.runWorkload(w, ops: 25, docLines: 300, lineWidth: 40)
            let b = EditorPerfBench.runWorkload(w, ops: 25, docLines: 300, lineWidth: 40)
            // Byte traffic + op count are pure functions of the inputs.
            XCTAssertEqual(a.ffiBytesTotal, b.ffiBytesTotal, "\(w.rawValue) FFI bytes stable")
            XCTAssertEqual(a.ffiBytesPerEdit, b.ffiBytesPerEdit)
            XCTAssertEqual(a.ops, b.ops)
            XCTAssertEqual(a.docLengthUTF16, b.docLengthUTF16)
        }
    }

    func test_dragSelect_growsRangeAndStaysInBounds() {
        // The drag-select script must produce ranges that grow but never run off
        // the end of the doc — every batch must apply cleanly (non-nil).
        let (base, batches) = EditorPerfBench.script(
            for: .dragSelect, docLines: 50, lineWidth: 30, ops: 40
        )
        XCTAssertFalse(batches.isEmpty)
        var lastTo = -1
        for batch in batches {
            XCTAssertEqual(batch.count, 1)
            let e = batch[0]
            XCTAssertGreaterThanOrEqual(e.to, e.from)
            XCTAssertLessThanOrEqual(e.to, base.utf16.count)
            XCTAssertGreaterThanOrEqual(e.to, lastTo, "selection range grows monotonically")
            lastTo = e.to
            XCTAssertNotNil(RustCMEditAdapter.apply(batch, to: base),
                "every scripted drag-select edit must apply cleanly")
        }
    }

    func test_pageUp_editsAtDocTop() {
        let (_, batches) = EditorPerfBench.script(
            for: .pageUp, docLines: 100, lineWidth: 40, ops: 10
        )
        for batch in batches {
            XCTAssertEqual(batch[0].from, 0, "page-up edits land at the doc top")
            XCTAssertEqual(batch[0].to, 0)
        }
    }

    // MARK: - Report serialization (stable JSON + CSV)

    func test_csvReport_hasHeaderPlusOneRowPerWorkload() {
        let report = EditorPerfBench.run(ops: 10, docLines: 50, lineWidth: 20)
        let csv = EditorPerfBench.csvReport(report)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
        // header + one row per workload.
        XCTAssertEqual(lines.count, 1 + EditorPerfBench.Workload.allCases.count)
        XCTAssertTrue(lines[0].hasPrefix("workload,ops,docLengthUTF16,"))
        XCTAssertTrue(lines[0].contains("ffiBytesPerEdit"),
            "the 543 metric column is present in the report")
        // Each workload label appears exactly once in a data row.
        for w in EditorPerfBench.Workload.allCases {
            let matches = lines.dropFirst().filter { $0.hasPrefix("\(w.rawValue),") }
            XCTAssertEqual(matches.count, 1, "\(w.rawValue) appears once in CSV")
        }
    }

    func test_jsonReport_isValidAndCarriesMetrics() throws {
        let report = EditorPerfBench.run(ops: 10, docLines: 50, lineWidth: 20)
        let json = EditorPerfBench.jsonReport(report)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["schemaVersion"] as? Int, EditorPerfBench.reportSchemaVersion)
        let results = try XCTUnwrap(obj["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, EditorPerfBench.Workload.allCases.count)

        // Every row must carry the ffiBytesPerEdit metric (the 543 number).
        for row in results {
            XCTAssertNotNil(row["workload"] as? String)
            XCTAssertNotNil(row["ffiBytesPerEdit"] as? Int)
            XCTAssertGreaterThan(try XCTUnwrap(row["ffiBytesPerEdit"] as? Int), 0)
        }
    }

    // MARK: - Helper: real encoder reference

    /// Build the EXACT `cm_apply` request frame the FFI sends (mirrors
    /// `mdvCoreApplyCMEdits`) using the REAL `MsgPackValue` encoder, and return
    /// its byte count. This is the ground truth the analytic model is checked
    /// against. `@testable import RustCore` makes `MsgPackValue` visible.
    private func realCMApplyFrameByteCount(base: String, edits: [CMEdit]) -> Int {
        let editVals: [MsgPackValue] = edits.map { e in
            .map([
                MsgPackPair(.string("from"), .int(Int64(e.from))),
                MsgPackPair(.string("to"), .int(Int64(e.to))),
                MsgPackPair(.string("insert"), .string(e.insert)),
            ])
        }
        let request = MsgPackValue.map([
            MsgPackPair(.string("base"), .string(base)),
            MsgPackPair(.string("edits"), .array(editVals)),
        ])
        return request.frame().count
    }
}
