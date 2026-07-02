import CMdvCore
import Foundation

// Canvas M1.S5c (TSK-1360) — the Swift wrapper over the REAL canvas engine:
// `mdvcore_canvas_doc_open/html/apply/free`, speaking the `canvas::wire`
// shapes ({baseRev, ops} → {rev, patches} | structured rejection). Replaces
// the M0 demo wrapper (numeric ids, mirror ops) that lived here through
// commit 5401e5b0.

/// A canvas op value: literal or a design-token reference.
public enum CanvasValue: Equatable, Sendable {
    case str(String)
    case num(Double)
    case bool(Bool)
    case token(String)

    var msgPackValue: MsgPackValue {
        switch self {
        case .str(let s): return .string(s)
        case .num(let n): return .double(n)
        case .bool(let b): return .bool(b)
        case .token(let path):
            return .map([MsgPackPair(.string("token"), .string(path))])
        }
    }
}

/// Position within a parent's children.
public enum CanvasPosition: Equatable, Sendable {
    case first
    case last
    case before(String)
    case after(String)

    var msgPackValue: MsgPackValue {
        switch self {
        case .first: return .map([MsgPackPair(.string("type"), .string("first"))])
        case .last: return .map([MsgPackPair(.string("type"), .string("last"))])
        case .before(let anchor):
            return .map([
                MsgPackPair(.string("type"), .string("before")),
                MsgPackPair(.string("anchor"), .string(anchor)),
            ])
        case .after(let anchor):
            return .map([
                MsgPackPair(.string("type"), .string("after")),
                MsgPackPair(.string("anchor"), .string(anchor)),
            ])
        }
    }
}

/// One canvas op (string ids, the engine's real vocabulary).
public enum CanvasOpRequest: Equatable, Sendable {
    case insert(
        id: String?, kind: String, parent: String, pos: CanvasPosition,
        props: [(String, CanvasValue)])
    case update(id: String, set: [(String, CanvasValue)], unset: [String])
    case move(id: String, parent: String, pos: CanvasPosition)
    case remove(id: String)

    public static func == (lhs: CanvasOpRequest, rhs: CanvasOpRequest) -> Bool {
        lhs.msgPackValue == rhs.msgPackValue
    }

    var msgPackValue: MsgPackValue {
        func propsValue(_ props: [(String, CanvasValue)]) -> MsgPackValue {
            .array(props.map { .array([.string($0.0), $0.1.msgPackValue]) })
        }
        switch self {
        case let .insert(id, kind, parent, pos, props):
            var pairs = [MsgPackPair(.string("op"), .string("insert"))]
            if let id { pairs.append(MsgPackPair(.string("id"), .string(id))) }
            pairs.append(MsgPackPair(.string("kind"), .string(kind)))
            pairs.append(MsgPackPair(.string("parent"), .string(parent)))
            pairs.append(MsgPackPair(.string("pos"), pos.msgPackValue))
            pairs.append(MsgPackPair(.string("props"), propsValue(props)))
            return .map(pairs)
        case let .update(id, set, unset):
            return .map([
                MsgPackPair(.string("op"), .string("update")),
                MsgPackPair(.string("id"), .string(id)),
                MsgPackPair(.string("set"), propsValue(set)),
                MsgPackPair(.string("unset"), .array(unset.map(MsgPackValue.string))),
            ])
        case let .move(id, parent, pos):
            return .map([
                MsgPackPair(.string("op"), .string("move")),
                MsgPackPair(.string("id"), .string(id)),
                MsgPackPair(.string("parent"), .string(parent)),
                MsgPackPair(.string("pos"), pos.msgPackValue),
            ])
        case let .remove(id):
            return .map([
                MsgPackPair(.string("op"), .string("remove")),
                MsgPackPair(.string("id"), .string(id)),
            ])
        }
    }
}

/// One DOM patch from the engine (the applier vocabulary).
public enum CanvasPatch: Equatable, Sendable {
    case setText(id: String, text: String)
    case setStyle(id: String, prop: String, value: String)
    case removeStyle(id: String, prop: String)
    case setAttr(id: String, attr: String, value: String)
    case insertNode(parent: String, before: String?, html: String)
    case removeNode(id: String)
    case moveNode(id: String, parent: String, before: String?)
}

/// A successful apply.
public struct CanvasApplied: Equatable, Sendable {
    public let rev: UInt64
    public let patches: [CanvasPatch]
    public let minted: [String]
    public let noop: Bool
}

