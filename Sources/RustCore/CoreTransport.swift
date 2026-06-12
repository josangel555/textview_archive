import Foundation
import CMdvCore

/// The transport seam (TSK-652): every STATELESS core call — request frame
/// body in, response frame body out — goes through a `CoreTransport`, so
/// local in-process FFI and a (future) remote `mdv-serve` socket are the
/// same client code; remote is a carrier swap, not a rewrite.
///
/// Scope: the frame-shaped exports (the `ffi_frame_body!` family). The
/// HANDLE-based CSV session APIs are pointer-shaped and join the seam with
/// the Phase-2 DocId registry; hex/indent use raw-byte signatures and join
/// when those move to frames.
public protocol CoreTransport: Sendable {
    /// Invoke `method` with the UNFRAMED MessagePack request body BYTES;
    /// returns the unframed response body, or `nil` for an empty response
    /// (the caller decides whether empty is legitimate). Implementations
    /// throw `CoreError` for transport/bridge faults. Byte-level on purpose:
    /// a remote carrier moves bytes; the value layer stays client-side.
    func call(_ method: String, requestBody: [UInt8]) throws -> [UInt8]?
}

extension CoreTransport {
    /// Wrapper-side convenience over the byte-level requirement.
    func call(_ method: String, request: MsgPackValue) throws -> [UInt8]? {
        try call(method, requestBody: request.encode())
    }
}

/// The local backend: dispatches to the linked `libmdvcore_ffi` exports via
/// the shared `mdvFrameCall` ritual (framing, pointer pass, buf free, status
/// mapping, ABI assert).
public struct InProcessTransport: CoreTransport {
    public init() {}

    typealias FrameFn = @Sendable (
        UnsafePointer<UInt8>?, UInt, UnsafeMutablePointer<MdvBuf>?
    ) -> MdvStatus

    /// The export table — one row per stateless frame export. Adding a port
    /// = adding a row (the misuse-matrix/capability ceremony covers the rest).
    static let exports: [String: FrameFn] = [
        "cm_apply": mdvcore_cm_apply,
        "diff_parse": mdvcore_diff_parse,
        "diff_hunk_marks": mdvcore_diff_hunk_marks,
        "fuzzy_rank": mdvcore_fuzzy_rank,
        "find_search": mdvcore_find_search,
        "transcript_parse": mdvcore_transcript_parse,
        "markdown_render": mdvcore_markdown_render,
    ]

    public func call(_ method: String, requestBody: [UInt8]) throws -> [UInt8]? {
        guard let fn = Self.exports[method] else {
            // A method name missing here is a build-time wiring bug (the
            // wrappers and this table live in the same module) — surfaced
            // as a typed decode fault, never a crash.
            throw CoreError.decode("no in-process export for core method '\(method)'")
        }
        return try mdvFrameCall(method, fn, body: requestBody)
    }
}

/// Process-wide transport selection. Defaults to in-process FFI; tests (and
/// the future remote client) inject here. Thread-safe; reads are on every
/// core call, so keep the critical section to the pointer swap.
public enum CoreTransportRegistry {
    nonisolated(unsafe) private static var _current: any CoreTransport = InProcessTransport()
    private static let lock = NSLock()

    public static var current: any CoreTransport {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _current
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _current = newValue
        }
    }

    /// Reset to the in-process default (test teardown hygiene).
    public static func resetToInProcess() {
        current = InProcessTransport()
    }
}
