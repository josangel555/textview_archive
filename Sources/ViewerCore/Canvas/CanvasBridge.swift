import Foundation

// Canvas M1.S5c (TSK-1360) — the versioned Swift⇄JS envelope for the canvas
// WebView, now speaking the REAL engine's vocabulary: string record ids and
// the 7 applier verbs (setText/setStyle/removeStyle/setAttr/insertNode/
// removeNode/moveNode). Mirrors the CodeMirror bridge discipline (versioned
// envelope, pure host-testable codec). The M0 numeric-id two-verb shape lived
// here through commit c275fbd8.

/// Protocol version for the canvas bridge envelope.
public enum CVProtocol {
    public static let currentVersion: Int = 1
    public static let oldestSupportedVersion: Int = 1
}

/// One applier instruction (bridge vocabulary — the engine's patch verbs).
public enum CVPatchInstruction: Equatable, Sendable {
    case setText(id: String, text: String)
    case setStyle(id: String, prop: String, value: String)
    case removeStyle(id: String, prop: String)
    case setAttr(id: String, attr: String, value: String)
    case insertNode(parent: String, before: String?, html: String)
    case removeNode(id: String)
    case moveNode(id: String, parent: String, before: String?)

    /// The JSON dictionary the JS applier consumes.
    var jsonObject: [String: Any] {
        switch self {
        case let .setText(id, text):
            return ["op": "setText", "id": id, "text": text]
        case let .setStyle(id, prop, value):
            return ["op": "setStyle", "id": id, "prop": prop, "value": value]
        case let .removeStyle(id, prop):
            return ["op": "removeStyle", "id": id, "prop": prop]
        case let .setAttr(id, attr, value):
            return ["op": "setAttr", "id": id, "attr": attr, "value": value]
        case let .insertNode(parent, before, html):
            var d: [String: Any] = ["op": "insertNode", "parent": parent, "html": html]
            if let before { d["before"] = before }
            return d
        case let .removeNode(id):
            return ["op": "removeNode", "id": id]
        case let .moveNode(id, parent, before):
            var d: [String: Any] = ["op": "moveNode", "id": id, "parent": parent]
            if let before { d["before"] = before }
            return d
        }
    }
}

/// A geometry box reported by the JS runtime.
public struct CVBox: Equatable, Sendable {
    public let id: String
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double

    public init(id: String, x: Double, y: Double, w: Double, h: Double) {
        self.id = id
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Swift → JS messages.
public enum CVOutboundMessage: Sendable {
    /// Replace the root's content with the engine's full lowering.
    case setContent(seq: UInt64, html: String)
    /// Apply a patch batch.
    case applyPatches(seq: UInt64, patches: [CVPatchInstruction])
    /// Ask for bounding boxes.
    case queryGeometry(replyId: UInt64, ids: [String])
    /// Read back one node's text content (E2E assert aid).
    case queryText(replyId: UInt64, id: String)
    // M3.S2 (TSK-1373) — WYSIWYG selection/edit commands (v1-additive):
    /// Show the selection overlay on `ids` (empty = clear).
    case setSelection(ids: [String])
    /// Clear the selection overlay.
    case clearSelection
    /// Toggle contenteditable on a text node (inline editing).
    case setEditable(id: String, on: Bool)
}

/// JS → Swift messages.
public enum CVInboundMessage: Equatable, Sendable {
    case ready(tsMs: Double)
    case contentSet(seq: UInt64, nodeCount: Int, tsMs: Double)
    case applied(seq: UInt64, applied: Int, missing: [String], tsMs: Double, applyMs: Double)
    case geometry(replyId: UInt64, boxes: [CVBox])
    case text(replyId: UInt64, found: Bool, text: String?)
    case error(message: String)
    case unsupportedVersion(v: Int)
    // M3.S2 (TSK-1373) — WYSIWYG edit intents (v1-additive):
    /// A node was clicked (hit-test result; modifiers for multi-select later).
    case nodeClicked(id: String, shift: Bool)
    /// An inline text edit committed.
    case textEdited(id: String, text: String)
    /// A drag ended over a drop slot: re-place `id` under `parent` before
    /// `beforeId` (nil = append).
    case dragEnded(id: String, parent: String, beforeId: String?)
    /// Escape pressed (clear selection / cancel edit).
    case escapePressed
}

/// Codec faults (decode side).
public enum CVBridgeCodecError: Error, Equatable {
    case notJSON
    case missingField(String)
    case unknownType(String)
}

/// Pure encode/decode for the envelope — no WebKit import, host-testable.
public enum CVBridgeCodec {
    /// Encode an outbound message as the JSON object literal handed to
    /// `window.cvDispatch({...})` (the CM6 production shape — object literal,
    /// never a quoted string; LESSONS 2026-07-02).
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
            dict["patches"] = patches.map(\.jsonObject)
        case let .queryGeometry(replyId, ids):
            dict["type"] = "queryGeometry"
            dict["replyId"] = replyId
            dict["ids"] = ids
        case let .queryText(replyId, id):
            dict["type"] = "queryText"
            dict["replyId"] = replyId
            dict["id"] = id
        case let .setSelection(ids):
            dict["type"] = "setSelection"
            dict["ids"] = ids
        case .clearSelection:
            dict["type"] = "clearSelection"
        case let .setEditable(id, on):
            dict["type"] = "setEditable"
            dict["id"] = id
            dict["on"] = on
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else {
            throw CVBridgeCodecError.notJSON
        }
        return s
    }

    /// Decode an inbound message from the `mdvCanvas` handler's body.
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
                missing: dict["missing"] as? [String] ?? [],
                tsMs: double(dict["tsMs"]),
                applyMs: double(dict["applyMs"])
            )
        case "geometry":
            let boxes: [CVBox] = (dict["boxes"] as? [[String: Any]] ?? []).compactMap { b in
                guard let id = b["id"] as? String else { return nil }
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
        case "nodeClicked":
            guard let id = dict["id"] as? String else {
                throw CVBridgeCodecError.missingField("id")
            }
            return .nodeClicked(id: id, shift: dict["shift"] as? Bool ?? false)
        case "textEdited":
            guard let id = dict["id"] as? String, let text = dict["text"] as? String else {
                throw CVBridgeCodecError.missingField("id/text")
            }
            return .textEdited(id: id, text: text)
        case "dragEnded":
            guard let id = dict["id"] as? String, let parent = dict["parent"] as? String else {
                throw CVBridgeCodecError.missingField("id/parent")
            }
            return .dragEnded(id: id, parent: parent, beforeId: dict["beforeId"] as? String)
        case "escapePressed":
            return .escapePressed
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
}
