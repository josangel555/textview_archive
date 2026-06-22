import CMdvCore
import Foundation
import os

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
    /// The envelope dispatch was handed a method id the LINKED core doesn't
    /// know (TSK-982) — a method-space SKEW (forward-compat / remote-skew),
    /// NOT a genuine core fault. Distinct from `.internalError` so a host can
    /// tell a version/capability mismatch (gate on `CoreABI.capabilities`,
    /// fall back, surface an upgrade hint) apart from a crash that reads the
    /// same. `method` carries the offending id WHEN the call site knew it (the
    /// envelope wrappers); a bare status→error map has no id and leaves it nil.
    case unknownMethod(method: UInt16?)
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
        case MDV_STATUS_UNKNOWN_METHOD: self = .unknownMethod(method: nil)
        case MDV_STATUS_PANIC: self = .panic
        case MDV_STATUS_INTERNAL: self = .internalError
        default: self = .unknown(status.rawValue)
        }
    }

    /// Status→error map that ENRICHES the method-space skew with the offending
    /// method id (TSK-982). Use at the envelope call sites that know `method`:
    /// an `MDV_STATUS_UNKNOWN_METHOD` becomes `.unknownMethod(method: method)`
    /// so the host can log/branch on exactly which id skewed. Every other
    /// status maps identically to `init(status:)`.
    init(status: MdvStatus, method: UInt16) {
        if status == MDV_STATUS_UNKNOWN_METHOD {
            self = .unknownMethod(method: method)
        } else {
            self.init(status: status)
        }
    }
}

/// The rich error detail carried in the MessagePack body on a wire fault
/// (TSK-577 emits it; TSK-669 decodes it here). The C status enum is coarse;
/// this gives host-side diagnosis the message + a stable `kind` tag
/// (encode|decode|framing|too_large). `code` mirrors the C status discriminant.
public struct WireErrorDetail: Equatable, Sendable {
    public let code: Int
    public let message: String
    public let kind: String
}

