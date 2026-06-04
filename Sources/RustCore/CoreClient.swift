import CMdvCore
import Foundation

/// `RustCore` — the Swift bridge over the MarkdownViewer Rust core's
/// `extern "C"` boundary (adapted from the validated PoC's `PocCore`).
///
/// This module is the *in-process transport tier* (direct FFI into the linked
/// `libmdvcore_ffi.a`). It exposes a throwing Swift API; ARC drives the opaque
/// Rust handle's lifetime (`deinit` frees it exactly once). Structured results
/// cross as length-prefixed MessagePack frames decoded by the hand-rolled
/// `MsgPackReader`, so there is zero Swift-side serialization dependency.
///
/// Scope today: the CSV beachhead (Phase A/B of the migration plan) — parse a
/// CSV into a `Table`, and a stateful `CsvSession` with level-triggered
/// filtered `Snapshot`s. The host routes through this only when the Rust-CSV
/// feature flag is ON; the default-OFF path keeps the existing Swift
/// `CSVParser` (see `RustCSVGate` / `RustCSVAdapter` in ViewerCore).

/// Errors thrown by the Rust-core bridge. Maps the C `MdvStatus` enum to a
/// Swift `throws`, plus the Swift-side wire-decode failures. No error is
/// silently swallowed — every non-`Ok` status surfaces here.
public enum CoreError: Error, Equatable {
    case nullArg
    case badUTF8
    /// Single-writer contract violated: another call held the handle lock.
    case busy
    case wireError
    /// A Rust panic was caught at the FFI boundary. The session's state may be
    /// suspect; the wrapper dead-flags the handle so no further call touches it.
    case panic
    case internalError
    /// Unknown / future status code (forward-compat default arm).
    case unknown(UInt32)
    /// The MessagePack frame returned by the core failed to decode.
    case decode(String)
    /// The session handle was invalidated by a prior caught panic; the caller
    /// must drop and recreate the session rather than reuse suspect state.
    case handleDead

    init(status: MdvStatus) {
        switch status {
        case MDV_STATUS_NULL_ARG: self = .nullArg
        case MDV_STATUS_BAD_UTF8: self = .badUTF8
        case MDV_STATUS_BUSY: self = .busy
        case MDV_STATUS_WIRE_ERROR: self = .wireError
        case MDV_STATUS_PANIC: self = .panic
        case MDV_STATUS_INTERNAL: self = .internalError
        default: self = .unknown(status.rawValue)
        }
    }
}

/// The parsed CSV table (Stage 1 result). Mirrors the Rust `wire::Table`.
public struct Table: Equatable, Sendable {
    public let delimiter: String
    public let header: [String]
    public let rows: [[String]]
    public let truncated: Bool

    public init(delimiter: String, header: [String], rows: [[String]], truncated: Bool) {
        self.delimiter = delimiter
        self.header = header
        self.rows = rows
        self.truncated = truncated
    }
}

/// A level-triggered snapshot of the session's visible rows (Stage 2). Mirrors
/// the Rust `wire::Snapshot`.
public struct Snapshot: Equatable, Sendable {
    public let header: [String]
    public let indices: [UInt32]
    public let rows: [[String]]
    public let totalRows: UInt32
    public let query: String
    public let version: UInt64
    public let truncated: Bool
}

/// Filter scope for `setFilter`.
public enum FilterScope: Sendable {
    case all
    case column(Int)

    var rawValue: Int64 {
        switch self {
        case .all: return -1
        case .column(let c): return Int64(c)
        }
    }
}

/// A CSV session owned by the Rust core, fronted by a Swift class so ARC drives
/// the handle's lifetime: `deinit` calls `mdvcore_session_free` EXACTLY once,
/// which is the mitigation for the use-after-free / double-free hazard (ARC
/// doesn't know about Rust ownership otherwise). After a caught panic the
/// handle is dead-flagged and further calls throw `.handleDead` rather than
/// touching suspect state. (This closes the PoC's noted `check()` gap, where
/// the docstring claimed dead-flagging that the code did not actually do.)
public final class CsvSession {
    private var handle: OpaquePointer?
    /// Set true after a caught `.panic`. The pointer is retained for `deinit`
    /// to free, but no new call is allowed to touch the suspect state.
    private var dead = false

