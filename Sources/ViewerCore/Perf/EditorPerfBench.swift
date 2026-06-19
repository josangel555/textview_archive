// Repeatable CM6 editor perf-benchmark harness (TSK-791).
//
// WHY: the owner wants a *quantified*, commit-comparable measurement of the
// editor's edit-apply latency AND of the FFI byte traffic per edit, to inform
// the TSK-543 redesign and the 890/891 traces. Today every incremental edit
// re-serialises the WHOLE document into the `cm_apply` request frame (see
// `mdvCoreApplyCMEdits` in CoreClient.swift: the frame is
// `{base:<full doc>, edits:[…]}`). So a one-character keystroke in a 1 MB file
// ships ~1 MB across the FFI. TSK-543's whole point is to collapse that to the
// edit delta; this harness makes "the win" a NUMBER the bench prints, not a
// hand-wave — `ffiBytesPerEdit` must move when 543 lands.
//
// WHAT IT MEASURES (per workload, per op):
//   - wall-clock of the model edit-apply (the pure Swift reducer
//     `CMEditApplier.apply`, the deterministic UI-free kernel both the Swift
//     and Rust paths agree on — host-stable, no WKWebView, no Rust lib needed).
//   - FFI request-frame bytes for that same edit, computed analytically from
//     the EXACT MessagePack wire format `cm_apply` uses (4-byte LE length
//     prefix + `{base, edits}` map). This is what crosses the process / (future)
//     network boundary on every edit — the cost 543 attacks.
//
// WORKLOADS (scripted, deterministic — same inputs every run):
//   - `.typing`      — N single-character insertions at the caret (the hot path).
//   - `.dragSelect`  — a selection range that GROWS over N steps, then one
//                      replace over the whole expanded range (drag-to-select
//                      then overtype / delete).
//   - `.pageUp`      — a viewport jump: an edit far from the caret (top of a
//                      large doc) — models editing after a page-up scroll, where
//                      the edit offset is nowhere near the previous one.
//
// OUTPUT: a stable, machine-diffable report — JSON (structured, for tooling)
// and CSV (one row per workload, for spreadsheets / commit-over-commit diff).
// The schema is versioned (`reportSchemaVersion`) so a consumer can detect a
// shape change. The on-screen END-TO-END latency (keypress → glyph) is the
// VM/xctrace tail (PerfSignpost `interact` lane) — this harness owns the MODEL
// half, which is host-measurable and the half 543 changes.
//
// Pure ViewerCore: Foundation only, no AppKit/WebKit. Host-testable.

import Foundation

public enum EditorPerfBench {

    // MARK: - Report schema

    /// Bump when the report shape changes so downstream tooling (or a future
    /// commit-over-commit differ) can detect an incompatible format.
    public static let reportSchemaVersion = 1

    /// The scripted workloads the harness runs. `rawValue` is the stable label
    /// that appears in the JSON/CSV report — treat renames as a report-format
    /// change (bump `reportSchemaVersion`).
    public enum Workload: String, CaseIterable, Sendable {
        case typing
        case dragSelect = "drag-select"
        case pageUp = "page-up"
    }

    /// One workload's measured result. All times are milliseconds; all byte
    /// counts are wire bytes of the `cm_apply` request frame.
    public struct WorkloadResult: Equatable, Sendable {
        public let workload: Workload
        /// Number of discrete edit-apply operations the workload performed.
        public let ops: Int
        /// Size of the document (UTF-16 code units) the edits ran against — the
        /// driver of FFI traffic under today's full-resend design.
        public let docLengthUTF16: Int
        /// Total wall-clock across all ops, ms.
        public let totalMs: Double
        /// Per-op wall-clock, ms (`totalMs / ops`).
        public let perOpMs: Double
        /// Best (min) single-op wall-clock across the ops, ms — the
        /// least-load-contaminated estimate of true per-op cost.
        public let bestOpMs: Double
        /// Total FFI request-frame bytes summed across all ops.
        public let ffiBytesTotal: Int
        /// FFI request-frame bytes per edit (`ffiBytesTotal / ops`). THE
        /// number TSK-543 must move: today ≈ docLength (whole doc re-sent
        /// every edit); after 543 it should be ≈ the edit-delta size.
        public let ffiBytesPerEdit: Int

        public init(
            workload: Workload, ops: Int, docLengthUTF16: Int,
            totalMs: Double, perOpMs: Double, bestOpMs: Double,
            ffiBytesTotal: Int, ffiBytesPerEdit: Int
        ) {
            self.workload = workload
            self.ops = ops
            self.docLengthUTF16 = docLengthUTF16
            self.totalMs = totalMs
            self.perOpMs = perOpMs
            self.bestOpMs = bestOpMs
            self.ffiBytesTotal = ffiBytesTotal
            self.ffiBytesPerEdit = ffiBytesPerEdit
        }
    }

