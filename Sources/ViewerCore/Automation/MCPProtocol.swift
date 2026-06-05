import Foundation

/// JSON-RPC 2.0 + MCP wire types, narrowed to the verbs we actually
/// speak in v1: `initialize`, `tools/list`, `tools/call`, plus generic
/// error responses. Everything else gets rejected with -32601
/// (MethodNotFound), which is the correct JSON-RPC 2.0 behaviour and
/// also a sane MCP response (the client expects standard JSON-RPC).
///
/// Why hand-rolled instead of pulling a swift-mcp package:
///   - Zero external deps (per project policy).
///   - We only need ~150 LOC of Codable; an SDK would bring 10× that
///     in transports/notifications we don't use.
///   - Spec churn risk is on us, not on an unmaintained dep.
///
/// Reference: JSON-RPC 2.0 spec + MCP 2024-11-05 schema (only the
/// fields we use).
public enum MCP {

    // MARK: - JSON value

    /// Loosely-typed JSON value used inside tool args and results.
    /// `Codable` against arbitrary JSON without depending on the
    /// JSONSerialization escape hatch (which doesn't play with Codable).
    public indirect enum Value: Codable, Equatable, Sendable {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([Value])
        case object([String: Value])

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let v = try? c.decode(Bool.self)   { self = .bool(v); return }
            // Try Int before Double — JSONDecoder will happily widen
            // `5` to `5.0` if Int isn't attempted first, losing fidelity
            // for tool args like `{"line": 42}`.
            if let v = try? c.decode(Int.self)    { self = .int(v); return }
            if let v = try? c.decode(Double.self) { self = .double(v); return }
            if let v = try? c.decode(String.self) { self = .string(v); return }
            if let v = try? c.decode([Value].self){ self = .array(v); return }
            if let v = try? c.decode([String: Value].self) { self = .object(v); return }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unrecognised JSON value")
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null:           try c.encodeNil()
            case .bool(let v):    try c.encode(v)
            case .int(let v):     try c.encode(v)
            case .double(let v):  try c.encode(v)
            case .string(let v):  try c.encode(v)
            case .array(let v):   try c.encode(v)
            case .object(let v):  try c.encode(v)
            }
        }

        // Convenience accessors used by tool handlers. They throw on
        // type mismatch so the dispatcher can convert to a JSON-RPC
        // -32602 (InvalidParams) response uniformly.

        public func string(_ key: String) throws -> String {
            guard case .object(let o) = self, case .string(let s)? = o[key] else {
                throw MCPError.invalidParams("missing or non-string field '\(key)'")
            }
            return s
        }
        public func bool(_ key: String, default fallback: Bool? = nil) throws -> Bool {
            guard case .object(let o) = self else {
                if let f = fallback { return f }
                throw MCPError.invalidParams("missing object")
            }
            guard let v = o[key] else {
                if let f = fallback { return f }
                throw MCPError.invalidParams("missing field '\(key)'")
            }
            guard case .bool(let b) = v else {
                throw MCPError.invalidParams("'\(key)' is not a bool")
            }
            return b
        }
        public func int(_ key: String) throws -> Int {
            guard case .object(let o) = self, let v = o[key] else {
                throw MCPError.invalidParams("missing field '\(key)'")
            }
            switch v {
            case .int(let i): return i
            // `Int(d)` is a runtime TRAP for out-of-range doubles (e.g.
            // `1e19`), which would crash the host from untrusted input.
            // `Int(exactly:)` is the non-trapping conversion: it returns
            // nil for any value outside Int's range or with a fraction.
            case .double(let d):
                guard let i = Int(exactly: d) else {
                    throw MCPError.invalidParams("'\(key)' is not an integer")
                }
                return i
            default:
                throw MCPError.invalidParams("'\(key)' is not an integer")
            }
        }
        public func optionalString(_ key: String) -> String? {
            guard case .object(let o) = self, case .string(let s)? = o[key] else { return nil }
            return s
        }
        public func optionalInt(_ key: String) -> Int? {
            guard case .object(let o) = self, let v = o[key] else { return nil }
            switch v {
            case .int(let i): return i
            // Non-trapping conversion — see `int(_:)`. `Int(exactly:)`
            // returns nil for out-of-range / fractional doubles, which
            // is exactly the "absent / unusable" semantics this accessor
            // already signals with nil.
            case .double(let d): return Int(exactly: d)
            default: return nil
            }
        }
    }

    // MARK: - JSON-RPC envelope

    /// The `id` field can be int, string, or null per JSON-RPC. We
    /// preserve the original shape so responses match what the client
    /// sent — some implementations rely on string ids round-tripping
    /// verbatim.
    public enum ID: Codable, Equatable, Sendable {
        case int(Int)
        case string(String)
        case null

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { self = .null; return }
            if let i = try? c.decode(Int.self)    { self = .int(i); return }
            if let s = try? c.decode(String.self) { self = .string(s); return }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "id must be int, string, or null")
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .null:           try c.encodeNil()
            case .int(let v):     try c.encode(v)
            case .string(let v):  try c.encode(v)
            }
        }
    }

    public struct Request: Codable, Sendable {
        public let jsonrpc: String
        public let id: ID?
        public let method: String
        public let params: Value?
    }

    public struct Response: Codable, Sendable {
        public let jsonrpc: String
        public let id: ID
        public let result: Value?
        public let error: ResponseError?

        public init(id: ID, result: Value) {
            self.jsonrpc = "2.0"; self.id = id; self.result = result; self.error = nil
        }
        public init(id: ID, error: ResponseError) {
            self.jsonrpc = "2.0"; self.id = id; self.result = nil; self.error = error
        }
    }

    public struct ResponseError: Codable, Sendable {
        public let code: Int
        public let message: String
        public let data: Value?

        public init(code: Int, message: String, data: Value? = nil) {
            self.code = code; self.message = message; self.data = data
        }
    }

    /// Standard JSON-RPC error codes + a small custom range for
    /// tool-specific failures (we keep them above -32000 so they don't
    /// collide with the spec).
    public enum ErrorCode {
        public static let parseError      = -32700
        public static let invalidRequest  = -32600
        public static let methodNotFound  = -32601
        public static let invalidParams   = -32602
        public static let internalError   = -32603
        // Server-defined range (-32000 to -32099)
        public static let toolError       = -32000
    }
}