    /// Open a session by parsing `bytes` as UTF-8 CSV.
    public init(bytes: [UInt8]) throws {
        var raw: OpaquePointer?
        let status = bytes.withUnsafeBufferPointer { buf in
            mdvcore_session_open(buf.baseAddress, UInt(buf.count), &raw)
        }
        guard status == MDV_STATUS_OK, let raw else {
            throw CoreError(status: status)
        }
        self.handle = raw
    }

    /// Convenience: open from a Swift `String` (UTF-8 encoded).
    public convenience init(csv: String) throws {
        try self.init(bytes: [UInt8](csv.utf8))
    }

    deinit {
        if let handle {
            mdvcore_session_free(handle)
        }
    }

    /// The parsed table (Stage 1).
    public func table() throws -> Table {
        let frame = try callBuf(mdvcore_session_table)
        return try Self.decodeTable(frame)
    }

    /// Set the active filter (Stage 2 command).
    public func setFilter(_ query: String, scope: FilterScope = .all) throws {
        let h = try liveHandle()
        let bytes = [UInt8](query.utf8)
        let status = bytes.withUnsafeBufferPointer { buf in
            mdvcore_session_set_filter(h, buf.baseAddress, UInt(buf.count), scope.rawValue)
        }
        try check(status)
    }

    /// The level-triggered visible-rows snapshot (Stage 2).
    public func snapshot() throws -> Snapshot {
        let frame = try callBuf(mdvcore_session_snapshot)
        return try Self.decodeSnapshot(frame)
    }

    // MARK: - Internals

    private func liveHandle() throws -> OpaquePointer {
        if dead { throw CoreError.handleDead }
        guard let handle else { throw CoreError.internalError }
        return handle
    }

    private func check(_ status: MdvStatus) throws {
        if status == MDV_STATUS_OK { return }
        if status == MDV_STATUS_PANIC {
            // The core's state may be half-mutated. Dead-flag the handle so no
            // further call touches suspect state; the free still runs in deinit.
            dead = true
        }
        throw CoreError(status: status)
    }

    /// Run an out-buf C call, copy the framed bytes out, and free the MdvBuf.
    private func callBuf(
        _ fn: (OpaquePointer?, UnsafeMutablePointer<MdvBuf>?) -> MdvStatus
    ) throws -> [UInt8] {
        let h = try liveHandle()
        var buf = MdvBuf(data: nil, len: 0, cap: 0)
        let status = fn(h, &buf)
        defer { mdvcore_buf_free(&buf) }
        try check(status)
        guard let data = buf.data, buf.len > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buf.len)))
    }

    // MARK: - Frame + wire decoding

    /// Strip the 4-byte LE length prefix and validate it against the body.
    static func unframe(_ frame: [UInt8]) throws -> [UInt8] {
        guard frame.count >= 4 else {
            throw CoreError.decode("frame shorter than length prefix")
        }
        let declared =
            UInt32(frame[0]) | (UInt32(frame[1]) << 8)
            | (UInt32(frame[2]) << 16) | (UInt32(frame[3]) << 24)
        let body = Array(frame[4...])
        guard Int(declared) == body.count else {
            throw CoreError.decode("frame length \(declared) != body \(body.count)")
        }
        return body
    }

    static func decodeTable(_ frame: [UInt8]) throws -> Table {
        if frame.isEmpty {
            return Table(delimiter: "", header: [], rows: [], truncated: false)
        }
        let body = try unframe(frame)
        var reader = MsgPackReader(body)
        do {
            let map = try reader.decode().mapValue()
            return Table(
                delimiter: try map.require("delimiter").stringValue(),
                header: try map.require("header").stringArray(),
                rows: try map.require("rows").stringMatrix(),
                truncated: try map.require("truncated").boolValue()
            )
        } catch let e as MsgPackError {
            throw CoreError.decode("\(e)")
        }
    }

    static func decodeSnapshot(_ frame: [UInt8]) throws -> Snapshot {
        let body = try unframe(frame)
        var reader = MsgPackReader(body)
        do {
            let map = try reader.decode().mapValue()
            return Snapshot(
                header: try map.require("header").stringArray(),
                indices: try map.require("indices").u32Array(),
                rows: try map.require("rows").stringMatrix(),
                totalRows: UInt32(truncatingIfNeeded: try map.require("total_rows").u64Value()),
                query: try map.require("query").stringValue(),
                version: try map.require("version").u64Value(),
                truncated: try map.require("truncated").boolValue()
            )
        } catch let e as MsgPackError {
            throw CoreError.decode("\(e)")
        }
    }
}

