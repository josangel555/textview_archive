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
    /// The result is real but its encoded frame exceeds the core's wire cap
    /// (16 MiB) — e.g. the table/snapshot of a large CSV. Distinct from
    /// `.wireError` so callers fall back / window instead of diagnosing a
    /// codec bug (audit TSK-548 stopgap; windowed snapshots are the real fix).
    case tooLarge
    /// A Rust panic was caught at the FFI boundary. The session's state may be
    /// suspect; the wrapper dead-flags the handle so no further call touches it.
    case panic
    case internalError
    /// Unknown / future status code (forward-compat default arm).
    case unknown(UInt32)
    /// The MessagePack frame returned by the core failed to decode.
    case decode(String)
    /// A find pattern the linear-time engine cannot compile (invalid syntax
    /// or an ICU-only construct like lookaround). NOT a bridge fault — the
    /// adapter maps it to `FindError.invalidRegex` or falls back to the
    /// Swift engine (TSK-630).
    case invalidPattern(String)
    /// The session handle is invalid: either this wrapper dead-flagged it after
    /// a caught panic, or the CORE reports its lock poisoned
    /// (`MDV_STATUS_HANDLE_DEAD`, TSK-581 — a previous call panicked while
    /// holding it). Both mean the same thing: drop and recreate the session
    /// rather than reuse suspect state.
    case handleDead

    init(status: MdvStatus) {
        switch status {
        case MDV_STATUS_NULL_ARG: self = .nullArg
        case MDV_STATUS_BAD_UTF8: self = .badUTF8
        case MDV_STATUS_BUSY: self = .busy
        case MDV_STATUS_WIRE_ERROR: self = .wireError
        case MDV_STATUS_TOO_LARGE: self = .tooLarge
        case MDV_STATUS_HANDLE_DEAD: self = .handleDead
        case MDV_STATUS_PANIC: self = .panic
        case MDV_STATUS_INTERNAL: self = .internalError
        default: self = .unknown(status.rawValue)
        }
    }
}

/// ABI skew guard (TSK-579, audit R4). The cbindgen header bakes
/// `MDV_WIRE_VERSION` in at COMPILE time; `mdvcore_abi_version()` reports what
/// the LINKED `libmdvcore_ffi.a` was built with at RUN time. They differ when
/// the staticlib and the staged header drift (the VM links a prebuilt .a
/// against rsync'd sources; a stale `rust-core/link/` artifact does the same
/// on the host). Calling across a skewed ABI is undefined behavior, so every
/// bridge entry point asserts compatibility once per process and crashes fast
/// with a rebuild hint instead of corrupting memory.
public enum CoreABI {
    /// The version this module was compiled against (header constant).
    public static let compiled: UInt32 = UInt32(MDV_WIRE_VERSION)
    /// The version the linked staticlib reports. 0 = the FFI guard tripped,
    /// which is never a valid version and always incompatible.
    public static var linked: UInt32 { mdvcore_abi_version() }
    /// Pure comparison — no side effects, safe for tests to probe.
    public static var isCompatible: Bool { linked == compiled }

    private static let checkedOnce: Void = {
        precondition(
            isCompatible,
            "mdvcore ABI skew: linked libmdvcore_ffi.a reports wire version "
            + "\(linked) but this build compiled against \(compiled) — run "
            + "`bash scripts/build-rust-core.sh` and rebuild before calling "
            + "across the FFI"
        )
    }()

    /// Crash-fast skew assert; runs the check exactly once per process.
    public static func assertCompatible() { _ = checkedOnce }

    /// Capability mask of the LINKED library (TSK-634) — feature negotiation
    /// ABOVE the frozen wire version. Gate each feature on its own bit;
    /// UNKNOWN bits must be ignored (a newer library may set them) — that
    /// tolerance is what lets client and core version independently, the
    /// skew a remote `mdv-serve` deployment makes routine.
    public static var capabilities: CoreCapabilities {
        CoreCapabilities(rawValue: mdvcore_capabilities())
    }
}

