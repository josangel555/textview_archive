// CodeMirror 6 bridge — versioned wire protocol (currently v1 + v2).
//
// Renamed from `CodeMirrorBridgeV1.swift`: the file was named for
// Phase 1 but now carries both protocol versions (v2 added the
// incremental-edit / fold / gutter / indent-guide messages), so the
// `V1` suffix mis-described its scope. The *file* is version-agnostic;
// `CMProtocol.currentVersion` is the single source of truth for what
// Swift speaks.
//
// See `docs/CM6_INTEGRATION_DESIGN_2026-05-23.md` §13 for the
// exhaustive spec. This is the pure-logic kernel: versioned envelope,
// typed enums for both directions, Codable-driven JSON encode/decode.
// No AppKit / WebKit / UI imports — every value here is testable from
// `ViewerCoreTests` without spinning up a WKWebView.
//
// Envelope:
//
//     { "v": <n>, "type": "<message-name>", "replyId"?: "...", ...payload }
//
// `CMInboundMessage`  ─ JS  → Swift (posted via `WKScriptMessageHandler`).
// `CMOutboundMessage` ─ Swift → JS (delivered via
//                       `window.cmDispatch({...})` in the host HTML).
//
// Forward/backward-compatibility rules (per §13.6):
//
// - Decoder returns `nil` for malformed envelopes (missing `v`,
//   too-old `v`, missing `type`, wrong shape), `.unsupportedVersion`
//   for a well-formed envelope whose `v` is NEWER than this binary
//   (so the host can log + downgrade rather than silently drop), and
//   `.unknown(...)` for a known envelope + unknown `type`.
// - Unknown payload fields on a recognized `type` are ignored.
// - Outbound encoding negotiates `v` down to the peer's version and
//   REFUSES to encode a message the peer's version can't handle
//   (see `encodeOutbound(_:peerVersion:)` + `minimumVersion`).
// - The decoder accepts `[oldestSupportedVersion ... currentVersion]`
//   so a freshly-bumped binary keeps talking to a stale JS bundle (and
//   vice versa) for one release cycle.

import Foundation

// MARK: - Envelope constants

public enum CMProtocol {
    /// The wire version Swift writes and the lowest version Swift
    /// requires JS to speak. Bumped to **2** in Phase 4 to introduce
    /// `incrementalChange` (JS → Swift) and `applyEdits`
    /// (Swift → JS) — both opt-in and forward-compatible.
    ///
    /// Forward-compat policy: the decoder accepts envelopes with
    /// `v == currentVersion` **or** `v == currentVersion - 1`, so a
    /// pre-v2 JS bundle still parses while users wait for an in-place
    /// app update to refresh `Resources/codemirror/`. Anything older /
    /// newer is dropped.
    public static let currentVersion: Int = 2
    public static let oldestSupportedVersion: Int = 1
}

// MARK: - Inbound (JS → Swift)

/// One incremental edit as emitted by CM6's
/// `tr.changes.iterChangedRanges(...)` and accumulated across the
/// 200 ms debounce window. `from`/`to` are doc offsets (UTF-16)
/// **before** the edit; `insert` is the text that replaces the range.
/// A pure delete is `insert: ""`; a pure insert is `from == to`.
public struct CMEdit: Equatable, Sendable, Hashable {
    public let from: Int
    public let to: Int
    public let insert: String
    public init(from: Int, to: Int, insert: String) {
        self.from = from; self.to = to; self.insert = insert
    }
}

/// One block-foldable region. `from`/`to` are CM6 doc offsets (UTF-16);
/// `kind` is the LSP `FoldingRangeKind` ("comment" | "imports" |
/// "region" | nil). JS side ignores `kind` today but we ship it so the
/// fold service can colour-code or default-collapse later.
public struct CMFoldRange: Equatable, Sendable, Hashable {
    public let from: Int
    public let to: Int
    public let kind: String?
    public init(from: Int, to: Int, kind: String? = nil) {
        self.from = from; self.to = to; self.kind = kind
    }
}