/// Stage 0 smoke: the trivial `add` over the FFI. Kept as a liveness probe.
public func mdvCoreAdd(_ a: Int32, _ b: Int32) -> Int32 {
    mdvcore_add(a, b)
}

/// Test hook: force a panic in the core and observe it mapped to an error.
public func mdvCoreForcePanic() -> CoreError {
    CoreError(status: mdvcore_force_panic())
}

/// Apply a CodeMirror edit batch through the Rust core (migration slice #2 —
/// the first STATELESS call: no handle, a MessagePack request frame in, a
/// response frame out). Returns the applied text, or `nil` when the core
/// **rejected** the batch (out-of-bounds / overlap / ill-formed UTF-16) — the
/// caller's cue to full-resync, exactly matching the Swift `CMEditApplier`
/// contract. Throws `CoreError` only on a bridge FAULT (null/wire/panic) so the
/// adapter can fall back to the Swift path; a rejected batch is `nil`, not a throw.
public func mdvCoreApplyCMEdits(
    base: String,
    edits: [(from: Int, to: Int, insert: String)]
) throws -> String? {
    // Build the request frame {base, edits:[{from,to,insert}]} via the
    // hand-rolled Swift→Rust MessagePack encoder (named maps → rmp-serde structs).
    let editVals: [MsgPackValue] = edits.map { e in
        .map([
            (.string("from"), .int(Int64(e.from))),
            (.string("to"), .int(Int64(e.to))),
            (.string("insert"), .string(e.insert)),
        ])
    }
    let request = MsgPackValue.map([
        (.string("base"), .string(base)),
        (.string("edits"), .array(editVals)),
    ])
    let reqBytes = request.frame()

    var buf = MdvBuf(data: nil, len: 0, cap: 0)
    let status = reqBytes.withUnsafeBufferPointer { p in
        mdvcore_cm_apply(p.baseAddress, UInt(p.count), &buf)
    }
    defer { mdvcore_buf_free(&buf) }
    guard status == MDV_STATUS_OK else { throw CoreError(status: status) }
    guard let data = buf.data, buf.len > 0 else {
        throw CoreError.decode("empty cm_apply response frame")
    }
    let frame = Array(UnsafeBufferPointer(start: data, count: Int(buf.len)))
    let body = try CsvSession.unframe(frame)
    var reader = MsgPackReader(body)
    do {
        let map = try reader.decode().mapValue()
        guard let v = map["text"] else { throw CoreError.decode("missing 'text'") }
        if case .nilValue = v { return nil }   // rejected batch
        return try v.stringValue()
    } catch let e as MsgPackError {
        throw CoreError.decode("\(e)")
    }
}

// MARK: - Unified-diff parsing (migration slice #3)

/// One file's parsed diff. Mirrors the Rust `diff::File` wire type; ViewerCore's
/// `RustDiffAdapter` maps it to the `UnifiedDiff.File` model the diff viewer uses
/// (RustCore can't depend on ViewerCore, so the bridge returns its own values).
public struct DiffFile: Equatable, Sendable {
    public let oldPath: String
    public let newPath: String
    public let isNew: Bool
    public let isDeleted: Bool
    public let isBinary: Bool
    public let isRename: Bool
    public let hunks: [DiffHunk]
}

/// One hunk of a parsed diff. Mirrors the Rust `diff::Hunk`.
public struct DiffHunk: Equatable, Sendable {
    public let oldStart: Int
    public let oldCount: Int
    public let newStart: Int
    public let newCount: Int
    public let header: String
    public let lines: [DiffLine]
}

/// One line of a parsed diff. Mirrors the Rust `diff::Line`.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case context, added, removed
        /// The Rust `LineKind::NoNewline` serializes lowercased-without-separator.
        case noNewline = "nonewline"
    }
    public let kind: Kind
    public let oldLineNo: Int?
    public let newLineNo: Int?
    public let content: String
}

