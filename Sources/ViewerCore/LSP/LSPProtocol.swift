import Foundation

// Vendored subset of LSP 3.17 type definitions. Why subset, not the
// full `ChimeHQ/LanguageServerProtocol` package? See LSP_DESIGN.md
// §1.7. PoC scope: only the types we actually serialize / decode.
//
// All types are `Sendable` value types — they cross actor boundaries
// in `LSPClient`. JSON-RPC IDs use a small ad-hoc enum because the
// spec lets servers echo either a string or a number; we always send
// numbers but must tolerate either on the inbound path.

public struct LSPPosition: Codable, Hashable, Sendable {
    public let line: Int      // 0-indexed
    public let character: Int // 0-indexed UTF-16 code units (spec default)
    public init(line: Int, character: Int) {
        self.line = line; self.character = character
    }
}

public struct LSPRange: Codable, Hashable, Sendable {
    public let start: LSPPosition
    public let end: LSPPosition
    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start; self.end = end
    }
}

public struct LSPLocation: Codable, Hashable, Sendable {
    public let uri: String
    public let range: LSPRange
    public init(uri: String, range: LSPRange) {
        self.uri = uri; self.range = range
    }
}

/// `textDocument/foldingRange` result entry. Per LSP 3.17 §16.18,
/// positions are line-based — `startCharacter` / `endCharacter` are
/// optional (servers may omit them when the whole line is included).
/// `kind` is one of "comment" | "imports" | "region"; servers may
/// invent additional kinds — we keep it as a raw string.
public struct LSPFoldingRange: Codable, Hashable, Sendable {
    public let startLine: Int       // 0-indexed
    public let endLine: Int         // 0-indexed, inclusive
    public let startCharacter: Int?
    public let endCharacter: Int?
    public let kind: String?
    public init(
        startLine: Int, endLine: Int,
        startCharacter: Int? = nil, endCharacter: Int? = nil,
        kind: String? = nil
    ) {
        self.startLine = startLine; self.endLine = endLine
        self.startCharacter = startCharacter; self.endCharacter = endCharacter
        self.kind = kind
    }
}

/// `textDocument/definition` may return a single Location, an array of
/// Locations, or an array of LocationLinks. We accept all shapes and
/// normalize to `[LSPLocation]` at the decode boundary.
public struct LSPLocationLink: Codable, Sendable {
    public let targetUri: String
    public let targetRange: LSPRange
    public let targetSelectionRange: LSPRange
}

/// `hover.contents` is the LSP spec's worst polymorphic union: it can
/// be a string, a `{language, value}` MarkedString, a
/// `{kind, value}` MarkupContent, or an array of any of those.
///
/// Decode-order discipline (the bug that ate half a day on the PoC):
/// MarkedString `{language, value}` MUST be checked **before**
/// MarkupContent `{kind, value}`. Both expose a `value` key; if you
/// fall into the MarkupContent branch first you silently drop the
/// `language` fencing and render Swift source as plain prose. See
/// LSP_DESIGN.md for the canonical decode-order rule.
public struct LSPHover: Sendable {
    public let contents: String   // pre-flattened to a markdown/plaintext blob
    public let isMarkdown: Bool
    public let range: LSPRange?

    public init(contents: String, isMarkdown: Bool, range: LSPRange?) {
        self.contents = contents
        self.isMarkdown = isMarkdown
        self.range = range
    }
}

/// LSP position encodings. Spec default is utf-16 (per LSP 3.16+);
/// utf-8 and utf-32 require client+server to both advertise support.
/// We always advertise all three so the server gets to pick. The
/// chosen value drives `LSPPositionConverter` translation at the
/// boundary — see that file for the conversion table.
public enum LSPPositionEncoding: String, Sendable, Codable {
    case utf16 = "utf-16"
    case utf8 = "utf-8"
    case utf32 = "utf-32"
}

/// SymbolKind values from LSP 3.17. We map unrecognized ones to
/// `.other` rather than failing — servers occasionally ship private
/// extensions to this enum, and outline rendering can fall back to a
/// generic icon. Numbering is stable across spec versions.
public enum LSPSymbolKind: Int, Sendable, Codable {
    case file = 1
    case module = 2
    case namespace = 3
    case package = 4
    case `class` = 5
    case method = 6
    case property = 7
    case field = 8
    case constructor = 9
    case `enum` = 10
    case interface = 11
    case function = 12
    case variable = 13
    case constant = 14
    case string = 15
    case number = 16
    case boolean = 17
    case array = 18
    case object = 19
    case key = 20
    case null = 21
    case enumMember = 22
    case `struct` = 23
    case event = 24
    case `operator` = 25
    case typeParameter = 26
    /// Catch-all for server-vendored kinds.
    case other = 0
}

/// `textDocument/documentSymbol` normalized to the modern hierarchical
/// shape. Legacy `SymbolInformation` is flattened: `uri` is populated
/// for that case (server tells us the file), `children` empty. Modern
/// `DocumentSymbol` returns positions relative to the requested URI,
/// so `uri` is nil and `children` nests the hierarchy.
public struct LSPDocumentSymbol: Sendable, Hashable {
    public let name: String
    public let detail: String?
    public let kind: LSPSymbolKind
    public let range: LSPRange
    public let selectionRange: LSPRange
    public let children: [LSPDocumentSymbol]
    public let uri: String?

