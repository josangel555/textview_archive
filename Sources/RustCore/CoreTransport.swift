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

    /// Invoke an AUX-bearing method (TSK-651): the small scalar request rides
    /// `requestBody`; the frame-cap-exempt bulk input (the indent text, the
    /// hex-search/render buffer) rides `aux`. Returns the response body bytes
    /// VERBATIM — the caller knows by method whether they are a response frame
    /// (hex search) or a raw payload (indent detect / hex render). Default
    /// impl rejects it so a transport that hasn't joined the aux seam fails
    /// loudly rather than silently dropping the bulk channel.
    func callAux(_ method: String, requestBody: [UInt8], aux: [UInt8]) throws -> [UInt8]?
}

extension CoreTransport {
    /// Wrapper-side convenience over the byte-level requirement.
    func call(_ method: String, request: MsgPackValue) throws -> [UInt8]? {
        try call(method, requestBody: request.encode())
    }

    /// Default: a transport that hasn't joined the aux seam can't carry the
    /// bulk side-channel. (Both shipping transports override this.)
    func callAux(_ method: String, requestBody: [UInt8], aux: [UInt8]) throws -> [UInt8]? {
        throw CoreError.decode("transport does not support the aux side-channel for '\(method)'")
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

    /// TSK-580 slice 4: stateless methods route through the ONE thin-waist
    /// envelope `mdvcore_call(MDV_METHOD_*, …)` (the per-method C symbols still
    /// exist but are no longer dispatched here). Byte-identical to the old
    /// symbols (dispatch parity tests), and the single entry a remote carrier
    /// exposes. Adding a port = adding a row here + a `dispatch::Method` arm.
    static let methodIds: [String: UInt16] = [
        "cm_apply": UInt16(MDV_METHOD_CM_APPLY),
        "diff_parse": UInt16(MDV_METHOD_DIFF_PARSE),
        "diff_hunk_marks": UInt16(MDV_METHOD_DIFF_HUNK_MARKS),
        "fuzzy_rank": UInt16(MDV_METHOD_FUZZY_RANK),
        "find_search": UInt16(MDV_METHOD_FIND_SEARCH),
        "transcript_parse": UInt16(MDV_METHOD_TRANSCRIPT_PARSE),
        "markdown_render": UInt16(MDV_METHOD_MARKDOWN_RENDER),
        // slice 5: highlight (separate crate) now dispatches via the envelope
        // too — the FFI intercepts id 9 and routes it to mdvcore-highlight.
        "highlight_runs": UInt16(MDV_METHOD_HIGHLIGHT_RUNS),
        "formula_evaluate": UInt16(MDV_METHOD_FORMULA_EVALUATE),
        "formula_recalc": UInt16(MDV_METHOD_FORMULA_RECALC),
        // Folds (separate crate, like highlight): the FFI intercepts id 15 and
        // routes it to mdvcore-highlight (TSK-1202).
        "fold_regions": UInt16(MDV_METHOD_FOLD_REGIONS),
        // TSK-543: cm-apply delta — core-routable (impl in core), not intercepted.
        "cm_apply_delta": UInt16(MDV_METHOD_CM_APPLY_DELTA),
    ]

    /// AUX-bearing method ids (TSK-651): the bulk input rides the `aux`
    /// side-channel. `indent_detect` is the first to join the transport seam;
    /// hex search/render follow when their wrappers route through `callAux`.
    static let auxMethodIds: [String: UInt16] = [
        "indent_detect": UInt16(MDV_METHOD_INDENT_DETECT),
    ]

    /// Per-method-symbol fallback — now EMPTY: every stateless method routes
    /// through the envelope. Kept (with `mdvFrameCall`) as the ready path for
    /// any future method that lands as a symbol before joining the envelope.
    static let exports: [String: FrameFn] = [:]

    public func call(_ method: String, requestBody: [UInt8]) throws -> [UInt8]? {
        do {
            let result: [UInt8]?
            if let id = Self.methodIds[method] {
                result = try mdvEnvelopeCall(method, id, body: requestBody)
            } else if let fn = Self.exports[method] {
                result = try mdvFrameCall(method, fn, body: requestBody)
            } else {
                // A method name in neither table is a build-time wiring bug
                // (the wrappers and these tables live in the same module) —
                // surfaced as a typed decode fault, never a crash.
                CoreTransportRegistry.audit(method, transport: "in-process", ok: false)
                throw CoreError.decode("no in-process export for core method '\(method)'")
            }
            CoreTransportRegistry.audit(method, transport: "in-process", ok: true)
            return result
        } catch {
            CoreTransportRegistry.audit(method, transport: "in-process", ok: false)
            throw error
        }
    }

    public func callAux(_ method: String, requestBody: [UInt8], aux: [UInt8]) throws -> [UInt8]? {
        do {
            guard let id = Self.auxMethodIds[method] else {
                CoreTransportRegistry.audit(method, transport: "in-process", ok: false)
                throw CoreError.decode("no in-process aux export for core method '\(method)'")
            }
            let result = try aux.withUnsafeBytes { raw in
                try mdvEnvelopeCallAux(method, id, body: requestBody, aux: raw)
            }
            CoreTransportRegistry.audit(method, transport: "in-process", ok: true)
            return result
        } catch {
            CoreTransportRegistry.audit(method, transport: "in-process", ok: false)
            throw error
        }
    }
}

/// Process-wide transport selection. Defaults to in-process FFI; tests (and
/// the future remote client) inject here. Thread-safe; reads are on every
/// core call, so keep the critical section to the pointer swap.
public enum CoreTransportRegistry {
    nonisolated(unsafe) private static var _current: any CoreTransport = InProcessTransport()
    private static let lock = NSLock()

    /// TSK-636 audit hook — the ONE emit point covering every stateless
    /// core call on BOTH transports (`method`, `transport` tag, success).
    /// RustCore cannot depend on the host's audit log, so the host installs
    /// a closure at startup. Nil = no auditing cost beyond a nil check.
    nonisolated(unsafe) private static var _auditHook:
        (@Sendable (_ method: String, _ transport: String, _ ok: Bool) -> Void)?

    public static var auditHook:
        (@Sendable (_ method: String, _ transport: String, _ ok: Bool) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _auditHook
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _auditHook = newValue
        }
    }

    /// Called by transport impls around each call.
    static func audit(_ method: String, transport: String, ok: Bool) {
        auditHook?(method, transport, ok)
    }

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