/// Parse a unified diff through the Rust core (migration slice #3 — STATELESS,
/// like `mdvCoreApplyCMEdits`: a `{text}` request frame in, a `{files:[…]}`
/// response frame out). Throws `CoreError` only on a bridge FAULT (null/wire/
/// panic) so the adapter can fall back to the Swift `DiffParser`. A diff that
/// parses to zero files is `[]`, not a throw.
public func mdvCoreParseDiff(text: String) throws -> [DiffFile] {
    let request = MsgPackValue.map([(.string("text"), .string(text))])
    let reqBytes = request.frame()

    var buf = MdvBuf(data: nil, len: 0, cap: 0)
    let status = reqBytes.withUnsafeBufferPointer { p in
        mdvcore_diff_parse(p.baseAddress, UInt(p.count), &buf)
    }
    defer { mdvcore_buf_free(&buf) }
    guard status == MDV_STATUS_OK else { throw CoreError(status: status) }
    guard let data = buf.data, buf.len > 0 else {
        throw CoreError.decode("empty diff_parse response frame")
    }
    let frame = Array(UnsafeBufferPointer(start: data, count: Int(buf.len)))
    let body = try CsvSession.unframe(frame)
    var reader = MsgPackReader(body)
    do {
        let map = try reader.decode().mapValue()
        guard let filesVal = map["files"] else { throw CoreError.decode("missing 'files'") }
        return try filesVal.arrayValue().map(decodeDiffFile)
    } catch let e as MsgPackError {
        throw CoreError.decode("\(e)")
    }
}

private func decodeDiffFile(_ v: MsgPackValue) throws -> DiffFile {
    let m = try v.mapValue()
    return DiffFile(
        oldPath: try m.require("old_path").stringValue(),
        newPath: try m.require("new_path").stringValue(),
        isNew: try m.require("is_new").boolValue(),
        isDeleted: try m.require("is_deleted").boolValue(),
        isBinary: try m.require("is_binary").boolValue(),
        isRename: try m.require("is_rename").boolValue(),
        hunks: try m.require("hunks").arrayValue().map(decodeDiffHunk)
    )
}

private func decodeDiffHunk(_ v: MsgPackValue) throws -> DiffHunk {
    let m = try v.mapValue()
    return DiffHunk(
        oldStart: Int(try m.require("old_start").u64Value()),
        oldCount: Int(try m.require("old_count").u64Value()),
        newStart: Int(try m.require("new_start").u64Value()),
        newCount: Int(try m.require("new_count").u64Value()),
        header: try m.require("header").stringValue(),
        lines: try m.require("lines").arrayValue().map(decodeDiffLine)
    )
}

private func decodeDiffLine(_ v: MsgPackValue) throws -> DiffLine {
    let m = try v.mapValue()
    let kindStr = try m.require("kind").stringValue()
    guard let kind = DiffLine.Kind(rawValue: kindStr) else {
        throw CoreError.decode("unknown diff line kind '\(kindStr)'")
    }
    return DiffLine(
        kind: kind,
        oldLineNo: try decodeOptInt(m.require("old_line_no")),
        newLineNo: try decodeOptInt(m.require("new_line_no")),
        content: try m.require("content").stringValue()
    )
}

/// A diff coordinate is non-negative (the Rust parser clamps to `0…1e9`), so a
/// present value decodes via `u64Value`; `null` (an added line's old number, or
/// vice-versa) decodes to `nil`.
private func decodeOptInt(_ v: MsgPackValue) throws -> Int? {
    if case .nilValue = v { return nil }
    return Int(try v.u64Value())
}

// MARK: - HEX dump rendering (migration slice #4)