    /// The full report: schema version + a row per workload. Self-describing so
    /// a run is comparable to another commit's run without external context.
    public struct Report: Equatable, Sendable {
        public let schemaVersion: Int
        public let results: [WorkloadResult]
        public init(schemaVersion: Int, results: [WorkloadResult]) {
            self.schemaVersion = schemaVersion
            self.results = results
        }
        public func result(for workload: Workload) -> WorkloadResult? {
            results.first { $0.workload == workload }
        }
    }

    // MARK: - FFI byte-traffic model

    /// The MessagePack-encoded length of one UTF-8 string value (header + body),
    /// matching `MsgPackValue.encodeString` in RustCore/MessagePack.swift.
    static func msgpackStringBytes(_ s: String) -> Int {
        let n = s.utf8.count
        let header: Int
        if n < 32 { header = 1 }              // fixstr
        else if n <= 0xff { header = 2 }      // str8
        else if n <= 0xffff { header = 3 }    // str16
        else { header = 5 }                   // str32
        return header + n
    }

    /// MessagePack map/array header size for `n` elements, matching
    /// `MsgPackValue.encodeLength`.
    static func msgpackCollectionHeaderBytes(_ n: Int) -> Int {
        if n < 16 { return 1 }
        else if n <= 0xffff { return 3 }
        else { return 5 }
    }

    /// MessagePack-encoded length of a non-negative `Int` value, matching
    /// `MsgPackValue.encodeInt` (offsets are always >= 0 here; the encoder uses
    /// the signed family for `.int`).
    static func msgpackIntBytes(_ i: Int) -> Int {
        if i >= -32 && i < 0 { return 1 }            // negative fixint
        else if i >= -128 && i <= 127 { return 2 }   // int8 (covers small +ve too)
        else if i >= -32768 && i <= 32767 { return 3 }
        else if i >= -2_147_483_648 && i <= 2_147_483_647 { return 5 }
        else { return 9 }
    }

    /// Exact wire size of the `cm_apply` request FRAME for `(base, edits)` — the
    /// bytes that cross the FFI boundary for one edit-apply call. Mirrors how
    /// `mdvCoreApplyCMEdits` builds `{base, edits:[{from,to,insert}]}` and how
    /// `MsgPackValue.frame()` prefixes a 4-byte LE length. This is the metric
    /// TSK-543 collapses: today it is dominated by `msgpackStringBytes(base)`.
    public static func cmApplyRequestFrameBytes(
        base: String, edits: [CMEdit]
    ) -> Int {
        // Outer map: {"base": <str>, "edits": <array>} — 2 pairs.
        var body = msgpackCollectionHeaderBytes(2)
        body += msgpackStringBytes("base") + msgpackStringBytes(base)
        body += msgpackStringBytes("edits")
        // edits array
        body += msgpackCollectionHeaderBytes(edits.count)
        for e in edits {
            // each edit: {"from": int, "to": int, "insert": str} — 3 pairs.
            body += msgpackCollectionHeaderBytes(3)
            body += msgpackStringBytes("from") + msgpackIntBytes(e.from)
            body += msgpackStringBytes("to") + msgpackIntBytes(e.to)
            body += msgpackStringBytes("insert") + msgpackStringBytes(e.insert)
        }
        // 4-byte LE length prefix (MsgPackFraming.frame).
        return 4 + body
    }

    // MARK: - Workload scripts

    /// Build the scripted edit sequence for `workload` over a document of
    /// `docLines` lines (`lineWidth` chars each). Returns the starting doc plus
    /// an ordered list of single-edit batches — each batch is one edit-apply op.
    ///
    /// Deterministic: identical inputs ⇒ identical script, so two runs (or two
    /// commits) are directly comparable.
    static func script(
        for workload: Workload, docLines: Int, lineWidth: Int, ops: Int
    ) -> (base: String, batches: [[CMEdit]]) {
        let line = String(repeating: "x", count: max(0, lineWidth)) + "\n"
        let base = String(repeating: line, count: max(1, docLines))
        let baseLen = base.utf16.count

        var batches: [[CMEdit]] = []
        batches.reserveCapacity(ops)

        switch workload {
        case .typing:
            // N single-char insertions at a fixed caret near the middle of the
            // doc. Each is an independent batch applied to `base` (the harness
            // measures the per-op apply cost against a stable doc — the FFI
            // resend cost is the same shape regardless of where the caret sits).
            let caret = min(baseLen, max(0, baseLen / 2))
            for _ in 0..<ops {
                batches.append([CMEdit(from: caret, to: caret, insert: "a")])
            }

        case .dragSelect:
            // A selection that grows by one line each step, then a single
            // replace over the expanded range — drag-to-select then overtype.
            // Modeled as: step i replaces [caret, caret + i*lineUnits] with one
            // char. Each step is a larger `to`, exercising bigger ranges.
            let caret = min(baseLen, baseLen / 4)
            let lineUnits = lineWidth + 1 // +1 for the newline
            for i in 0..<ops {
                let to = min(baseLen, caret + i * lineUnits)
                batches.append([CMEdit(from: caret, to: to, insert: "Z")])
            }

        case .pageUp:
            // Editing after a page-up jump: the edit lands at the TOP of the
            // doc, far from any prior caret. Each op inserts at offset 0.
            for _ in 0..<ops {
                batches.append([CMEdit(from: 0, to: 0, insert: "// page-up edit\n")])
            }
        }
        return (base, batches)
    }