/// Typed view of the `MDV_CAP_*` bitmap. Raw values MIRROR the header
/// constants and are ABI — assigned once, never renumbered (pinned by
/// `CoreCapabilityTests` against the header AND by the Rust-side twin).
public struct CoreCapabilities: OptionSet, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let csvSession = CoreCapabilities(rawValue: UInt64(MDV_CAP_CSV_SESSION))
    public static let diff       = CoreCapabilities(rawValue: UInt64(MDV_CAP_DIFF))
    public static let hex        = CoreCapabilities(rawValue: UInt64(MDV_CAP_HEX))
    public static let indent     = CoreCapabilities(rawValue: UInt64(MDV_CAP_INDENT))
    public static let cmApply    = CoreCapabilities(rawValue: UInt64(MDV_CAP_CM_APPLY))
    /// Reserved — pre-assigned for the approved ports (TSK-630..633); their
    /// bits stay OFF in the mask until the engine's exports land.
    public static let find       = CoreCapabilities(rawValue: UInt64(MDV_CAP_FIND))
    public static let markdown   = CoreCapabilities(rawValue: UInt64(MDV_CAP_MARKDOWN))
    public static let transcript = CoreCapabilities(rawValue: UInt64(MDV_CAP_TRANSCRIPT))
    public static let fuzzy      = CoreCapabilities(rawValue: UInt64(MDV_CAP_FUZZY))
    /// SERVER-ONLY (TSK-654): set by a remote mdv-serve hello when a root
    /// is served; never present in the in-process library's mask.
    public static let fs         = CoreCapabilities(rawValue: UInt64(MDV_CAP_FS))
    /// SERVER-ONLY (TSK-657): same posture as `.fs`.
    public static let git        = CoreCapabilities(rawValue: UInt64(MDV_CAP_GIT))
    /// SERVER-ONLY (TSK-658): same posture as `.fs`.
    public static let transcriptList = CoreCapabilities(rawValue: UInt64(MDV_CAP_TRANSCRIPT_LIST))
    /// RESERVED (TSK-659): the LSP pipe family.
    public static let lspPipe    = CoreCapabilities(rawValue: UInt64(MDV_CAP_LSP_PIPE))
    /// SERVER-ONLY (TSK-656): same posture as `.fs`.
    public static let search     = CoreCapabilities(rawValue: UInt64(MDV_CAP_SEARCH))
    /// Tree-sitter highlight runs (TSK-660) — an ENGINE bit: present in the
    /// in-process mask AND a remote hello.
    public static let highlight  = CoreCapabilities(rawValue: UInt64(MDV_CAP_HIGHLIGHT))

    /// Everything the CURRENT Swift adapters require of the linked core —
    /// the graceful-degradation floor. `assertCompatible` already crash-fasts
    /// on wire-version skew; capability gating is deliberately SOFT (adapters
    /// fall back to Swift), so this set is for diagnostics, not preconditions.
    public static let requiredByShippingAdapters: CoreCapabilities =
        [.csvSession, .diff, .hex, .indent, .cmApply]
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
        CoreABI.assertCompatible()
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
        if status == MDV_STATUS_PANIC || status == MDV_STATUS_HANDLE_DEAD {
            // The core's state may be half-mutated (panic mid-call) or its lock
            // is poisoned (the core's own tri-state, TSK-581). Dead-flag the
            // handle so no further call touches suspect state; the free still
            // runs in deinit.
            dead = true
        }
        throw CoreError(status: status)
    }

    #if DEBUG
    /// The C `MdvStatus` outcomes a handle-taking session call can yield that the
    /// dead-flag state machine cares about. Test-only mirror so the regression
    /// test never has to import the raw `CMdvCore` C module.
    enum SimulatedSessionOutcome {
        /// Maps to `MDV_STATUS_PANIC`: the core panicked mid-call (fatal — latches
        /// the dead-flag).
        case panic
        /// Maps to `MDV_STATUS_BUSY`: the single-writer lock was contended
        /// (retryable — must NOT latch the dead-flag).
        case busy
        /// Maps to `MDV_STATUS_HANDLE_DEAD`: the core reports its lock
        /// poisoned (TSK-581 tri-state; fatal — latches the dead-flag).
        case coreHandleDead
        /// Maps to `MDV_STATUS_OK`: a clean call (used to probe a dead handle).
        case ok

        fileprivate var status: MdvStatus {
            switch self {
            case .panic: return MDV_STATUS_PANIC
            case .busy: return MDV_STATUS_BUSY
            case .coreHandleDead: return MDV_STATUS_HANDLE_DEAD
            case .ok: return MDV_STATUS_OK
            }
        }
    }

    /// Test-only hook: simulate a handle-taking session call with `outcome`,
    /// driving the REAL `liveHandle()` + `check()` state machine on this live
    /// session (no Rust shim needed — the FFI crate stays untouched). Lets a test
    /// prove the dead-flag contract end-to-end: a `.panic` outcome must throw
    /// `.panic` AND latch `dead`, so a subsequent real call (`table()` /
    /// `snapshot()`) throws `.handleDead`; a `.busy` outcome must throw `.busy`
    /// WITHOUT latching `dead` (contention is retryable, not fatal). This
    /// exercises the same `liveHandle`/`check` path every production session call
    /// flows through, so it is a faithful proxy for a panicking session shim.
    func _simulateSessionCall(_ outcome: SimulatedSessionOutcome) throws {
        _ = try liveHandle()      // throws .handleDead once a prior panic latched
        try check(outcome.status) // maps status → CoreError; latches dead on .panic
    }

    /// Test-only accessor for the dead-flag, so a test can assert the latch
    /// transition directly rather than only inferring it from the next throw.
    var _isDead: Bool { dead }
    #endif

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
/// TSK-634 stage 3: the ONE Swift-side call ritual for every stateless
/// frame export (`ffi_frame_body!` shape: request frame in, response frame
/// out). Owns request framing, the unsafe pointer pass, buf free, status
/// mapping, response copy + unframe — and the once-per-process ABI assert
/// the per-wrapper copies had silently dropped. Returns `nil` for an EMPTY
/// response buffer: callers decide whether that is a decode fault
/// (cm_apply/diff_parse) or a legitimate empty result (hunk marks).
///
/// Stage 3 was deliberately REDESIGNED from "generate Swift stubs post-
/// cbindgen" to this shared helper: stage 2's uniform C signature makes
/// every wrapper a one-liner around it, which captures the same ceremony
/// reduction with zero generator/build machinery and no generated-file
/// drift to police.
func mdvFrameCall(
    // `name` is the per-export observability tag — unused today, reserved as
    // the single emit point for the TSK-636 activity/audit log (one hook
    // instruments every stateless FFI call). Since TSK-652 the transport
    // seam (`CoreTransport.call`) is the equivalent point one level up,
    // covering remote calls too.
    _ name: String,
    _ fn: (UnsafePointer<UInt8>?, UInt, UnsafeMutablePointer<MdvBuf>?) -> MdvStatus,
    body: [UInt8]
) throws -> [UInt8]? {
    CoreABI.assertCompatible()
    let reqBytes = MsgPackFraming.frame(body)
    var buf = MdvBuf(data: nil, len: 0, cap: 0)
    let status = reqBytes.withUnsafeBufferPointer { p in
        fn(p.baseAddress, UInt(p.count), &buf)
    }
    defer { mdvcore_buf_free(&buf) }
    guard status == MDV_STATUS_OK else { throw CoreError(status: status) }
    guard let data = buf.data, buf.len > 0 else { return nil }
    let frame = Array(UnsafeBufferPointer(start: data, count: Int(buf.len)))
    return try CsvSession.unframe(frame)
}

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
    guard let body = try CoreTransportRegistry.current.call("cm_apply", request: request) else {
        throw CoreError.decode("empty cm_apply response frame")
    }
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
    guard let body = try CoreTransportRegistry.current.call("diff_parse", request: request) else {
        throw CoreError.decode("empty diff_parse response frame")
    }
    var reader = MsgPackReader(body)
    do {
        let map = try reader.decode().mapValue()
        guard let filesVal = map["files"] else { throw CoreError.decode("missing 'files'") }
        return try filesVal.arrayValue().map(decodeDiffFile)
    } catch let e as MsgPackError {
        throw CoreError.decode("\(e)")
    }
}

