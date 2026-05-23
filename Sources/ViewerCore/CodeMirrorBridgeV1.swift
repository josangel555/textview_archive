// CodeMirror 6 bridge — protocol v1.
//
// See `docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` §13 for the
// exhaustive spec. This file is the pure-logic kernel of Phase 1:
// versioned envelope, typed enums for both directions, Codable-driven
// JSON encode/decode. No AppKit / WebKit / UI imports — every value
// here is testable from `ViewerCoreTests` without spinning up a
// WKWebView.
//
// Envelope:
//
//     { "v": 1, "type": "<message-name>", "replyId"?: "...", ...payload }
//
// `CMInboundMessage`  ─ JS  → Swift (posted via `WKScriptMessageHandler`).
// `CMOutboundMessage` ─ Swift → JS (delivered via
//                       `window.cmDispatch({...})` in the host HTML).
//
// Forward-compatibility rules (per §13.6):
//
// - Decoder returns `nil` for malformed envelopes (missing `v`, wrong
//   shape) and `.unknown(...)` for known envelope + unknown `type` so
//   callers can log without crashing.
// - Unknown payload fields on a recognized `type` are ignored.
// - Bumping the protocol version is a flag day; v2 work will keep v1
//   decodable for one release cycle alongside.

import Foundation

// MARK: - Envelope constants

public enum CMProtocol {
    public static let currentVersion: Int = 1
}

// MARK: - Inbound (JS → Swift)

public enum CMInboundMessage: Equatable, Sendable {
    case ready(version: Int)
    case change(text: String, version: Int, contentLength: Int)
    case save
    case cursorPositionChanged(line: Int, column: Int, head: Int, ranges: Int)
    case selectionChanged(selectionJSON: String, hasSelection: Bool)
    case scrollChanged(top: Int, left: Int, viewportFromLine: Int, viewportToLine: Int)
    case findOpened(query: String)
    case findClosed
    case findResultChanged(matches: Int, current: Int)
    case linkClicked(href: String, line: Int, column: Int)
    case editorBlurred
    case errorOccurred(phase: String, message: String, stack: String?)
    case requestReply(replyId: String, valueJSON: String)
    /// Recognized envelope, unknown `type`. Surfaced so the host can
    /// log once + drop, rather than treat as a hard parse error.
    case unknown(type: String)
}

// MARK: - Outbound (Swift → JS)

public enum CMOutboundMessage: Equatable, Sendable {
    case setText(text: String, resetHistory: Bool, preserveSelection: Bool)
    case appendText(text: String)
    case replaceRange(from: Int, to: Int, insert: String, version: Int)
    case setLanguage(String)
    case setTheme(name: String)
    case setFontSize(Int)
    case setWordWrap(Bool)
    case setReadOnly(Bool)
    case setLineNumbers(Bool)
    case setShowInvisibles(Bool)
    case setIndentation(useTabs: Bool, size: Int)
    case gotoLine(line: Int, column: Int?, select: Bool)
    case setSelection(anchor: Int, head: Int, scroll: Bool)
    case openSearch(query: String?, replace: Bool)
    case closeSearch
    case findNext
    case findPrev
    case replaceNext
    case replaceAll
    case foldAll
    case unfoldAll
    case undo
    case redo
    case focus
    case flushChanges
    case getDocument(replyId: String)
    case getSelection(replyId: String)
    case getScrollPosition(replyId: String)
}

// MARK: - Codec

public enum CMBridgeCodec {

    // MARK: Decode (JS → Swift)

