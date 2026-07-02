import CMdvCore
import Foundation

// Canvas M0 spike (TSK-1353) — the Swift wrapper over the canvas patch-loop
// FFI (`mdvcore_canvas_demo_open/html/apply/free`). Mirrors the `CsvSession`
// shape: opaque handle + status mapping + framed MessagePack responses.
// Throwaway-grade by design (docs/canvas/plans/M0-PLAN.md); the M1 engine
// replaces the demo-doc internals but keeps this boundary shape.

/// An op the host asks the canvas core to apply (M0: exactly two).
public enum CanvasOpRequest: Equatable, Sendable {
    case setText(id: UInt32, text: String)
    case setStyle(id: UInt32, key: String, value: String)

    /// The `{op: "...", ...}` MessagePack map the Rust side decodes.
    var msgPackValue: MsgPackValue {
        switch self {
        case let .setText(id, text):
            return .map([
                MsgPackPair(.string("op"), .string("setText")),
                MsgPackPair(.string("id"), .uint(UInt64(id))),
                MsgPackPair(.string("text"), .string(text)),
            ])
        case let .setStyle(id, key, value):
            return .map([
                MsgPackPair(.string("op"), .string("setStyle")),
                MsgPackPair(.string("id"), .uint(UInt64(id))),
                MsgPackPair(.string("key"), .string(key)),
                MsgPackPair(.string("value"), .string(value)),
            ])
        }
    }
}

/// One patch instruction from the core's patch plan (M0 mirror of the op).
public enum CanvasPatch: Equatable, Sendable {
    case setText(id: UInt32, text: String)
    case setStyle(id: UInt32, key: String, value: String)
}

/// The decoded `{rev, patches, rejected}` patch-plan response.
public struct CanvasPatchPlan: Equatable, Sendable {
    public let rev: UInt64
    public let patches: [CanvasPatch]
    public let rejected: [UInt32]
}

/// Swift handle over the M0 canvas demo document. Single-writer (the core
/// returns `.busy` on contention); NOT thread-safe by design — confine to one
/// actor/queue like `CsvSession`.
public final class CanvasDemoSession {
    private var handle: OpaquePointer?
    private var dead = false

    /// Open the hardcoded ~200-node demo document in the core.
    public init() throws {
        var h: OpaquePointer?
        let status = mdvcore_canvas_demo_open(&h)
        guard status == MDV_STATUS_OK, h != nil else {
            throw CanvasDemoSession.mapError(status)
        }
        handle = h
    }

    deinit {
        if let h = handle {
            mdvcore_canvas_free(h)
        }
    }

    /// Lower the whole document to HTML (raw UTF-8 bytes, not a frame).
    public func html() throws -> String {
        let h = try liveHandle()
        var buf = MdvBuf(data: nil, len: 0, cap: 0)
        let status = mdvcore_canvas_html(h, &buf)
        defer { mdvcore_buf_free(&buf) }
        try check(status)
        guard let data = buf.data, buf.len > 0 else { return "" }
        let bytes = Array(UnsafeBufferPointer(start: data, count: Int(buf.len)))
        guard let s = String(bytes: bytes, encoding: .utf8) else {
            throw CoreError.decode("canvas html is not UTF-8")
        }
        return s
    }

    /// Apply an op batch; returns the decoded patch plan.
    public func apply(_ ops: [CanvasOpRequest]) throws -> CanvasPatchPlan {
        let h = try liveHandle()
        let request = MsgPackValue.map([
            MsgPackPair(.string("ops"), .array(ops.map(\.msgPackValue)))
        ])
        let frame = request.frame()
        var buf = MdvBuf(data: nil, len: 0, cap: 0)
        let status = frame.withUnsafeBufferPointer { p in
            mdvcore_canvas_apply(h, p.baseAddress, UInt(p.count), &buf)
        }
        defer { mdvcore_buf_free(&buf) }
        if status != MDV_STATUS_OK {
            CsvSession.logWireErrorIfPresent(buf)
        }
        try check(status)
        guard let data = buf.data, buf.len > 0 else {
            throw CoreError.decode("empty canvas patch-plan frame")
        }
        let planFrame = Array(UnsafeBufferPointer(start: data, count: Int(buf.len)))
        return try Self.decodePlan(planFrame)
    }

    // MARK: - internals

    private func liveHandle() throws -> OpaquePointer {
        if dead { throw CoreError.handleDead }
        guard let h = handle else { throw CoreError.handleDead }
        return h
    }

    private func check(_ status: MdvStatus) throws {
        if status == MDV_STATUS_OK { return }
        let err = Self.mapError(status)
        if err == .panic || err == .handleDead {
            dead = true
        }
        throw err
    }

    private static func mapError(_ status: MdvStatus) -> CoreError {
        switch status {
        case MDV_STATUS_NULL_ARG: return .nullArg
        case MDV_STATUS_BAD_UTF8: return .badUTF8
        case MDV_STATUS_BUSY: return .busy
        case MDV_STATUS_WIRE_ERROR: return .wireError
        case MDV_STATUS_TOO_LARGE: return .tooLarge
        case MDV_STATUS_PANIC: return .panic
        case MDV_STATUS_HANDLE_DEAD: return .handleDead
        default: return .internalError
        }
    }

    static func decodePlan(_ frame: [UInt8]) throws -> CanvasPatchPlan {
        var reader = MsgPackReader(frame, startingAt: try CsvSession.frameBodyStart(frame))
        do {
            let map = try reader.decode().mapValue()
            let rev = try Self.uint(map.require("rev"), "rev")
            let patches = try map.require("patches").arrayValue().map(Self.decodePatch)
            let rejected = try map.require("rejected").arrayValue().map {
                UInt32(truncatingIfNeeded: try Self.uint($0, "rejected id"))
            }
            return CanvasPatchPlan(rev: rev, patches: patches, rejected: rejected)
        } catch let e as MsgPackError {
            throw CoreError.decode("\(e)")
        }
    }

    private static func decodePatch(_ value: MsgPackValue) throws -> CanvasPatch {
        let map = try value.mapValue()
        let op = try map.require("op").stringValue()
        let id = UInt32(truncatingIfNeeded: try Self.uint(map.require("id"), "id"))
        switch op {
        case "setText":
            return .setText(id: id, text: try map.require("text").stringValue())
        case "setStyle":
            return .setStyle(
                id: id,
                key: try map.require("key").stringValue(),
                value: try map.require("value").stringValue()
            )
        default:
            throw CoreError.decode("unknown patch op '\(op)'")
        }
    }

    /// Accept both MessagePack integer encodings for an unsigned field.
    private static func uint(_ value: MsgPackValue, _ field: String) throws -> UInt64 {
        switch value {
        case .uint(let u): return u
        case .int(let i) where i >= 0: return UInt64(i)
        default: throw CoreError.decode("field '\(field)' is not an unsigned integer")
        }
    }
}