/// The Swift side of the thin-waist envelope (TSK-580): route a STATELESS
/// method through the single `mdvcore_call` dispatch, using the `MDV_METHOD_*`
/// ids cbindgen emits into the C header (no hand-synced Swift table). Returns
/// the response frame; throws `CoreError` on a fault (with the rich WireError
/// detail logged, TSK-669). The per-method C symbols still exist during the
/// migration — this is the forward path new callers should use.
public enum CoreEnvelope {
    /// Dispatch `req` (a length-prefixed request frame) to `method`. `aux` is
    /// the reserved bulk side-channel (unused by the current methods).
    public static func call(method: UInt16, req: [UInt8], aux: [UInt8] = []) throws -> [UInt8] {
        var buf = MdvBuf(data: nil, len: 0, cap: 0)
        let status = req.withUnsafeBufferPointer { rp in
            aux.withUnsafeBufferPointer { ap in
                mdvcore_call(method, rp.baseAddress, UInt(rp.count),
                             ap.baseAddress, UInt(ap.count), &buf)
            }
        }
        defer { mdvcore_buf_free(&buf) }
        if status != MDV_STATUS_OK {
            CsvSession.logWireErrorIfPresent(buf)   // TSK-669 rich-error diagnosis
            throw CoreError(status: status, method: method)   // TSK-982 carries the skewed id
        }
        guard let data = buf.data, buf.len > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buf.len)))
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

    /// A WINDOW of the visible-rows snapshot — rows `[offset, offset+limit)`
    /// of the surviving (post-filter) set (TSK-559). Same shape as
    /// `snapshot()` but O(window): a consumer pages the viewport instead of
    /// pulling the whole filtered set, so filter-as-you-type on a large table
    /// costs ~one screen of rows per keystroke. The returned `indices` carry
    /// the ABSOLUTE row ids of the window; pair with `filteredCount()` to size
    /// the scrollbar. An `offset` past the end yields an empty window.
    public func snapshotWindow(offset: Int, limit: Int) throws -> Snapshot {
        let h = try liveHandle()
        var buf = MdvBuf(data: nil, len: 0, cap: 0)
        let status = mdvcore_session_snapshot_window(
            h, UInt64(max(0, offset)), UInt64(max(0, limit)), &buf)
        defer { mdvcore_buf_free(&buf) }
        if status != MDV_STATUS_OK {
            // TSK-981: the core emits a rich WireError frame into out_buf on a
            // wire fault — decode + log it for host-side diagnosis before the
            // coarse status throws, matching `callBuf`/`CoreEnvelope.call`.
            // Without this the windowed-snapshot error path discarded the rich
            // detail (the bare enum can't explain a malformed/too-large fault).
            Self.logWireErrorIfPresent(buf)
        }
        try check(status)
        let frame: [UInt8]
        if let data = buf.data, buf.len > 0 {
            frame = Array(UnsafeBufferPointer(start: data, count: Int(buf.len)))
        } else {
            frame = []
        }
        return try Self.decodeSnapshot(frame)
    }

    /// The number of rows surviving the current filter — the windowable set
    /// size, for scrollbar sizing (TSK-559). Cheap: serializes no rows.
    public func filteredCount() throws -> Int {
        let h = try liveHandle()
        var count: UInt64 = 0
        try check(mdvcore_session_filtered_count(h, &count))
        return Int(clamping: count)
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
        if status != MDV_STATUS_OK {
            // TSK-669: the core emits a rich WireError frame into out_buf on a
            // wire fault — decode + log it for host-side diagnosis before the
            // coarse status throws (production triage of large-file/malformed
            // failures, which the bare enum couldn't explain).
            Self.logWireErrorIfPresent(buf)
        }
        try check(status)
        guard let data = buf.data, buf.len > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(buf.len)))
    }

    /// If `buf` carries a WireError frame (TSK-577), log its detail. No-op for
    /// an empty buf or a non-WireError payload. Called on the error path only.
    static func logWireErrorIfPresent(_ buf: MdvBuf) {
        guard let data = buf.data, buf.len > 0 else { return }
        let frame = Array(UnsafeBufferPointer(start: data, count: Int(buf.len)))
        switch classifyErrorBuffer(frame) {
        case .empty:
            break
        case .wireError(let detail):
            log.error(
                "FFI wire fault [\(detail.kind, privacy: .public)] code=\(detail.code, privacy: .public): \(detail.message, privacy: .public)"
            )
        case .undecodable(let bytes):
            // TSK-995: a non-empty error-path buffer that ISN'T a decodable
            // WireError must be surfaced, not silently dropped (the gap was the
            // bare `guard let … else { return }`).
            log.error("FFI error buffer present (\(bytes, privacy: .public) bytes) but not a decodable WireError")
        }
    }

    /// Classification of an error-path out-buffer for logging (TSK-995). The
    /// `.undecodable` case is the observability gap this closes: a non-empty
    /// buffer the core emitted on a fault that doesn't parse as a WireError.
    enum ErrorBufferClass: Equatable {
        case empty
        case wireError(WireErrorDetail)
        case undecodable(bytes: Int)
    }

    static func classifyErrorBuffer(_ frame: [UInt8]) -> ErrorBufferClass {
        if frame.isEmpty { return .empty }
        if let detail = decodeWireError(frame) { return .wireError(detail) }
        return .undecodable(bytes: frame.count)
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

    /// Zero-copy twin of `unframe` (TSK-564): validate the 4-byte LE length
    /// prefix against the remaining bytes and return the BODY START OFFSET (4),
    /// without copying `frame[4...]`. The caller decodes the body in place via
    /// `MsgPackReader(frame, startingAt:)`. Same validation as `unframe`; use it
    /// on the big-payload decode paths (table/snapshot) where the body copy
    /// scales with the frame.
    static func frameBodyStart(_ frame: [UInt8]) throws -> Int {
        guard frame.count >= 4 else {
            throw CoreError.decode("frame shorter than length prefix")
        }
        let declared =
            UInt32(frame[0]) | (UInt32(frame[1]) << 8)
            | (UInt32(frame[2]) << 16) | (UInt32(frame[3]) << 24)
        let bodyLen = frame.count - 4
        guard Int(declared) == bodyLen else {
            throw CoreError.decode("frame length \(declared) != body \(bodyLen)")
        }
        return 4
    }

    /// Single-copy unframe straight off the raw FFI out-buffer (TSK-826).
    ///
    /// The pre-existing receive path materialized every response frame TWICE:
    /// `Array(UnsafeBufferPointer(...))` copied the whole framed buffer out of
    /// the C `MdvBuf`, then `unframe` did `Array(frame[4...])` to strip the
    /// 4-byte length prefix — a second full-body copy that scales with the
    /// payload (a >1 MB markdown/find/transcript response copies >1 MB twice).
    ///
    /// This validates the LE length prefix directly against the FFI buffer and
    /// copies ONLY the body subrange `[4..<len]` into a single `[UInt8]` — one
    /// copy, the unavoidable one (the C buffer is freed right after by the
    /// caller's `defer mdvcore_buf_free`). Returns `nil` for a length-0 body
    /// (an empty response, e.g. hunk marks), matching the old
    /// `buf.len > 0` guard the callers used before unframing.
    ///
    /// `base`/`count` are the raw `MdvBuf.data`/`MdvBuf.len`. The pointer is
    /// borrowed for the duration of this call only.
    static func copyFrameBody(_ base: UnsafePointer<UInt8>, _ count: Int) throws -> [UInt8] {
        guard count >= 4 else {
            throw CoreError.decode("frame shorter than length prefix")
        }
        let declared =
            UInt32(base[0]) | (UInt32(base[1]) << 8)
            | (UInt32(base[2]) << 16) | (UInt32(base[3]) << 24)
        let bodyLen = count - 4
        guard Int(declared) == bodyLen else {
            throw CoreError.decode("frame length \(declared) != body \(bodyLen)")
        }
        // The single, unavoidable copy: the body subrange [4..<count]. No
        // intermediate full-frame Array, no second `frame[4...]` copy.
        return [UInt8](UnsafeBufferPointer(start: base + 4, count: bodyLen))
    }

    /// Diagnostics channel for FFI faults (TSK-669).
    static let log = Logger(subsystem: "com.markdownviewer.RustCore", category: "ffi")

    /// Decode the rich WireError frame the core emits into out_buf on a wire
    /// fault (TSK-577/669). Returns nil for an empty buf or any frame that
    /// isn't a WireError map — total and non-throwing, since this runs on the
    /// ERROR path and must not mask the original status with a decode throw.
    static func decodeWireError(_ frame: [UInt8]) -> WireErrorDetail? {
        guard let body = try? unframe(frame) else { return nil }
        var reader = MsgPackReader(body)
        guard let map = try? reader.decode().mapValue(),
              let code = try? map.require("code").i64Value(),
              let message = try? map.require("message").stringValue()
        else { return nil }
        var kind = ""
        if let pairs = try? map.require("data").arrayValue() {
            for pair in pairs {
                guard let kv = try? pair.arrayValue(), kv.count == 2,
                      let k = try? kv[0].stringValue(), k == "kind",
                      let v = try? kv[1].stringValue()
                else { continue }
                kind = v
            }
        }
        return WireErrorDetail(code: Int(code), message: message, kind: kind)
    }

    static func decodeTable(_ frame: [UInt8]) throws -> Table {
        if frame.isEmpty {
            return Table(delimiter: "", header: [], rows: [], truncated: false)
        }
        var reader = MsgPackReader(frame, startingAt: try frameBodyStart(frame))
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
        var reader = MsgPackReader(frame, startingAt: try frameBodyStart(frame))
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
    // TSK-826: single-copy unframe — copy ONLY the body off the FFI buffer,
    // skipping the old full-frame Array + `Array(frame[4...])` double copy.
    return try CsvSession.copyFrameBody(data, Int(buf.len))
}

/// Same ritual as `mdvFrameCall`, but routes through the thin-waist envelope
/// `mdvcore_call(methodId, …)` instead of a per-method symbol (TSK-580 slice 4).
/// Byte-identical to the direct symbol (proven by the dispatch parity tests),
/// so migrating the transport seam to it is behavior-preserving — and it is the
/// SINGLE entry a remote `mdv-serve` carrier exposes (the transport-agnostic
/// goal). Logs the rich WireError detail (TSK-669) on a fault.
func mdvEnvelopeCall(_ name: String, _ methodId: UInt16, body: [UInt8]) throws -> [UInt8]? {
    _ = name // observability tag (the audit point is one level up, CoreTransport.call)
    CoreABI.assertCompatible()
    let reqBytes = MsgPackFraming.frame(body)
    var buf = MdvBuf(data: nil, len: 0, cap: 0)
    let status = reqBytes.withUnsafeBufferPointer { p in
        mdvcore_call(methodId, p.baseAddress, UInt(p.count), nil, 0, &buf)
    }
    defer { mdvcore_buf_free(&buf) }
    guard status == MDV_STATUS_OK else {
        CsvSession.logWireErrorIfPresent(buf)
        throw CoreError(status: status, method: methodId)   // TSK-982 carries the skewed id
    }
    guard let data = buf.data, buf.len > 0 else { return nil }
    // TSK-826: single-copy unframe (see mdvFrameCall).
    return try CsvSession.copyFrameBody(data, Int(buf.len))
}

/// Envelope call WITH the `aux` bulk side-channel (TSK-580 slice 3) for the
/// raw-byte methods — hex render (~18 MB dump), hex search, indent detect. The
/// small scalar request rides `body` (framed here, exactly like
/// `mdvEnvelopeCall`); the frame-cap-exempt bulk input rides `aux`, borrowed
/// zero-copy across the FFI (no `[UInt8]` copy of a multi-MiB file). Returns the
/// RAW `out_buf` bytes UNFRAMED — the caller decides whether they are a response
/// frame (HexSearch's `{offsets}`) or a raw payload (HexRender/IndentDetect
/// dumps), because `dispatch::call` returns those methods' output verbatim and
/// `MdvStatus` (Ok vs a wire status) disambiguates raw output from an error
/// frame. Same ABI assert + WireError logging as the frame envelope.
func mdvEnvelopeCallAux(
    _ name: String, _ methodId: UInt16,
    body: [UInt8], aux: UnsafeRawBufferPointer
) throws -> [UInt8]? {
    _ = name // observability tag (the audit point is one level up, CoreTransport.call)
    CoreABI.assertCompatible()
    let reqBytes = MsgPackFraming.frame(body)
    var buf = MdvBuf(data: nil, len: 0, cap: 0)
    // baseAddress is nil for an empty buffer; the FFI tolerates (null, 0).
    let auxBase = aux.bindMemory(to: UInt8.self).baseAddress
    let status = reqBytes.withUnsafeBufferPointer { p in
        mdvcore_call(methodId, p.baseAddress, UInt(p.count), auxBase, UInt(aux.count), &buf)
    }
    defer { mdvcore_buf_free(&buf) }
    guard status == MDV_STATUS_OK else {
        CsvSession.logWireErrorIfPresent(buf)
        throw CoreError(status: status, method: methodId)   // TSK-982 carries the skewed id
    }
    guard let data = buf.data, buf.len > 0 else { return nil }
    return Array(UnsafeBufferPointer(start: data, count: Int(buf.len)))
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

/// A formula evaluation result in RustCore's own vocabulary. ViewerCore's
/// `RustFormulaAdapter` maps it to the app's `FormulaValue` (RustCore cannot
/// depend on ViewerCore). `error` carries the Excel-style code Rust emits
/// ("dividebyzero", "value", "na", …).
public enum CoreFormulaValue: Sendable, Equatable {
    case number(Double)
    case text(String)
    case boolean(Bool)
    case blank
    case error(String)
}

/// Evaluate `formulas` in the Rust core (TSK-1213, STATELESS): a
/// `{formulas, cells}` request frame in, a `{values:[…]}` response out. `cells`
/// is the A1→raw-text snapshot the formulas resolve against (a missing key is a
/// blank cell). Throws `CoreError` on a bridge fault so the adapter can fall
/// back to the Swift engine.
public func mdvCoreEvaluateFormulas(
    _ formulas: [String], cells: [String: String]
) throws -> [CoreFormulaValue] {
    let cellPairs: [(MsgPackValue, MsgPackValue)] = cells.map { (.string($0.key), .string($0.value)) }
    let request = MsgPackValue.map([
        (.string("formulas"), .array(formulas.map { .string($0) })),
        (.string("cells"), .map(cellPairs)),
    ])
    guard let body = try CoreTransportRegistry.current.call("formula_evaluate", request: request) else {
        throw CoreError.decode("empty formula_evaluate response frame")
    }
    var reader = MsgPackReader(body)
    do {
        let map = try reader.decode().mapValue()
        guard let valuesVal = map["values"] else { throw CoreError.decode("missing 'values'") }
        return try valuesVal.arrayValue().map(decodeFormulaValue)
    } catch let e as MsgPackError {
        throw CoreError.decode("\(e)")
    }
}

private func decodeFormulaValue(_ v: MsgPackValue) throws -> CoreFormulaValue {
    let map = try v.mapValue()
    guard let kind = try map["kind"]?.stringValue() else {
        throw CoreError.decode("formula value missing 'kind'")
    }
    switch kind {
    case "number": return .number(try (map["value"] ?? .nilValue).doubleValue())
    case "text": return .text(try (map["value"] ?? .string("")).stringValue())
    case "bool": return .boolean(try (map["value"] ?? .bool(false)).boolValue())
    case "blank": return .blank
    case "error": return .error(try (map["value"] ?? .string("error")).stringValue())
    default: throw CoreError.decode("unknown formula value kind '\(kind)'")
    }
}

/// Recalculate a whole grid in the Rust core (TSK-1213): the full grid as
/// A1 → raw text in, A1 → computed `CoreFormulaValue` (formula cells only) out.
/// Unlike `mdvCoreEvaluateFormulas`, references to other FORMULA cells resolve to
/// their computed value (cycles → an `error("cycle")`). Throws `CoreError` on a
/// bridge fault so the adapter can fall back to the Swift engine.
public func mdvCoreRecalc(cells: [String: String]) throws -> [String: CoreFormulaValue] {
    let cellPairs: [(MsgPackValue, MsgPackValue)] = cells.map { (.string($0.key), .string($0.value)) }
    let request = MsgPackValue.map([(.string("cells"), .map(cellPairs))])
    guard let body = try CoreTransportRegistry.current.call("formula_recalc", request: request) else {
        throw CoreError.decode("empty formula_recalc response frame")
    }
    var reader = MsgPackReader(body)
    do {
        let map = try reader.decode().mapValue()
        guard let valuesVal = map["values"] else { throw CoreError.decode("missing 'values'") }
        let valuesMap = try valuesVal.mapValue()
        var out: [String: CoreFormulaValue] = [:]
        out.reserveCapacity(valuesMap.count)
        for (a1, v) in valuesMap {
            out[a1] = try decodeFormulaValue(v)
        }
        return out
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
    // TSK-580 slice 3-output close-out: route through the thin-waist envelope
    // (`mdvcore_call`, MDV_METHOD_HEX_RENDER) instead of the dedicated
    // `mdvcore_hex_render` symbol. The bytes ride the `aux` bulk channel
    // (frame-cap-exempt); {width, total_byte_count, is_truncated} ride the small
    // request frame (named map → the Rust `RenderAuxRequest`). Byte-identical:
    // the FFI envelope_routes_hex_render_raw_bulk_output A/B test pins it, and
    // HexRenderABTests re-verifies the whole corpus vs the Swift engine THROUGH
    // this path.
    let req = MsgPackValue.map([
        (.string("width"), .uint(UInt64(UInt32(truncatingIfNeeded: width)))),
        (.string("total_byte_count"), .uint(UInt64(truncatingIfNeeded: totalByteCount))),
        (.string("is_truncated"), .bool(isTruncated)),
    ]).encode()
    let out = try bytes.withUnsafeBytes { raw in
        try mdvEnvelopeCallAux("hex_render", UInt16(MDV_METHOD_HEX_RENDER), body: req, aux: raw)
    }
    guard let out, !out.isEmpty else {
        return ""   // empty file, non-truncated → empty dump (valid)
    }
    return String(decoding: out, as: UTF8.self)
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
    // TSK-580 slice 3 close-out: route through the envelope (MDV_METHOD_HEX_SEARCH)
    // instead of the dedicated `mdvcore_hex_search` symbol. The buffer to search
    // rides the `aux` bulk channel (frame-cap-exempt); {query, mode} ride the
    // small request frame (named map → the Rust `SearchAuxRequest`). Unlike the
    // raw-output render/detect, HexSearch's response IS a `{offsets:[u32]}` frame,
    // so unframe it. Byte-identical (FFI envelope_routes_hex_search A/B pin +
    // HexSearchABTests corpus through this path).
    let req = MsgPackValue.map([
        (.string("query"), .string(query)),
        (.string("mode"), .uint(UInt64(mode.rawValue))),
    ]).encode()
    let frame = try data.withUnsafeBytes { raw in
        try mdvEnvelopeCallAux("hex_search", UInt16(MDV_METHOD_HEX_SEARCH), body: req, aux: raw)
    }
    guard let frame else { return [] }
    // TSK-826: `mdvEnvelopeCallAux` already materialized the full frame once
    // (the aux helper is shared with raw-output methods, so it can't unframe).
    // Decode the body IN PLACE from offset 4 (frameBodyStart) rather than
    // copying `frame[4...]` into a second Array.
    var reader = MsgPackReader(frame, startingAt: try CsvSession.frameBodyStart(frame))
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
    // TSK-580 slice 3-output close-out: route through the envelope
    // (MDV_METHOD_INDENT_DETECT) instead of the dedicated `mdvcore_indent_detect`
    // symbol. The source text rides the `aux` bulk channel; {sample_lines} rides
    // the small request frame (named map → the Rust `DetectAuxRequest`). Result
    // is the RAW UTF-8 style string (not a frame). Byte-identical (FFI
    // envelope_routes_indent_detect A/B pin + IndentDetectABTests corpus).
    // TSK-651: route through the transport seam so a remote `mdv-serve`
    // carries indent detection too (the loopback acceptance pins byte-equality
    // local vs remote). `aux` carries the source text; `body` carries the
    // {sample_lines} scalar frame. In-process this lands back on
    // `mdvEnvelopeCallAux` (byte-identical to the prior direct call).
    let req = MsgPackValue.map([
        (.string("sample_lines"), .uint(UInt64(UInt32(truncatingIfNeeded: sampleLines)))),
    ]).encode()
    let out = try CoreTransportRegistry.current.callAux(
        "indent_detect", requestBody: req, aux: [UInt8](text.utf8))
    guard let out, !out.isEmpty else { return "—" }  // unreachable: detect is never empty
    return String(decoding: out, as: UTF8.self)
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
            // Allocation-free per-row field access: no throwaway dict per match.
            return FuzzyRanked(
                index: Int(try el.requireField("index").u64Value()),
                score: Int(try el.requireField("score").u64Value()),
                matchedIndices: try el.requireField("indices").u32Array().map(Int.init)
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
            // Allocation-free per-row field access: no throwaway dict per match.
            return CoreFindMatch(
                location: Int(try el.requireField("location").u64Value()),
                length: Int(try el.requireField("length").u64Value()),
                line: Int(try el.requireField("line").u64Value()),
                column: Int(try el.requireField("column").u64Value())
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
        return try runs.arrayValue().compactMap { el -> CoreHighlightRun? in
            // TSK-841: each run is a POSITIONAL [start, len, kind] array (was a
            // {start,len,kind} map) — 4× smaller / ~5× faster decode. The Rust
            // encoder (`runs.rs` Run::serialize) emits the matching tuple.
            let a = try el.arrayValue()
            guard a.count >= 3 else {
                throw CoreError.decode("highlight run wire arity \(a.count) < 3")
            }
            // TSK-978: `Int(UInt64)` TRAPS on values > Int.max. Highlight is a
            // capability bit, so a remote producer can route a `start`/`len` of
            // 2^63 here and crash the app at DECODE time, BEFORE any length
            // clamp. Bound-check via `Int(exactly:)` and DROP a span that can't
            // fit `Int` rather than synthesize a bogus one — the wire fault
            // (string `kind`, arity) still throws; only an over-range offset is
            // benign-dropped. (`kind` decoded first to keep type faults loud.)
            // TSK-978: `Int(UInt64)` TRAPS on values > Int.max. Highlight is a
            // capability bit, so a remote producer can route a `start`/`len` of
            // 2^63 here and crash the app at DECODE time, BEFORE any length
            // clamp. Bound-check via `Int(exactly:)` and DROP a span that can't
            // fit `Int` rather than synthesize a bogus one — the wire fault
            // (string `kind`, arity) still throws; only an over-range offset is
            // benign-dropped. (`kind` decoded first to keep type faults loud.)
            let kind = try a[2].stringValue()
            guard let start = Int(exactly: try a[0].u64Value()),
                  let len = Int(exactly: try a[1].u64Value())
            else {
                return nil
            }
            return CoreHighlightRun(start: start, len: len, kind: kind)
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
            // Allocation-free per-row field access: no throwaway dict per event.
            let id = try el.requireField("id").stringValue()
            var timestampMs: Int64?
            if let ts = try el.field("timestamp_ms"), !ts.isNil {
                timestampMs = try ts.i64Value()
            }
            let kind: CoreTranscriptEvent.Kind
            switch try el.requireField("kind").stringValue() {
            case "user":
                kind = .userMessage(text: try el.requireField("text").stringValue())
            case "assistant":
                kind = .assistantMessage(text: try el.requireField("text").stringValue())
            case "thinking":
                kind = .thinking(text: try el.requireField("text").stringValue())
            case "tool_use":
                var input: [String: String] = [:]
                for pair in try el.requireField("input").arrayValue() {
                    let kv = try pair.arrayValue()
                    if kv.count == 2 {
                        input[try kv[0].stringValue()] = try kv[1].stringValue()
                    }
                }
                kind = .toolUse(
                    id: id,
                    name: try el.requireField("name").stringValue(),
                    input: input)
            case "tool_result":
                kind = .toolResult(
                    toolUseId: try el.requireField("tool_use_id").stringValue(),
                    summary: try el.requireField("summary").stringValue())
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
            // Allocation-free per-row field access: no throwaway dict per chunk.
            return CoreMarkdownChunk(
                kind: try el.requireField("kind").stringValue(),
                lang: try el.requireField("lang").stringValue(),
                payload: try el.requireField("payload").stringValue())
        }
        return CoreMarkdownRendered(html: html, chunks: chunks)
    } catch let e as MsgPackError {
        throw CoreError.decode("\(e)")
    }
}