/// One gutter marker for a single line. Used for diff bars
/// (added/modified/removed) and git-blame swatches. `line` is 1-based
/// (matches `CMCursorPosition`). `kind` is opaque to the codec — the
/// JS side maps "added"|"removed"|"modified"|"blame" to CSS classes.
/// `tooltip` is optional hover text.
public struct CMGutterMarker: Equatable, Sendable, Hashable {
    public let line: Int
    public let kind: String
    public let tooltip: String?
    public init(line: Int, kind: String, tooltip: String? = nil) {
        self.line = line; self.kind = kind; self.tooltip = tooltip
    }
}

public enum CMInboundMessage: Equatable, Sendable {
    case ready(version: Int)
    case change(text: String, version: Int, contentLength: Int)
    /// **v2.** Incremental edit stream — sent in place of `change`
    /// when the JS bundle was built with the v2 emitter. Carries the
    /// accumulated change ranges since the last `change`/`incrementalChange`,
    /// plus a `contentLength` for cheap sanity-check on the Swift
    /// side. Swift may still fall back to a full `change` if the
    /// applied buffer's length ≠ `contentLength` (drift detected).
    case incrementalChange(edits: [CMEdit], version: Int, contentLength: Int)
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
    /// JS → Swift hover request. Carries the doc-offset pos (UTF-16) and
    /// a replyId so Swift can route the asynchronously-resolved hover
    /// markup back via `.hoverResponse(...)`. Triggered by CM6's
    /// `hoverTooltip` callback in `codemirror.html`.
    case requestHover(pos: Int, line: Int, character: Int, replyId: String)
    /// JS → Swift Cmd-click definition request. Same coords as hover,
    /// no reply needed (Swift opens the target tab natively).
    case requestDefinition(pos: Int, line: Int, character: Int)
    /// JS → Swift right-click. JS has already preventDefault'd the
    /// browser menu; Swift pops a native NSMenu at the screen point.
    /// `selection` is the current selection text (empty when none) so
    /// Swift can branch items on token shape.
    case contextMenuRequested(
        pos: Int, line: Int, character: Int,
        screenX: Double, screenY: Double,
        selection: String,
        hasSelection: Bool
    )
    /// Recognized envelope, unknown `type`. Surfaced so the host can
    /// log once + drop, rather than treat as a hard parse error.
    case unknown(type: String)
    /// Well-formed envelope whose `v` is **newer** than this binary
    /// understands (`v > CMProtocol.currentVersion`). Distinct from a
    /// malformed-envelope `nil` so the host can log "peer is speaking a
    /// future protocol; please update" instead of silently dropping —
    /// and so the bridge can downgrade subsequent *outbound* traffic to
    /// the peer's floor. Carries the offending version. (API-08.)
    case unsupportedVersion(Int)
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
    /// Set the active find-bar query. Re-issued after every keystroke
    /// in the SwiftUI find bar (debounced upstream) so CM's
    /// `SearchQuery` matches what the user typed. `caseSensitive` /
    /// `isRegex` are passed through to CM's matcher.
    case setSearchQuery(query: String, caseSensitive: Bool, regex: Bool)
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
    /// Replace the inline-diagnostic decoration set. Empty array clears.
    /// CM6's `@codemirror/lint` linter source pulls from a StateField
    /// fed by this effect; squiggles + lint gutter both react.
    case setDiagnostics([CMDiagnostic])
    case getDocument(replyId: String)
    case getSelection(replyId: String)
    case getScrollPosition(replyId: String)
    /// Resolve a pending JS-side `hoverTooltip` callback. `markdown` is
    /// the formatted hover body (CM6 renders it via its own minimal
    /// renderer — currently we ship it as plain text after stripping
    /// our LSP markdown wrapper). Empty contents → tooltip dismissed.
    case hoverResponse(replyId: String, contents: String, from: Int, to: Int)
    /// Enable / disable save-on-blur. JS side already always posts
    /// `editorBlurred`; this gates whether Swift acts on it. Wired here
    /// for symmetry with other compartment toggles.
    case setSaveOnBlur(enabled: Bool)
    /// **v2.** Apply a list of incremental edits without going through
    /// `setText`. Reciprocal to `incrementalChange` (inbound). Each
    /// edit references the pre-edit `from`/`to`; the JS side dispatches
    /// them as a single transaction so undo collapses to one step.
    /// `version` lets JS drop stale edits if its doc has moved on.
    case applyEdits(edits: [CMEdit], version: Int)
    /// **v2.** Push a server-provided fold range set. Wired to a
    /// `foldService.of(...)` extension on the JS side so CM6's fold
    /// gutter and `foldAll` operate on LSP-computed ranges. Empty
    /// array clears the override (falls back to language-default
    /// fold heuristics).
    case setFoldingRanges([CMFoldRange])
    /// **v2.** Push a server-provided per-line gutter marker set.
    /// Drives diff bars (added/modified/removed) and git-blame
    /// swatches. Empty array clears all markers.
    case setGutterMarkers([CMGutterMarker])
    /// **v2.** Toggle indent guides — the hand-rolled
    /// `ViewPlugin` that draws vertical rules at each indent level.
    /// Pure decoration; no language dependency.
    case setIndentGuides(Bool)