/// A structured rejection (valid frame; refused batch).
public struct CanvasRejection: Error, Equatable, Sendable {
    public let kind: String
    public let detail: String
    public let currentRev: UInt64
}

/// Swift handle over a real canvas document.
public final class CanvasDocSession {
    private var handle: OpaquePointer?
    private var dead = false

    /// Open an empty document (default theme + root page `pg:1`).
    public init() throws {
        var h: OpaquePointer?
        let status = mdvcore_canvas_doc_open(&h)
        guard status == MDV_STATUS_OK, h != nil else {
            throw CanvasDocSession.mapError(status)
        }
        handle = h
    }

    deinit {
        if let h = handle {
            mdvcore_canvas_free(h)
        }
    }

    /// Root page id of documents opened by `init` (the engine's constant).
    public static let rootPage = "pg:1"

    /// Lower the whole document to HTML (raw UTF-8 bytes).
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

    /// Apply an op batch against `baseRev`. Throws `CanvasRejection` for
    /// refused batches (conflict/fence/store/idInUse) and `CoreError` for
    /// transport faults.
    public func apply(baseRev: UInt64, ops: [CanvasOpRequest]) throws -> CanvasApplied {
        let h = try liveHandle()
        let request = MsgPackValue.map([
            MsgPackPair(.string("baseRev"), .uint(baseRev)),
            MsgPackPair(.string("ops"), .array(ops.map(\.msgPackValue))),
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
            throw CoreError.decode("empty canvas apply response")
        }
        let respFrame = Array(UnsafeBufferPointer(start: data, count: Int(buf.len)))
        return try Self.decodeResponse(respFrame)
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

    static func decodeResponse(_ frame: [UInt8]) throws -> CanvasApplied {
        var reader = MsgPackReader(frame, startingAt: try CsvSession.frameBodyStart(frame))
        do {
            let map = try reader.decode().mapValue()
            // Rejection frame?
            if let rejected = map["rejected"] {
                try Self.throwRejection(rejected: rejected, map: map)
            }
            let rev = try Self.uint(map.require("rev"), "rev")
            let patches = try map.require("patches").arrayValue().map(Self.decodePatch)
            let minted = try map.require("minted").arrayValue().map { try $0.stringValue() }
            let noop = try map.require("noop").boolValue()
            return CanvasApplied(rev: rev, patches: patches, minted: minted, noop: noop)
        } catch let e as MsgPackError {
            throw CoreError.decode("\(e)")
        }
    }

    private static func throwRejection(
        rejected: MsgPackValue, map: [String: MsgPackValue]
    ) throws -> Never {
        let kind = (try? rejected.stringValue()) ?? "unknown"
        let detail = (try? map.require("detail").stringValue()) ?? ""
        let current = map["currentRev"].flatMap { try? Self.uint($0, "currentRev") } ?? 0
        throw CanvasRejection(kind: kind, detail: detail, currentRev: current)
    }

    private static func decodePatch(_ value: MsgPackValue) throws -> CanvasPatch {
        let map = try value.mapValue()
        let op = try map.require("op").stringValue()
        func s(_ key: String) throws -> String { try map.require(key).stringValue() }
        func opt(_ key: String) -> String? { map[key].flatMap { try? $0.stringValue() } }
        switch op {
        case "setText":
            return .setText(id: try s("id"), text: try s("text"))
        case "setStyle":
            return .setStyle(id: try s("id"), prop: try s("prop"), value: try s("value"))
        case "removeStyle":
            return .removeStyle(id: try s("id"), prop: try s("prop"))
        case "setAttr":
            return .setAttr(id: try s("id"), attr: try s("attr"), value: try s("value"))
        case "insertNode":
            return .insertNode(parent: try s("parent"), before: opt("before"), html: try s("html"))
        case "removeNode":
            return .removeNode(id: try s("id"))
        case "moveNode":
            return .moveNode(id: try s("id"), parent: try s("parent"), before: opt("before"))
        default:
            throw CoreError.decode("unknown patch op '\(op)'")
        }
    }

    private static func uint(_ value: MsgPackValue, _ field: String) throws -> UInt64 {
        switch value {
        case .uint(let u): return u
        case .int(let i) where i >= 0: return UInt64(i)
        default: throw CoreError.decode("field '\(field)' is not an unsigned integer")
        }
    }
}