// TSK-563 (wire v2): diff per-element records are POSITIONAL MessagePack
// arrays — the per-line field keys were ~41 bytes/line of pure key text.
// Element order is the wire contract, mirrored by the Rust `FileView`/
// `HunkView`/`LineView` tuples: append-only, never reorder.

private func decodeDiffFile(_ v: MsgPackValue) throws -> DiffFile {
    let a = try positional(v, count: 7, what: "diff file")
    return DiffFile(
        oldPath: try a[0].stringValue(),
        newPath: try a[1].stringValue(),
        isNew: try a[2].boolValue(),
        isDeleted: try a[3].boolValue(),
        isBinary: try a[4].boolValue(),
        isRename: try a[5].boolValue(),
        hunks: try a[6].arrayValue().map(decodeDiffHunk)
    )
}

private func decodeDiffHunk(_ v: MsgPackValue) throws -> DiffHunk {
    let a = try positional(v, count: 6, what: "diff hunk")
    return DiffHunk(
        oldStart: Int(try a[0].u64Value()),
        oldCount: Int(try a[1].u64Value()),
        newStart: Int(try a[2].u64Value()),
        newCount: Int(try a[3].u64Value()),
        header: try a[4].stringValue(),
        lines: try a[5].arrayValue().map(decodeDiffLine)
    )
}