/// Errors thrown by tool handlers / arg parsing. Caught at the dispatcher
/// boundary and converted to JSON-RPC error responses; never propagated
/// out of the server loop (so a buggy handler can't crash the host).
public enum MCPError: Error, Equatable {
    case invalidParams(String)
    case toolFailed(String)
    case notFound(String)
    case permissionDenied(String)

    public var code: Int {
        switch self {
        case .invalidParams:    return MCP.ErrorCode.invalidParams
        case .toolFailed:       return MCP.ErrorCode.toolError
        case .notFound:         return MCP.ErrorCode.toolError
        case .permissionDenied: return MCP.ErrorCode.toolError
        }
    }
    public var message: String {
        switch self {
        case .invalidParams(let s),
             .toolFailed(let s),
             .notFound(let s),
             .permissionDenied(let s):
            return s
        }
    }
}

// MARK: - MCP-level DTOs

extension MCP {

    /// Subset of the MCP `initialize` result the spec requires us to
    /// return. We advertise only the `tools` capability — no
    /// resources, prompts, or logging in v1.
    public struct InitializeResult: Codable, Sendable {
        public let protocolVersion: String
        public let capabilities: Capabilities
        public let serverInfo: ServerInfo

        public struct Capabilities: Codable, Sendable {
            public let tools: ToolsCapability
            public struct ToolsCapability: Codable, Sendable {
                /// We don't emit `notifications/tools/list_changed` in
                /// v1 — the tool set is static. Keep the field so the
                /// shape matches the spec.
                public let listChanged: Bool
                public init(listChanged: Bool = false) { self.listChanged = listChanged }
            }
        }

        public struct ServerInfo: Codable, Sendable {
            public let name: String
            public let version: String
        }
    }

    /// One entry in `tools/list`. `inputSchema` is a free-form JSON
    /// Schema object — we ship hand-written minimal schemas (just
    /// types, no `required`) rather than a full validator. The
    /// dispatcher does its own type-check via `Value.string(_:)` etc.
    public struct ToolDescriptor: Codable, Sendable {
        public let name: String
        public let description: String
        public let inputSchema: Value

        public init(name: String, description: String, inputSchema: Value) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
        }
    }

    /// `tools/call` result. We always return a single text block — the
    /// content is a JSON-serialised version of the tool's return value
    /// so clients can re-parse it. Multi-content / binary blocks (as
    /// MCP supports) are not used in v1.
    public struct ToolCallResult: Codable, Sendable {
        public let content: [ContentBlock]
        public let isError: Bool

        public struct ContentBlock: Codable, Sendable {
            public let type: String   // "text" only in v1
            public let text: String
        }

        public init(text: String, isError: Bool = false) {
            self.content = [ContentBlock(type: "text", text: text)]
            self.isError = isError
        }
    }
}