    /// The lowest protocol version in which this message's `type` exists
    /// on the JS side. Outbound encoding consults this against the
    /// peer's negotiated version: a v2-only message must NOT be sent to
    /// a v1 peer (the JS dispatch switch has no handler for it and would
    /// post an `errorOccurred`, or worse, silently no-op a state push
    /// the host believes landed). (API-06/07.)
    ///
    /// Keep this in lock-step with the `case` arms `codemirror.html`'s
    /// `cmDispatch` switch handles per version. New v2 message types are
    /// listed explicitly; everything else is v1.
    public var minimumVersion: Int {
        switch self {
        case .applyEdits, .setFoldingRanges, .setGutterMarkers, .setIndentGuides:
            return 2
        default:
            return 1
        }
    }
}

/// One inline-diagnostic decoration in CM6 doc coordinates (UTF-16
/// offsets — what `EditorState.doc.lineAt` / `line.from + col` produce).
/// Translated from `LSPDiagnostic`'s `(line, character)` ranges via
/// the doc text (see `CMDiagnosticMapping`).
public struct CMDiagnostic: Equatable, Sendable, Hashable {
    public enum Severity: String, Sendable, Hashable {
        case error, warning, info, hint
    }
    public let from: Int
    public let to: Int
    public let severity: Severity
    public let message: String
    public let source: String?
    public let code: String?
    public init(
        from: Int, to: Int, severity: Severity,
        message: String, source: String? = nil, code: String? = nil
    ) {
        self.from = from; self.to = to
        self.severity = severity; self.message = message
        self.source = source; self.code = code
    }
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

        // Version must be present. We accept
        // `[oldestSupportedVersion ... currentVersion]` so a freshly-
        // bumped Swift binary can still talk to a not-yet-rebundled JS
        // payload (or vice versa during dev hot-reload).
        guard let v = dict["v"] as? Int else { return nil }
        // Too-OLD envelopes are a hard drop — we no longer speak that
        // dialect and can't trust the field layout. Missing `type` is
        // also a hard drop (can't even classify).
        guard v >= CMProtocol.oldestSupportedVersion else { return nil }
        // Too-NEW envelopes (peer speaks a future protocol) are
        // surfaced as `.unsupportedVersion` rather than dropped: the
        // host logs an actionable "please update" and the bridge can
        // pin outbound traffic to the peer's floor. We still require a
        // `type` to have been a well-formed envelope at all. (API-08.)
        guard v <= CMProtocol.currentVersion else {
            return .unsupportedVersion(v)
        }
        guard let type = dict["type"] as? String else { return nil }