/// Decode a positional element record: an array of exactly `count` values.
/// A count mismatch is a wire-contract violation (e.g. a version-skewed
/// library), surfaced as a decode fault so adapters fall back to Swift.
private func positional(
    _ v: MsgPackValue, count: Int, what: String
) throws -> [MsgPackValue] {
    let a = try v.arrayValue()
    guard a.count == count else {
        throw CoreError.decode("\(what): expected \(count) positional fields, got \(a.count)")
    }
    return a
}

/// Per-working-tree-line diff mark (mirrors the Rust `diff::DiffMark`; raw
/// values match the wire `mark` strings). ViewerCore's `RustDiffAdapter` maps it
/// to its own `DiffMark` (RustCore can't depend on ViewerCore).
public enum DiffHunkMark: String, Sendable {
    case added
    case modified
    case deleted
}

/// Flatten a unified diff to per-line gutter marks through the Rust core
/// (migration slice #3, gutter half — STATELESS, `{text}` frame in,
/// `{marks:[{line,mark}]}` frame out). Throws `CoreError` only on a bridge FAULT
/// so the adapter can fall back to the Swift `DiffHunkParser`.
public func mdvCoreDiffHunkMarks(text: String) throws -> [Int: DiffHunkMark] {
    let request = MsgPackValue.map([(.string("text"), .string(text))])
    guard let body = try CoreTransportRegistry.current.call("diff_hunk_marks", request: request) else { return [:] }   // empty response = no marks, not a fault
    var reader = MsgPackReader(body)
    do {
        let map = try reader.decode().mapValue()
        guard let marksVal = map["marks"] else { throw CoreError.decode("missing 'marks'") }
        var result: [Int: DiffHunkMark] = [:]
        for el in try marksVal.arrayValue() {
            // TSK-563 (wire v2): positional `[line, mark]`.
            let a = try positional(el, count: 2, what: "diff hunk mark")
            let line = Int(try a[0].u64Value())
            let kindStr = try a[1].stringValue()
            guard let mark = DiffHunkMark(rawValue: kindStr) else {
                throw CoreError.decode("unknown diff hunk mark '\(kindStr)'")
            }
            result[line] = mark
        }
        return result
    } catch let e as MsgPackError {
        throw CoreError.decode("\(e)")
    }
}

