import CMdvCore
import Foundation

/// TSK-1517/1518 — Swift client for the stateful editor-doc family
/// (`MDV_METHOD_DOC_*` over the thin-waist envelope).
///
/// The document crosses the FFI boundary ONCE at `open`; every subsequent
/// mutation ships only `{docId, edits}` and gets back the changed region —
/// the endgame of the TSK-543 traffic redesign. The core enforces the TSK-589
/// eviction policy (1.5 GB / 200 docs) with the dirty⇒pinned law: an unsaved
/// doc is NEVER evicted core-side.
///
/// `nowMs` is a host-supplied MONOTONIC clock (the core is sans-IO; recency /
/// TTL decisions stay deterministic and testable). Use `CoreDocStore.nowMs()`.
public enum CoreDocStore {

    /// A single CM6-shaped edit (UTF-16 offsets, unclamped — the core
    /// validates and rejects malformed batches atomically).
    public struct Edit: Sendable, Equatable {
        public let from: Int64
        public let to: Int64
        public let insert: String
        public init(from: Int64, to: Int64, insert: String) {
            self.from = from
            self.to = to
            self.insert = insert
        }
    }

    /// Result of a delta apply. `found == false` ⇒ the id is gone (evicted /
    /// closed) — re-open from the bytes the host still holds. `changed == nil`
    /// with `found` ⇒ the batch was REJECTED (atomic no-op) — full-resync.
    public struct DeltaResult: Sendable, Equatable {
        public let found: Bool
        public let changed: Bool
        public let rev: UInt64
        public let lenUTF16: UInt64
        public let dirty: Bool
    }

    /// Whether the linked core ships the doc-store family.
    public static var isAvailable: Bool {
        CoreABI.isCompatible
            && mdvcore_capabilities() & UInt64(MDV_CAP_DOC_STORE) != 0
    }

    /// Monotonic milliseconds for the `nowMs` parameters.
    public static func nowMs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    /// Open a document (the one full-text transfer). Returns the core doc id.
    public static func open(
        text: String, url: String? = nil, language: String? = nil,
        nowMs: UInt64 = nowMs()
    ) throws -> UInt64 {
        let req = MsgPackValue.map([
            MsgPackPair(.string("text"), .string(text)),
            MsgPackPair(.string("url"), url.map { .string($0) } ?? .nilValue),
            MsgPackPair(.string("language"), language.map { .string($0) } ?? .nilValue),
            MsgPackPair(.string("now_ms"), .uint(nowMs)),
        ]).frame()
        let resp = try CoreEnvelope.call(method: UInt16(MDV_METHOD_DOC_OPEN), req: req)
        let map = try decodeMap(resp)
        return try map.require("doc_id").u64Value()
    }

    /// Apply an edit batch to a resident doc.
    public static func applyDelta(
        docId: UInt64, edits: [Edit], nowMs: UInt64 = nowMs()
    ) throws -> DeltaResult {
        let req = MsgPackValue.map([
            MsgPackPair(.string("doc_id"), .uint(docId)),
            MsgPackPair(.string("now_ms"), .uint(nowMs)),
            MsgPackPair(.string("edits"), .array(edits.map { e in
                .map([
                    MsgPackPair(.string("from"), .int(e.from)),
                    MsgPackPair(.string("to"), .int(e.to)),
                    MsgPackPair(.string("insert"), .string(e.insert)),
                ])
            })),
        ]).frame()
        let resp = try CoreEnvelope.call(method: UInt16(MDV_METHOD_DOC_APPLY_DELTA), req: req)
        let map = try decodeMap(resp)
        let changed: Bool = if let c = map["changed"], c != .nilValue { true } else { false }
        return DeltaResult(
            found: try map.require("found").boolValue(),
            changed: changed,
            rev: try map.require("rev").u64Value(),
            lenUTF16: try map.require("len_utf16").u64Value(),
            dirty: try map.require("dirty").boolValue()
        )
    }

    /// Full text of a resident doc (save path). `nil` = unknown/evicted id.
    public static func text(docId: UInt64, nowMs: UInt64 = nowMs()) throws -> String? {
        let resp = try CoreEnvelope.call(
            method: UInt16(MDV_METHOD_DOC_TEXT), req: idFrame(docId, nowMs))
        let map = try decodeMap(resp)
        guard try map.require("found").boolValue() else { return nil }
        guard let t = map["text"], t != .nilValue else { return nil }
        return try t.stringValue()
    }