    public init(
        name: String, detail: String?, kind: LSPSymbolKind,
        range: LSPRange, selectionRange: LSPRange,
        children: [LSPDocumentSymbol], uri: String?
    ) {
        self.name = name
        self.detail = detail
        self.kind = kind
        self.range = range
        self.selectionRange = selectionRange
        self.children = children
        self.uri = uri
    }
}

/// `workspace/symbol` response item. Two on-the-wire shapes per LSP
/// 3.17:
///   - Legacy `SymbolInformation`: full `location: {uri, range}`,
///     optional `containerName`.
///   - Modern `WorkspaceSymbol`: `location` may be either a full
///     Location or a URI-only stub (the server promises a follow-up
///     `workspaceSymbol/resolve`). v1 ignores resolve — we only accept
///     full-Location shapes; pyright + sourcekit-lsp both deliver these.
///
/// Decode normalizes to a single value type with optional fields.
public struct LSPWorkspaceSymbol: Sendable, Hashable {
    public let name: String
    public let kind: LSPSymbolKind
    public let containerName: String?
    public let location: LSPLocation

    public init(
        name: String, kind: LSPSymbolKind,
        containerName: String?, location: LSPLocation
    ) {
        self.name = name
        self.kind = kind
        self.containerName = containerName
        self.location = location
    }
}

/// `textDocument/publishDiagnostics` payload. Decoded eagerly in the
/// LSPClient reader and forwarded to the @MainActor LSPDiagnosticsStore
/// via the per-(client) callback registered by LSPPool.
public struct LSPDiagnostic: Sendable, Hashable {
    public enum Severity: Int, Sendable, Codable {
        case error = 1
        case warning = 2
        case information = 3
        case hint = 4
    }

    public let range: LSPRange
    public let severity: Severity
    public let code: String?
    public let source: String?
    public let message: String

    public init(
        range: LSPRange, severity: Severity,
        code: String?, source: String?, message: String
    ) {
        self.range = range
        self.severity = severity
        self.code = code
        self.source = source
        self.message = message
    }
}

/// Per-request cancellation handle. Caller constructs one before
/// issuing a request; `client.hover(..., token: token)` binds the
/// token to the JSON-RPC id internally. Calling `cancel()` from
/// another task sends `$/cancelRequest` and resumes the local awaiter
/// with `CancellationError`.
///
/// Tokens are single-use; rebind is a no-op. `cancel()` is safe to
/// call before bind — it marks the token as cancelled and the binder
/// fires immediately upon bind.
///
/// **Single-request only.** A token binds to exactly one `(id, owner)`
/// pair — the first request that binds it wins; later binds are no-ops.
/// Do NOT share one token across a fan-out (e.g. `LSPPool.workspaceSymbol`
/// over N clients): `cancel()` would only reach the first client's
/// request, leaving the rest running. Mint a fresh token per request, or
/// rely on structured-concurrency cancellation (`Task.checkCancellation`)
/// between requests.
public final class LSPCancellationToken: @unchecked Sendable {

    private let lock = NSLock()
    private var boundID: Int64?
    private var owner: LSPClient?
    private var didCancel = false

    public init() {}

    /// Whether `cancel()` has been called. Lets a fan-out caller
    /// (e.g. `LSPPool.workspaceSymbol`) mirror a pre-cancelled shared
    /// token onto the per-client tokens it mints. Lock-guarded read.
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didCancel
    }

    /// Internal: invoked by `LSPClient.request(...)`.
    func bind(id: Int64, owner: LSPClient) {
        lock.lock()
        let shouldFireImmediately = didCancel
        if boundID == nil {
            boundID = id
            self.owner = owner
        }
        lock.unlock()
        if shouldFireImmediately {
            Task { [owner] in await owner.cancelRequestPublic(id: id) }
        }
    }

    public func cancel() {
        lock.lock()
        didCancel = true
        let id = boundID
        let owner = self.owner
        lock.unlock()
        if let id = id, let owner = owner {
            Task { await owner.cancelRequestPublic(id: id) }
        }
    }
}

// MARK: - JSON-RPC envelopes

/// JSON-RPC 2.0 id. Spec allows `string | number | null`; we always
/// send numbers but must decode strings/numbers on incoming responses.
public enum LSPRequestID: Hashable, Sendable, Codable {
    case number(Int64)
    case string(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int64.self) { self = .number(n); return }
        self = .string(try c.decode(String.self))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }
}

public enum LSPError: Error, Sendable, CustomStringConvertible {
    case serverBinaryNotFound(String)
    case spawnFailed(String)
    case transportClosed
    case framingError(String)
    case timeout(method: String)
    case serverError(code: Int, message: String)
    case decodeError(method: String, message: String)
    case notInitialized

    public var description: String {
        switch self {
        case .serverBinaryNotFound(let path): return "LSP server binary not found: \(path)"
        case .spawnFailed(let m):              return "LSP spawn failed: \(m)"
        case .transportClosed:                 return "LSP transport closed"
        case .framingError(let m):             return "LSP framing error: \(m)"
        case .timeout(let m):                  return "LSP timeout: \(m)"
        case .serverError(let c, let m):       return "LSP server error \(c): \(m)"
        case .decodeError(let method, let m):  return "LSP decode error (\(method)): \(m)"
        case .notInitialized:                  return "LSP client not initialized"
        }
    }
}