private func decodeDiffLine(_ v: MsgPackValue) throws -> DiffLine {
    let a = try positional(v, count: 4, what: "diff line")
    let kindStr = try a[0].stringValue()
    guard let kind = DiffLine.Kind(rawValue: kindStr) else {
        throw CoreError.decode("unknown diff line kind '\(kindStr)'")
    }
    return DiffLine(
        kind: kind,
        oldLineNo: try decodeOptInt(a[1]),
        newLineNo: try decodeOptInt(a[2]),
        content: try a[3].stringValue()
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

// MARK: - Fuzzy ranking (migration slice — TSK-633)

/// One ranked fuzzy match from the Rust core. `matchedIndices` are Unicode
/// SCALAR offsets into the candidate (the Rust port walks `char`s; the Swift
/// twin walks grapheme `Character`s) — identical on ASCII, divergent only on
/// grapheme-cluster-heavy strings. A consumer highlighting glyphs must map.
public struct FuzzyRanked: Equatable, Sendable {
    public let index: Int
    public let score: Int
    public let matchedIndices: [Int]
}

/// Rank `candidates` against `query` through the Rust core (STATELESS,
/// `{query, candidates}` frame in, `{matches:[{index,score,indices}]}` frame
/// out — sorted score-descending, stable input-order ties, exactly the Swift
/// `FuzzyMatcher.filterWithMatches` contract). Throws `CoreError` only on a
/// bridge FAULT so an adapter can fall back to the Swift matcher.
public func mdvCoreFuzzyRank(query: String, candidates: [String]) throws -> [FuzzyRanked] {
    let request = MsgPackValue.map([
        (.string("query"), .string(query)),
        (.string("candidates"), .array(candidates.map { .string($0) })),
    ])
    guard let body = try CoreTransportRegistry.current.call("fuzzy_rank", request: request) else {
        throw CoreError.decode("empty fuzzy_rank response frame")
    }
    var reader = MsgPackReader(body)
    do {
        let map = try reader.decode().mapValue()
        guard let matches = map["matches"] else { throw CoreError.decode("missing 'matches'") }
        return try matches.arrayValue().map { el in
            let m = try el.mapValue()
            return FuzzyRanked(
                index: Int(try m.require("index").u64Value()),
                score: Int(try m.require("score").u64Value()),
                matchedIndices: try m.require("indices").u32Array().map(Int.init)
            )
        }
    } catch let e as MsgPackError {
        throw CoreError.decode("\(e)")
    }
}

// MARK: - Whole-document find (migration slice — TSK-630)

/// One find match from the Rust engine: UTF-16 range pieces + 1-based
/// line/column, mirroring the Swift `FindMatch`'s NSRange semantics exactly.
public struct CoreFindMatch: Equatable, Sendable {
    public let location: Int
    public let length: Int
    public let line: Int
    public let column: Int
}

/// Search `text` through the Rust core's linear-time find engine (STATELESS,
/// TSK-630). `kind` is "literal" or "regex". Throws `CoreError.invalidPattern`
/// when the pattern doesn't compile (the adapter's FindError.invalidRegex /
/// Swift-fallback channel) and other `CoreError`s only on a bridge fault.
/// ReDoS is structurally impossible (PikeVM) — no deadline parameter exists.
/// Documented divergence vs ICU: case-insensitivity is ASCII-only; lookaround/
/// backreferences surface as `.invalidPattern`.
public func mdvCoreFindSearch(
    text: String,
    pattern: String,
    kind: String,
    caseSensitive: Bool,
    wholeWord: Bool
) throws -> [CoreFindMatch] {
    let request = MsgPackValue.map([
        (.string("text"), .string(text)),
        (.string("pattern"), .string(pattern)),
        (.string("kind"), .string(kind)),
        (.string("case_sensitive"), .bool(caseSensitive)),
        (.string("whole_word"), .bool(wholeWord)),
    ])
    guard let body = try CoreTransportRegistry.current.call("find_search", request: request) else {
        throw CoreError.decode("empty find_search response frame")
    }
    var reader = MsgPackReader(body)
    do {
        let map = try reader.decode().mapValue()
        if let err = map["error"], case .string(let reason) = err {
            throw CoreError.invalidPattern(reason)
        }
        guard let matches = map["matches"] else { throw CoreError.decode("missing 'matches'") }
        return try matches.arrayValue().map { el in
            let m = try el.mapValue()
            return CoreFindMatch(
                location: Int(try m.require("location").u64Value()),
                length: Int(try m.require("length").u64Value()),
                line: Int(try m.require("line").u64Value()),
                column: Int(try m.require("column").u64Value())
            )
        }
    } catch let e as MsgPackError {
        throw CoreError.decode("\(e)")
    }
}

// MARK: - Tree-sitter highlight runs (migration slice — TSK-660)

/// One highlight run from the Rust core: UTF-16 NSRange pieces + the app
/// `TokenKind` rawValue (the core's capture table mirrors CaptureMap.swift).
public struct CoreHighlightRun: Equatable, Sendable {
    public let start: Int
    public let len: Int
    public let kind: String
}

/// Tokenise `text` as `lang` (the host `HighlightLanguage` rawValue) through
/// the Rust core (STATELESS, `{text, lang}` frame in, `{supported, runs}`
/// frame out). Returns `nil` when this core build has NO grammar for `lang`
/// — the caller's fall-back-to-Swift signal, distinct from a real empty
/// result. Throws `CoreError` only on a bridge fault.
public func mdvCoreHighlightRuns(text: String, lang: String) throws -> [CoreHighlightRun]? {
    let request = MsgPackValue.map([
        (.string("text"), .string(text)),
        (.string("lang"), .string(lang)),
    ])
    guard let body = try CoreTransportRegistry.current.call("highlight_runs", request: request)
    else {
        throw CoreError.decode("empty highlight_runs response frame")
    }
    var reader = MsgPackReader(body)
    do {
        let map = try reader.decode().mapValue()
        guard case .bool(true) = map["supported"] ?? .bool(false) else { return nil }
        guard let runs = map["runs"] else { throw CoreError.decode("missing 'runs'") }
        return try runs.arrayValue().map { el in
            let m = try el.mapValue()
            return CoreHighlightRun(
                start: Int(try m.require("start").u64Value()),
                len: Int(try m.require("len").u64Value()),
                kind: try m.require("kind").stringValue()
            )
        }
    } catch let e as MsgPackError {
        throw CoreError.decode("\(e)")
    }
}

// MARK: - Claude transcript parse (migration slice — TSK-632)

/// One projected transcript event from the Rust core — mirrors the Swift
/// `ClaudeEvent.Kind` cases. `timestampMs` is epoch milliseconds (the
/// `withFractionalSeconds` precision); divergence from the Swift twin: a
/// record with neither `uuid` nor `id` gets a deterministic `line-<n>` id
/// rather than a random UUID (the core reads no randomness).
public struct CoreTranscriptEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case userMessage(text: String)
        case assistantMessage(text: String)
        case thinking(text: String)
        case toolUse(id: String, name: String, input: [String: String])
        case toolResult(toolUseId: String, summary: String)
    }

    public let id: String
    public let timestampMs: Int64?
    public let kind: Kind
}