/// Render a HEX dump through the Rust core (migration slice #4 — STATELESS:
/// raw bytes in via a pointer, the rendered dump out as **raw UTF-8** rather
/// than a MessagePack frame, because a 4 MB file renders to ~18 MB of text and
/// double-encoding/decoding it would be pure waste). Throws `CoreError` only on
/// a bridge FAULT (null/panic) so the adapter can fall back to the Swift
/// `HexDumpBuilder`. An empty dump is `""`, not a throw.
public func mdvCoreHexRender(
    bytes: Data,
    width: Int,
    totalByteCount: Int,
    isTruncated: Bool
) throws -> String {
    var buf = MdvBuf(data: nil, len: 0, cap: 0)
    let status = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> MdvStatus in
        // baseAddress is nil for an empty buffer; the FFI tolerates (null, 0).
        let base = raw.bindMemory(to: UInt8.self).baseAddress
        return mdvcore_hex_render(
            base,
            UInt(bytes.count),
            UInt32(truncatingIfNeeded: width),
            UInt64(truncatingIfNeeded: totalByteCount),
            isTruncated,
            &buf)
    }
    defer { mdvcore_buf_free(&buf) }
    guard status == MDV_STATUS_OK else { throw CoreError(status: status) }
    guard let data = buf.data, buf.len > 0 else {
        return ""   // empty file, non-truncated → empty dump (valid)
    }
    return String(decoding: UnsafeBufferPointer(start: data, count: Int(buf.len)),
                  as: UTF8.self)
}

// MARK: - HEX search (migration slice #5)

/// Query interpretation for `mdvCoreHexSearch` (mirrors the Rust
/// `hex::HexSearchMode`; raw values match the FFI `mode` arg).
public enum HexSearchKind: UInt32, Sendable {
    case hex = 0
    case ascii = 1
}

/// Search `data` for `query` through the Rust core (migration slice #5 —
/// STATELESS: data + query in by raw pointer, the non-overlapping match offsets
/// out as a `{offsets:[u32]}` frame). Throws `CoreError` only on a bridge FAULT
/// so the adapter can fall back to the Swift `HexSearchEngine`. An invalid or
/// empty query yields `[]` (not a throw) — matching the Swift contract.
public func mdvCoreHexSearch(data: Data, query: String, mode: HexSearchKind) throws -> [Int] {
    let qbytes = [UInt8](query.utf8)
    var buf = MdvBuf(data: nil, len: 0, cap: 0)
    let status = data.withUnsafeBytes { (rawData: UnsafeRawBufferPointer) -> MdvStatus in
        qbytes.withUnsafeBufferPointer { qp in
            mdvcore_hex_search(
                rawData.bindMemory(to: UInt8.self).baseAddress,
                UInt(data.count),
                qp.baseAddress,
                UInt(qp.count),
                mode.rawValue,
                &buf)
        }
    }
    defer { mdvcore_buf_free(&buf) }
    guard status == MDV_STATUS_OK else { throw CoreError(status: status) }
    guard let bytes = buf.data, buf.len > 0 else { return [] }
    let frame = Array(UnsafeBufferPointer(start: bytes, count: Int(buf.len)))
    let body = try CsvSession.unframe(frame)
    var reader = MsgPackReader(body)
    do {
        let map = try reader.decode().mapValue()
        guard let v = map["offsets"] else { throw CoreError.decode("missing 'offsets'") }
        return try v.u32Array().map(Int.init)
    } catch let e as MsgPackError {
        throw CoreError.decode("\(e)")
    }
}

// MARK: - Indent detection (migration slice #7)

/// Detect indentation style through the Rust core (migration slice #7 —
/// STATELESS: text in by raw pointer, the tiny result string out as raw UTF-8).
/// Throws `CoreError` only on a bridge FAULT so the adapter can fall back to the
/// Swift `IndentDetector`.
public func mdvCoreIndentDetect(text: String, sampleLines: Int = 50) throws -> String {
    let bytes = [UInt8](text.utf8)
    var buf = MdvBuf(data: nil, len: 0, cap: 0)
    let status = bytes.withUnsafeBufferPointer { p in
        mdvcore_indent_detect(
            p.baseAddress,
            UInt(p.count),
            UInt32(truncatingIfNeeded: sampleLines),
            &buf)
    }
    defer { mdvcore_buf_free(&buf) }
    guard status == MDV_STATUS_OK else { throw CoreError(status: status) }
    guard let data = buf.data, buf.len > 0 else { return "—" }  // unreachable: detect is never empty
    return String(decoding: UnsafeBufferPointer(start: data, count: Int(buf.len)),
                  as: UTF8.self)
}
