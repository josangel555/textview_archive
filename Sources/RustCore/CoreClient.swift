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
