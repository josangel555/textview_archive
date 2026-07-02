import Foundation

// Canvas M0 spike (TSK-1353) — the versioned Swift⇄JS envelope for the canvas
// WebView, mirroring the CodeMirror bridge discipline (`CMProtocol`): one
// version constant, typed inbound/outbound enums, a pure host-testable codec.
// JSON over `window.cvDispatch` / the `mdvCanvas` script-message handler.

/// Protocol version for the canvas bridge envelope.
public enum CVProtocol {
    /// Bump when the envelope shape changes. The JS side rejects `v` greater
    /// than its own version; the Swift decoder accepts `v` in
    /// `[oldestSupportedVersion ... currentVersion]`.
    public static let currentVersion: Int = 1
    /// Oldest inbound version the Swift decoder still accepts.
    public static let oldestSupportedVersion: Int = 1
}

/// One DOM patch instruction, bridge-side (decoupled from RustCore types; the
/// adapter maps `CanvasPatch` → `CVPatch`).
public struct CVPatch: Equatable, Sendable, Codable {
    public enum Op: String, Codable, Sendable {
        case setText
        case setStyle
    }
    public let op: Op
    public let id: UInt32
    public let text: String?
    public let key: String?
    public let value: String?

    public init(op: Op, id: UInt32, text: String? = nil, key: String? = nil, value: String? = nil) {
        self.op = op
        self.id = id
        self.text = text
        self.key = key
        self.value = value
    }
}

/// A geometry box reported by the JS runtime.
public struct CVBox: Equatable, Sendable, Codable {
    public let id: UInt32
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
}

/// Swift → JS messages.
public enum CVOutboundMessage: Equatable, Sendable {
    /// Replace the root's content with the core's lowered HTML.
    case setContent(seq: UInt64, html: String)
    /// Apply a patch batch.
    case applyPatches(seq: UInt64, patches: [CVPatch])
    /// Ask for the bounding boxes of `ids`.
    case queryGeometry(replyId: UInt64, ids: [UInt32])
    /// Read back one node's text content (M0 E2E assert aid).
    case queryText(replyId: UInt64, id: UInt32)
}

/// JS → Swift messages.
public enum CVInboundMessage: Equatable, Sendable {
    case ready(tsMs: Double)
    case contentSet(seq: UInt64, nodeCount: Int, tsMs: Double)
    case applied(seq: UInt64, applied: Int, missing: [UInt32], tsMs: Double, applyMs: Double)
    case geometry(replyId: UInt64, boxes: [CVBox])
    case text(replyId: UInt64, found: Bool, text: String?)
    case error(message: String)
    /// A structurally-valid envelope whose version is newer than this build
    /// understands — surfaced, never silently dropped.
    case unsupportedVersion(v: Int)
}

/// Codec faults (decode side).
public enum CVBridgeCodecError: Error, Equatable {
    case notJSON
    case missingField(String)
    case unknownType(String)
}

/// Pure encode/decode for the envelope — no WebKit import, host-testable.
public enum CVBridgeCodec {
    /// Encode an outbound message as the compact JSON string handed to
    /// `window.cvDispatch(...)`.
    public static func encode(_ message: CVOutboundMessage) throws -> String {
        var dict: [String: Any] = ["v": CVProtocol.currentVersion]
        switch message {
        case let .setContent(seq, html):
            dict["type"] = "setContent"
            dict["seq"] = seq
            dict["html"] = html
        case let .applyPatches(seq, patches):
            dict["type"] = "applyPatches"
            dict["seq"] = seq
            dict["patches"] = patches.map { p -> [String: Any] in
                var m: [String: Any] = ["op": p.op.rawValue, "id": p.id]
                if let t = p.text { m["text"] = t }
                if let k = p.key { m["key"] = k }
                if let v = p.value { m["value"] = v }
                return m
            }
        case let .queryGeometry(replyId, ids):
            dict["type"] = "queryGeometry"
            dict["replyId"] = replyId
            dict["ids"] = ids
        case let .queryText(replyId, id):
            dict["type"] = "queryText"
            dict["replyId"] = replyId
            dict["id"] = id
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw CVBridgeCodecError.notJSON
        }
        return s
    }

    /// Decode an inbound message from the `mdvCanvas` handler's body (a JSON
    /// string, per the JS side's `post`).
    public static func decode(_ body: Any) throws -> CVInboundMessage {
        guard let json = body as? String, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else {
            throw CVBridgeCodecError.notJSON
        }
        guard let v = dict["v"] as? Int else { throw CVBridgeCodecError.missingField("v") }
        if v > CVProtocol.currentVersion { return .unsupportedVersion(v: v) }
        guard let type = dict["type"] as? String else {
            throw CVBridgeCodecError.missingField("type")
        }
        switch type {
        case "ready":
            return .ready(tsMs: double(dict["tsMs"]))
        case "contentSet":
            return .contentSet(
                seq: uint64(dict["seq"]),
                nodeCount: dict["nodeCount"] as? Int ?? 0,
                tsMs: double(dict["tsMs"])
            )
        case "applied":
            return .applied(
                seq: uint64(dict["seq"]),
                applied: dict["applied"] as? Int ?? 0,
                missing: uint32Array(dict["missing"]),
                tsMs: double(dict["tsMs"]),
                applyMs: double(dict["applyMs"])
            )
        case "geometry":
            let boxes: [CVBox] = (dict["boxes"] as? [[String: Any]] ?? []).compactMap { b in
                guard let id = b["id"] as? UInt32 ?? (b["id"] as? Int).flatMap({ UInt32(exactly: $0) })
                else { return nil }
                return CVBox(
                    id: id, x: double(b["x"]), y: double(b["y"]),
                    w: double(b["w"]), h: double(b["h"])
                )
            }
            return .geometry(replyId: uint64(dict["replyId"]), boxes: boxes)
        case "text":
            return .text(
                replyId: uint64(dict["replyId"]),
                found: dict["found"] as? Bool ?? false,
                text: dict["text"] as? String
            )
        case "error":
            return .error(message: dict["message"] as? String ?? "")
        default:
            throw CVBridgeCodecError.unknownType(type)
        }
    }

    private static func double(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return 0
    }

    private static func uint64(_ v: Any?) -> UInt64 {
        if let u = v as? UInt64 { return u }
        if let i = v as? Int, i >= 0 { return UInt64(i) }
        return 0
    }

    private static func uint32Array(_ v: Any?) -> [UInt32] {
        guard let arr = v as? [Any] else { return [] }
        return arr.compactMap {
            if let i = $0 as? Int, i >= 0 { return UInt32(exactly: i) }
            if let u = $0 as? UInt32 { return u }
            return nil
        }
    }
}