        switch type {
        case "ready":
            return .ready(version: v)
        case "change":
            let text = dict["text"] as? String ?? ""
            let version = dict["version"] as? Int ?? 0
            let contentLength = (dict["contentLength"] as? Int) ?? text.utf16.count
            return .change(text: text, version: version, contentLength: contentLength)
        case "incrementalChange":
            // v2 — list of `{from, to, insert}`. Drop the whole envelope
            // if `edits` isn't an array; partial drops would silently
            // diverge the Swift buffer from JS.
            guard let arr = dict["edits"] as? [[String: Any]] else { return nil }
            var out: [CMEdit] = []
            out.reserveCapacity(arr.count)
            for item in arr {
                let from = item["from"] as? Int ?? -1
                let to = item["to"] as? Int ?? -1
                let insert = item["insert"] as? String ?? ""
                guard from >= 0, to >= from else { return nil }
                out.append(CMEdit(from: from, to: to, insert: insert))
            }
            let version = dict["version"] as? Int ?? 0
            let contentLength = dict["contentLength"] as? Int ?? -1
            return .incrementalChange(
                edits: out, version: version, contentLength: contentLength)
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
        case "requestHover":
            guard let replyId = dict["replyId"] as? String else { return nil }
            return .requestHover(
                pos: dict["pos"] as? Int ?? 0,
                line: dict["line"] as? Int ?? 1,
                character: dict["character"] as? Int ?? 0,
                replyId: replyId
            )
        case "requestDefinition":
            return .requestDefinition(
                pos: dict["pos"] as? Int ?? 0,
                line: dict["line"] as? Int ?? 1,
                character: dict["character"] as? Int ?? 0
            )
        case "contextMenuRequested":
            let pos = dict["pos"] as? Int ?? 0
            let line = dict["line"] as? Int ?? 1
            let character = dict["character"] as? Int ?? 0
            let sx: Double = (dict["screenX"] as? Double)
                ?? Double(dict["screenX"] as? Int ?? 0)
            let sy: Double = (dict["screenY"] as? Double)
                ?? Double(dict["screenY"] as? Int ?? 0)
            let sel = dict["selection"] as? String ?? ""
            let hasSel = dict["hasSelection"] as? Bool ?? false
            return .contextMenuRequested(
                pos: pos, line: line, character: character,
                screenX: sx, screenY: sy,
                selection: sel, hasSelection: hasSel
            )
        default:
            return .unknown(type: type)
        }
    }

    // MARK: Encode (Swift → JS)

    /// Encode an outbound message as a JSON dictionary suitable for
    /// `JSONSerialization.data(withJSONObject:)`. Always includes the
    /// `v` envelope field, stamped with `CMProtocol.currentVersion`.
    /// Pure value transform; no I/O.
    ///
    /// This convenience assumes the peer speaks the current version. To
    /// down-encode for a peer pinned to an older version (and to refuse
    /// messages the peer can't handle), use
    /// `encodeOutbound(_:peerVersion:)`.
    public static func encodeOutbound(_ msg: CMOutboundMessage) -> [String: Any] {
        // Safe to force-unwrap: passing `currentVersion` as the peer can
        // never refuse (every message's minimumVersion <= currentVersion).
        return encodeOutbound(msg, peerVersion: CMProtocol.currentVersion)!
    }

    /// Encode an outbound message, negotiating the envelope `v` down to
    /// the peer's version. Stamps `v = min(currentVersion, peerVersion)`
    /// so a Swift binary that's been bumped ahead of the JS bundle keeps
    /// talking the bundle's dialect instead of stamping a `v` the JS
    /// `cmDispatch` guard rejects outright. (API-06.)
    ///
    /// Returns `nil` — refusing to encode — when `msg.minimumVersion`
    /// exceeds `peerVersion`: a v2-only message (e.g. `setGutterMarkers`)
    /// has no handler in a v1 JS bundle, so shipping it stamped `v:1`
    /// would land as an `unknown message type` error and the host would
    /// wrongly believe the state push succeeded. The caller must treat
    /// `nil` as "peer too old for this feature; skip / fall back".
    /// (API-07.)
    public static func encodeOutbound(
        _ msg: CMOutboundMessage, peerVersion: Int
    ) -> [String: Any]? {
        guard msg.minimumVersion <= peerVersion else { return nil }
        let wireVersion = min(CMProtocol.currentVersion, peerVersion)
        var dict: [String: Any] = ["v": wireVersion]
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
        case .setSearchQuery(let query, let caseSensitive, let regex):
            dict["type"] = "setSearchQuery"
            dict["query"] = query
            dict["caseSensitive"] = caseSensitive
            dict["regex"] = regex
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
        case .setDiagnostics(let diags):
            dict["type"] = "setDiagnostics"
            dict["diagnostics"] = diags.map { d -> [String: Any] in
                var o: [String: Any] = [
                    "from": d.from, "to": d.to,
                    "severity": d.severity.rawValue,
                    "message": d.message,
                ]
                if let s = d.source { o["source"] = s }
                if let c = d.code { o["code"] = c }
                return o
            }
        case .getDocument(let replyId):
            dict["type"] = "getDocument"
            dict["replyId"] = replyId
        case .getSelection(let replyId):
            dict["type"] = "getSelection"
            dict["replyId"] = replyId
        case .getScrollPosition(let replyId):
            dict["type"] = "getScrollPosition"
            dict["replyId"] = replyId
        case .hoverResponse(let replyId, let contents, let from, let to):
            dict["type"] = "hoverResponse"
            dict["replyId"] = replyId
            dict["contents"] = contents
            dict["from"] = from
            dict["to"] = to
        case .setSaveOnBlur(let enabled):
            dict["type"] = "setSaveOnBlur"
            dict["enabled"] = enabled
        case .applyEdits(let edits, let version):
            dict["type"] = "applyEdits"
            dict["version"] = version
            dict["edits"] = edits.map { e -> [String: Any] in
                ["from": e.from, "to": e.to, "insert": e.insert]
            }
        case .setFoldingRanges(let ranges):
            dict["type"] = "setFoldingRanges"
            dict["ranges"] = ranges.map { r -> [String: Any] in
                var o: [String: Any] = ["from": r.from, "to": r.to]
                if let k = r.kind { o["kind"] = k }
                return o
            }
        case .setGutterMarkers(let markers):
            dict["type"] = "setGutterMarkers"
            dict["markers"] = markers.map { m -> [String: Any] in
                var o: [String: Any] = ["line": m.line, "kind": m.kind]
                if let t = m.tooltip { o["tooltip"] = t }
                return o
            }
        case .setIndentGuides(let enabled):
            dict["type"] = "setIndentGuides"
            dict["enabled"] = enabled
        }
        return dict
    }

    /// Encode to a UTF-8 JSON string. Stable ordering not guaranteed —
    /// callers that need a deterministic textual form (tests, hashing)
    /// should sort keys themselves.
    ///
    /// The output is safe to embed inside a JS source-text literal
    /// produced via string interpolation (e.g.
    /// `"window.cmDispatch(\(json))"`). `JSONSerialization` does not
    /// escape U+2028 / U+2029, which are valid in JSON strings but
    /// are line terminators in JavaScript source — embedding them
    /// raw breaks the surrounding script. We post-process to escape
    /// both via `JSStringEmbedding.sanitize`.
    public static func encodeOutboundJSON(_ msg: CMOutboundMessage) -> String {
        return encodeOutboundJSON(msg, peerVersion: CMProtocol.currentVersion) ?? fallbackEncodingError
    }

    /// Peer-aware JSON encode. Returns `nil` when the message can't be
    /// represented for `peerVersion` (a v2-only message to a v1 peer) so
    /// the caller skips the `evaluateJavaScript` entirely rather than
    /// shipping a payload the peer will reject. (API-06/07.)
    public static func encodeOutboundJSON(
        _ msg: CMOutboundMessage, peerVersion: Int
    ) -> String? {
        guard let obj = encodeOutbound(msg, peerVersion: peerVersion) else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys]
        ),
        let str = String(data: data, encoding: .utf8) else {
            return fallbackEncodingError
        }
        return JSStringEmbedding.sanitize(str)
    }

    private static let fallbackEncodingError =
        "{\"v\":\(CMProtocol.currentVersion),\"type\":\"errorEncoding\"}"
}
