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
/// `{kind, value}` MarkupContent, or an array of any of those. PoC
/// only renders the `markdown` MarkupContent path well; everything
/// else falls back to a plain-text dump.
public struct LSPHover: Sendable {
    public let contents: String   // pre-flattened to a markdown/plaintext blob
    public let isMarkdown: Bool
    public let range: LSPRange?
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