/// Parse a Claude JSONL transcript through the Rust core (STATELESS,
/// `{text, redacting}` frame in, `{events:[…]}` frame out — tolerant framing,
/// torn/invalid lines skipped, the S6/S7 line-byte/event caps applied).
/// `redacting: true` routes every record through the TSK-245 barrier
/// (signature/headers/image-blob scrub) and is REQUIRED for surfacing
/// consumers. Throws `CoreError` only on a bridge FAULT so an adapter can
/// fall back to the Swift `ClaudeLogParser`.
public func mdvCoreTranscriptParse(
    text: String,
    redacting: Bool,
    maxEvents: Int? = nil
) throws -> [CoreTranscriptEvent] {
    var fields: [(MsgPackValue, MsgPackValue)] = [
        (.string("text"), .string(text)),
        (.string("redacting"), .bool(redacting)),
    ]
    if let maxEvents, maxEvents > 0 {
        fields.append((.string("max_events"), .uint(UInt64(maxEvents))))
    }
    let request = MsgPackValue.map(fields)
    guard let body = try CoreTransportRegistry.current.call("transcript_parse", request: request) else {
        throw CoreError.decode("empty transcript_parse response frame")
    }
    var reader = MsgPackReader(body)
    do {
        let map = try reader.decode().mapValue()
        guard let events = map["events"] else { throw CoreError.decode("missing 'events'") }
        return try events.arrayValue().map { el in
            let m = try el.mapValue()
            let id = try m.require("id").stringValue()
            var timestampMs: Int64?
            if let ts = m["timestamp_ms"], !ts.isNil {
                timestampMs = try ts.i64Value()
            }
            let kind: CoreTranscriptEvent.Kind
            switch try m.require("kind").stringValue() {
            case "user":
                kind = .userMessage(text: try m.require("text").stringValue())
            case "assistant":
                kind = .assistantMessage(text: try m.require("text").stringValue())
            case "thinking":
                kind = .thinking(text: try m.require("text").stringValue())
            case "tool_use":
                var input: [String: String] = [:]
                for pair in try m.require("input").arrayValue() {
                    let kv = try pair.arrayValue()
                    if kv.count == 2 {
                        input[try kv[0].stringValue()] = try kv[1].stringValue()
                    }
                }
                kind = .toolUse(
                    id: id,
                    name: try m.require("name").stringValue(),
                    input: input)
            case "tool_result":
                kind = .toolResult(
                    toolUseId: try m.require("tool_use_id").stringValue(),
                    summary: try m.require("summary").stringValue())
            case let unknown:
                throw CoreError.decode("unknown transcript event kind '\(unknown)'")
            }
            return CoreTranscriptEvent(id: id, timestampMs: timestampMs, kind: kind)
        }
    } catch let e as MsgPackError {
        throw CoreError.decode("\(e)")
    }
}