    /// Decode the `body` from a `WKScriptMessage`. The raw body is
    /// either a `[String: Any]` (already deserialized by WebKit) or, in
    /// tests, a `Data` carrying JSON. Returns `nil` if the envelope is
    /// malformed (no dictionary / wrong version / missing `type`).
    public static func decodeInbound(_ body: Any) -> CMInboundMessage? {
        let dict: [String: Any]
        if let d = body as? [String: Any] {
            dict = d
        } else if let data = body as? Data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        } else if let s = body as? String,
                  let data = s.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            dict = parsed
        } else {
            return nil
        }

        // Version must be present and match. Reject silently otherwise.
        guard let v = dict["v"] as? Int, v == CMProtocol.currentVersion else { return nil }
        guard let type = dict["type"] as? String else { return nil }

        switch type {
        case "ready":
            return .ready(version: v)
        case "change":
            let text = dict["text"] as? String ?? ""
            let version = dict["version"] as? Int ?? 0
            let contentLength = (dict["contentLength"] as? Int) ?? text.utf16.count
            return .change(text: text, version: version, contentLength: contentLength)
        case "save":
            return .save
        case "cursorPositionChanged":
            return .cursorPositionChanged(
                line: dict["line"] as? Int ?? 1,
                column: dict["column"] as? Int ?? 0,
                head: dict["head"] as? Int ?? 0,
                ranges: dict["ranges"] as? Int ?? 1
            )
        case "selectionChanged":
            let json: String
            if let s = dict["selection"] as? String {
                json = s
            } else if let obj = dict["selection"],
                      let data = try? JSONSerialization.data(withJSONObject: obj),
                      let s = String(data: data, encoding: .utf8) {
                json = s
            } else {
                json = "{}"
            }
            return .selectionChanged(
                selectionJSON: json,
                hasSelection: dict["hasSelection"] as? Bool ?? false
            )
        case "scrollChanged":
            return .scrollChanged(
                top: dict["top"] as? Int ?? 0,
                left: dict["left"] as? Int ?? 0,
                viewportFromLine: dict["viewportFromLine"] as? Int ?? 1,
                viewportToLine: dict["viewportToLine"] as? Int ?? 1
            )
        case "findOpened":
            return .findOpened(query: dict["query"] as? String ?? "")
        case "findClosed":
            return .findClosed
        case "findResultChanged":
            return .findResultChanged(
                matches: dict["matches"] as? Int ?? 0,
                current: dict["current"] as? Int ?? 0
            )
        case "linkClicked":
            return .linkClicked(
                href: dict["href"] as? String ?? "",
                line: dict["line"] as? Int ?? 0,
                column: dict["column"] as? Int ?? 0
            )
        case "editorBlurred":
            return .editorBlurred
        case "errorOccurred":
            return .errorOccurred(
                phase: dict["phase"] as? String ?? "unknown",
                message: dict["message"] as? String ?? "",
                stack: dict["stack"] as? String
            )
        case "requestReply":
            guard let replyId = dict["replyId"] as? String else { return nil }
            let valueJSON: String
            if let s = dict["value"] as? String {
                valueJSON = s
            } else if let obj = dict["value"],
                      let data = try? JSONSerialization.data(
                          withJSONObject: obj, options: [.fragmentsAllowed]
                      ),
                      let s = String(data: data, encoding: .utf8) {
                valueJSON = s
            } else {
                valueJSON = "null"
            }
            return .requestReply(replyId: replyId, valueJSON: valueJSON)
        default:
            return .unknown(type: type)
        }
    }

    // MARK: Encode (Swift → JS)

    /// Encode an outbound message as a JSON dictionary suitable for
    /// `JSONSerialization.data(withJSONObject:)`. Always includes the
    /// `v` envelope field. Pure value transform; no I/O.
    public static func encodeOutbound(_ msg: CMOutboundMessage) -> [String: Any] {
        var dict: [String: Any] = ["v": CMProtocol.currentVersion]
        switch msg {
        case .setText(let text, let resetHistory, let preserveSelection):
            dict["type"] = "setText"
            dict["text"] = text
            dict["resetHistory"] = resetHistory
            dict["preserveSelection"] = preserveSelection
        case .appendText(let text):
            dict["type"] = "appendText"
            dict["text"] = text
        case .replaceRange(let from, let to, let insert, let version):
            dict["type"] = "replaceRange"
            dict["from"] = from
            dict["to"] = to
            dict["insert"] = insert
            dict["version"] = version
        case .setLanguage(let lang):
            dict["type"] = "setLanguage"
            dict["lang"] = lang
        case .setTheme(let name):
            dict["type"] = "setTheme"
            dict["name"] = name
        case .setFontSize(let px):
            dict["type"] = "setFontSize"
            dict["px"] = px
        case .setWordWrap(let enabled):
            dict["type"] = "setWordWrap"
            dict["enabled"] = enabled
        case .setReadOnly(let enabled):
            dict["type"] = "setReadOnly"
            dict["enabled"] = enabled
        case .setLineNumbers(let enabled):
            dict["type"] = "setLineNumbers"
            dict["enabled"] = enabled
        case .setShowInvisibles(let enabled):
            dict["type"] = "setShowInvisibles"
            dict["enabled"] = enabled
        case .setIndentation(let useTabs, let size):
            dict["type"] = "setIndentation"
            dict["useTabs"] = useTabs
            dict["size"] = size
        case .gotoLine(let line, let column, let select):
            dict["type"] = "gotoLine"
            dict["line"] = line
            if let column = column { dict["column"] = column }
            dict["select"] = select
        case .setSelection(let anchor, let head, let scroll):
            dict["type"] = "setSelection"
            dict["anchor"] = anchor
            dict["head"] = head
            dict["scroll"] = scroll
        case .openSearch(let query, let replace):
            dict["type"] = "openSearch"
            if let query = query { dict["query"] = query }
            dict["replace"] = replace
        case .closeSearch:    dict["type"] = "closeSearch"
        case .findNext:       dict["type"] = "findNext"
        case .findPrev:       dict["type"] = "findPrev"
        case .replaceNext:    dict["type"] = "replaceNext"
        case .replaceAll:     dict["type"] = "replaceAll"
        case .foldAll:        dict["type"] = "foldAll"
        case .unfoldAll:      dict["type"] = "unfoldAll"
        case .undo:           dict["type"] = "undo"
        case .redo:           dict["type"] = "redo"
        case .focus:          dict["type"] = "focus"
        case .flushChanges:   dict["type"] = "flushChanges"
        case .getDocument(let replyId):
            dict["type"] = "getDocument"
            dict["replyId"] = replyId
        case .getSelection(let replyId):
            dict["type"] = "getSelection"
            dict["replyId"] = replyId
        case .getScrollPosition(let replyId):
            dict["type"] = "getScrollPosition"
            dict["replyId"] = replyId
        }
        return dict
    }

    /// Encode to a UTF-8 JSON string. Stable ordering not guaranteed —
    /// callers that need a deterministic textual form (tests, hashing)
    /// should sort keys themselves.
    public static func encodeOutboundJSON(_ msg: CMOutboundMessage) -> String {
        let obj = encodeOutbound(msg)
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys]
        ),
        let str = String(data: data, encoding: .utf8) else {
            return "{\"v\":\(CMProtocol.currentVersion),\"type\":\"errorEncoding\"}"
        }
        return str
    }
}