    // MARK: - Runner

    /// Run all workloads and produce a report. `ops` is the number of edit-apply
    /// operations each workload performs; `docLines`/`lineWidth` size the
    /// synthetic document. Pure: drives the host-stable Swift reducer
    /// (`CMEditApplier.apply`) for wall-clock, and the analytic wire model for
    /// FFI bytes. Deterministic inputs ⇒ comparable across commits.
    public static func run(
        ops: Int = 200, docLines: Int = 2_000, lineWidth: Int = 60
    ) -> Report {
        var results: [WorkloadResult] = []
        for workload in Workload.allCases {
            results.append(
                runWorkload(workload, ops: ops, docLines: docLines, lineWidth: lineWidth)
            )
        }
        return Report(schemaVersion: reportSchemaVersion, results: results)
    }

    /// Run a single workload. Exposed for targeted benching of one shape.
    public static func runWorkload(
        _ workload: Workload, ops: Int = 200, docLines: Int = 2_000, lineWidth: Int = 60
    ) -> WorkloadResult {
        let n = max(1, ops)
        let (base, batches) = script(
            for: workload, docLines: docLines, lineWidth: lineWidth, ops: n
        )
        let docLen = base.utf16.count

        var totalMs = 0.0
        var bestMs = Double.greatestFiniteMagnitude
        var ffiBytesTotal = 0

        for edits in batches {
            // FFI traffic this op would cost (analytic, exact wire size).
            ffiBytesTotal += cmApplyRequestFrameBytes(base: base, edits: edits)

            // Model edit-apply wall-clock (the deterministic Swift reducer).
            let t0 = Date()
            let applied = CMEditApplier.apply(edits, to: base)
            let dt = Date().timeIntervalSince(t0) * 1000
            totalMs += dt
            bestMs = min(bestMs, dt)
            // Touch the result so the optimizer can't elide the work.
            precondition(applied != nil, "scripted edit must apply cleanly")
        }

        return WorkloadResult(
            workload: workload,
            ops: n,
            docLengthUTF16: docLen,
            totalMs: totalMs,
            perOpMs: totalMs / Double(n),
            bestOpMs: bestMs == .greatestFiniteMagnitude ? 0 : bestMs,
            ffiBytesTotal: ffiBytesTotal,
            ffiBytesPerEdit: ffiBytesTotal / n
        )
    }

    // MARK: - Report serialization

    /// JSON report — structured, schema-versioned. Stable key order via a
    /// hand-built object (Foundation's `JSONSerialization` does not guarantee
    /// key order, so we assemble the string deterministically).
    public static func jsonReport(_ report: Report) -> String {
        func num(_ d: Double) -> String { String(format: "%.4f", d) }
        var rows: [String] = []
        for r in report.results {
            rows.append("""
                {
                  "workload": "\(r.workload.rawValue)",
                  "ops": \(r.ops),
                  "docLengthUTF16": \(r.docLengthUTF16),
                  "totalMs": \(num(r.totalMs)),
                  "perOpMs": \(num(r.perOpMs)),
                  "bestOpMs": \(num(r.bestOpMs)),
                  "ffiBytesTotal": \(r.ffiBytesTotal),
                  "ffiBytesPerEdit": \(r.ffiBytesPerEdit)
                }
                """)
        }
        return """
            {
              "schemaVersion": \(report.schemaVersion),
              "results": [
            \(rows.joined(separator: ",\n"))
              ]
            }
            """
    }

    /// CSV report — one header row + one row per workload. Spreadsheet-friendly
    /// and trivially diffable commit-over-commit.
    public static func csvReport(_ report: Report) -> String {
        func num(_ d: Double) -> String { String(format: "%.4f", d) }
        var lines: [String] = [
            "workload,ops,docLengthUTF16,totalMs,perOpMs,bestOpMs,ffiBytesTotal,ffiBytesPerEdit"
        ]
        for r in report.results {
            lines.append(
                "\(r.workload.rawValue),\(r.ops),\(r.docLengthUTF16),"
                + "\(num(r.totalMs)),\(num(r.perOpMs)),\(num(r.bestOpMs)),"
                + "\(r.ffiBytesTotal),\(r.ffiBytesPerEdit)"
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