// MARK: - Markdown structural render (migration slice — TSK-631)

/// One host-enrichment island from the Rust markdown renderer. The html
/// carries a `<!--mdv-chunk-N-->` sentinel per chunk; the host splices:
/// `raw_html` → HTMLSanitizer (the security barrier stays Swift-side),
/// `mermaid` → the mermaid host div, `code` → syntax-highlighted fence body.
public struct CoreMarkdownChunk: Equatable, Sendable {
    public let kind: String
    public let lang: String
    public let payload: String

    public init(kind: String, lang: String, payload: String) {
        self.kind = kind
        self.lang = lang
        self.payload = payload
    }
}

/// The Rust renderer's output: structural html + enrichment chunks.
public struct CoreMarkdownRendered: Equatable, Sendable {
    public let html: String
    public let chunks: [CoreMarkdownChunk]

    /// The sentinel marking where chunk `n` splices in.
    public static func sentinel(_ n: Int) -> String { "<!--mdv-chunk-\(n)-->" }

    /// Splice enriched chunk content into the html. Segment-based scan of
    /// the ORIGINAL html, left-to-right, each sentinel consumed once — a
    /// payload that *contains* sentinel text cannot hijack a later slot.
    public func spliced(_ enrich: (CoreMarkdownChunk) -> String) -> String {
        var out = ""
        var rest = Substring(html)
        for (i, chunk) in chunks.enumerated() {
            guard let range = rest.range(of: Self.sentinel(i)) else { continue }
            out += rest[..<range.lowerBound]
            out += enrich(chunk)
            rest = rest[range.upperBound...]
        }
        out += rest
        return out
    }
}

/// Render markdown through the Rust core (STATELESS, `{text}` frame in,
/// `{html, chunks}` frame out — see `CoreMarkdownRendered` for the splice
/// contract). Raw HTML NEVER appears in `html`; it rides `raw_html` chunks
/// for the host sanitizer. Throws `CoreError` only on a bridge FAULT so an
/// adapter can fall back to the Swift `HTMLRenderer`.
public func mdvCoreMarkdownRender(text: String) throws -> CoreMarkdownRendered {
    let request = MsgPackValue.map([
        (.string("text"), .string(text)),
    ])
    guard let body = try CoreTransportRegistry.current.call("markdown_render", request: request) else {
        throw CoreError.decode("empty markdown_render response frame")
    }
    var reader = MsgPackReader(body)
    do {
        let map = try reader.decode().mapValue()
        let html = try map.require("html").stringValue()
        let chunks = try map.require("chunks").arrayValue().map { el in
            let m = try el.mapValue()
            return CoreMarkdownChunk(
                kind: try m.require("kind").stringValue(),
                lang: try m.require("lang").stringValue(),
                payload: try m.require("payload").stringValue())
        }
        return CoreMarkdownRendered(html: html, chunks: chunks)
    } catch let e as MsgPackError {
        throw CoreError.decode("\(e)")
    }
}