    /// Windowed lossy read (viewer path). `nil` = unknown/evicted id.
    public static func window(
        docId: UInt64, from: UInt64, len: UInt64, nowMs: UInt64 = nowMs()
    ) throws -> String? {
        let req = MsgPackValue.map([
            MsgPackPair(.string("doc_id"), .uint(docId)),
            MsgPackPair(.string("now_ms"), .uint(nowMs)),
            MsgPackPair(.string("from"), .uint(from)),
            MsgPackPair(.string("len"), .uint(len)),
        ]).frame()
        let resp = try CoreEnvelope.call(method: UInt16(MDV_METHOD_DOC_WINDOW), req: req)
        let map = try decodeMap(resp)
        guard try map.require("found").boolValue() else { return nil }
        guard let t = map["text"], t != .nilValue else { return nil }
        return try t.stringValue()
    }

    /// Baseline reset after the host performed the save IO. Returns the saved
    /// rev, or `nil` for an unknown id.
    public static func markSaved(docId: UInt64, nowMs: UInt64 = nowMs()) throws -> UInt64? {
        let resp = try CoreEnvelope.call(
            method: UInt16(MDV_METHOD_DOC_MARK_SAVED), req: idFrame(docId, nowMs))
        let map = try decodeMap(resp)
        guard try map.require("found").boolValue() else { return nil }
        return try map.require("rev").u64Value()
    }

    /// Host pin/unpin (visible tab / explicit hold). The dirty half of the
    /// effective pin is core-side and independent.
    @discardableResult
    public static func setPinned(
        docId: UInt64, pinned: Bool, nowMs: UInt64 = nowMs()
    ) throws -> Bool {
        let req = MsgPackValue.map([
            MsgPackPair(.string("doc_id"), .uint(docId)),
            MsgPackPair(.string("now_ms"), .uint(nowMs)),
            MsgPackPair(.string("pinned"), .bool(pinned)),
        ]).frame()
        let resp = try CoreEnvelope.call(method: UInt16(MDV_METHOD_DOC_PIN_CLOSE), req: req)
        return try decodeMap(resp).require("found").boolValue()
    }

    /// Close (idempotent).
    public static func close(docId: UInt64, nowMs: UInt64 = nowMs()) throws {
        let req = MsgPackValue.map([
            MsgPackPair(.string("doc_id"), .uint(docId)),
            MsgPackPair(.string("now_ms"), .uint(nowMs)),
            MsgPackPair(.string("pinned"), .nilValue),
        ]).frame()
        _ = try CoreEnvelope.call(method: UInt16(MDV_METHOD_DOC_PIN_CLOSE), req: req)
    }

    // MARK: - Internals

    private static func idFrame(_ docId: UInt64, _ nowMs: UInt64) -> [UInt8] {
        MsgPackValue.map([
            MsgPackPair(.string("doc_id"), .uint(docId)),
            MsgPackPair(.string("now_ms"), .uint(nowMs)),
        ]).frame()
    }

    private static func decodeMap(_ frame: [UInt8]) throws -> [String: MsgPackValue] {
        var reader = MsgPackReader(frame, startingAt: try CsvSession.frameBodyStart(frame))
        return try reader.decode().mapValue()
    }
}

/// Stage-B (TSK-649): one-shot CSV parse with a FORCED delimiter + explicit
/// caps over the envelope (`MDV_METHOD_CSV_PARSE_WITH`) — the clipboard TSV
/// path that must not sniff. Returns the same `Table` shape as the
/// session `table()` read.
public enum CoreCsvParseWith {
    public static func parse(
        _ text: String,
        delimiter: Character,
        maxCellChars: Int? = nil,
        maxCellsPerRow: Int? = nil,
        maxTotalCells: Int? = nil,
        maxInputScalars: Int? = nil
    ) throws -> Table {
        let req = MsgPackValue.map([
            MsgPackPair(.string("text"), .string(text)),
            MsgPackPair(.string("delimiter"), .string(String(delimiter))),
            MsgPackPair(.string("max_cell_chars"),
                        maxCellChars.map { .uint(UInt64($0)) } ?? .nilValue),
            MsgPackPair(.string("max_cells_per_row"),
                        maxCellsPerRow.map { .uint(UInt64($0)) } ?? .nilValue),
            MsgPackPair(.string("max_total_cells"),
                        maxTotalCells.map { .uint(UInt64($0)) } ?? .nilValue),
            MsgPackPair(.string("max_input_scalars"),
                        maxInputScalars.map { .uint(UInt64($0)) } ?? .nilValue),
        ]).frame()
        let resp = try CoreEnvelope.call(method: UInt16(MDV_METHOD_CSV_PARSE_WITH), req: req)
        var reader = MsgPackReader(resp, startingAt: try CsvSession.frameBodyStart(resp))
        let map = try reader.decode().mapValue()
        return Table(
            delimiter: try map.require("delimiter").stringValue(),
            header: try map.require("header").stringArray(),
            rows: try map.require("rows").stringMatrix(),
            truncated: (try? map.require("truncated").boolValue()) ?? false)
    }
}
