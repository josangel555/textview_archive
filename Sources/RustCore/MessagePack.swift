import Foundation

/// A minimal, dependency-free MessagePack reader — just enough to decode the
/// named-field maps the Rust core emits (`to_vec_named`). Hand-rolled to keep
/// the Swift side dependency-free too (mirrors the "hand-roll everything" rule
/// the Rust side follows). Supports the subset the wire types use: fixmap /
/// map16 / map32, fixarray / array16 / array32, fixstr / str8/16/32,
/// positive/negative fixint, uint/int 8..64, bool, nil.
///
/// This is a READER only (Swift decodes the Rust core's responses). The Swift
/// side sends commands via primitive C args, not MessagePack, so no encoder is
/// needed. Carried over verbatim from the validated PoC bridge.
enum MsgPackValue: Equatable {
    case nilValue
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case string(String)
    case array([MsgPackValue])
    case map([(MsgPackValue, MsgPackValue)])

    static func == (lhs: MsgPackValue, rhs: MsgPackValue) -> Bool {
        switch (lhs, rhs) {
        case (.nilValue, .nilValue): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.uint(a), .uint(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.map(a), .map(b)):
            guard a.count == b.count else { return false }
            for i in a.indices where a[i].0 != b[i].0 || a[i].1 != b[i].1 { return false }
            return true
        default: return false
        }
    }
}

enum MsgPackError: Error, Equatable {
    case truncated
    case unsupportedTag(UInt8)
    case typeMismatch(String)
    case missingKey(String)
}

struct MsgPackReader {
    private let bytes: [UInt8]
    private var pos: Int = 0

    init(_ data: [UInt8]) { self.bytes = data }
    init(_ data: Data) { self.bytes = [UInt8](data) }

    private mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw MsgPackError.truncated }
        defer { pos += 1 }
        return bytes[pos]
    }

    private mutating func take(_ n: Int) throws -> [UInt8] {
        guard pos + n <= bytes.count else { throw MsgPackError.truncated }
        defer { pos += n }
        return Array(bytes[pos..<pos + n])
    }

    private mutating func uintN(_ n: Int) throws -> UInt64 {
        var v: UInt64 = 0
        for b in try take(n) { v = (v << 8) | UInt64(b) }
        return v
    }

    private mutating func intN(_ n: Int) throws -> Int64 {
        let raw = try uintN(n)
        switch n {
        case 1: return Int64(Int8(bitPattern: UInt8(truncatingIfNeeded: raw)))
        case 2: return Int64(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
        case 4: return Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
        default: return Int64(bitPattern: raw)
        }
    }

    mutating func decode() throws -> MsgPackValue {
        let tag = try u8()
        switch tag {
        case 0x00...0x7f: return .uint(UInt64(tag))                     // positive fixint
        case 0xe0...0xff: return .int(Int64(Int8(bitPattern: tag)))     // negative fixint
        case 0xc0: return .nilValue
        case 0xc2: return .bool(false)
        case 0xc3: return .bool(true)
        case 0xcc: return .uint(try uintN(1))
        case 0xcd: return .uint(try uintN(2))
        case 0xce: return .uint(try uintN(4))
        case 0xcf: return .uint(try uintN(8))
        case 0xd0: return .int(try intN(1))
        case 0xd1: return .int(try intN(2))
        case 0xd2: return .int(try intN(4))
        case 0xd3: return .int(try intN(8))
        case 0xa0...0xbf: return .string(try str(Int(tag & 0x1f)))      // fixstr
        case 0xd9: return .string(try str(Int(try uintN(1))))
        case 0xda: return .string(try str(Int(try uintN(2))))
        case 0xdb: return .string(try str(Int(try uintN(4))))
        case 0x90...0x9f: return try array(Int(tag & 0x0f))             // fixarray
        case 0xdc: return try array(Int(try uintN(2)))
        case 0xdd: return try array(Int(try uintN(4)))
        case 0x80...0x8f: return try map(Int(tag & 0x0f))               // fixmap
        case 0xde: return try map(Int(try uintN(2)))
        case 0xdf: return try map(Int(try uintN(4)))
        default: throw MsgPackError.unsupportedTag(tag)
        }
    }

    private mutating func str(_ n: Int) throws -> String {
        let raw = try take(n)
        guard let s = String(bytes: raw, encoding: .utf8) else {
            throw MsgPackError.typeMismatch("invalid utf-8 string")
        }
        return s
    }

    private mutating func array(_ n: Int) throws -> MsgPackValue {
        var out: [MsgPackValue] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(try decode()) }
        return .array(out)
    }

    private mutating func map(_ n: Int) throws -> MsgPackValue {
        var out: [(MsgPackValue, MsgPackValue)] = []
        out.reserveCapacity(n)
        for _ in 0..<n {
            let k = try decode()
            let v = try decode()
            out.append((k, v))
        }
        return .map(out)
    }
}

// MARK: - Typed accessors over a decoded map

extension MsgPackValue {
    func mapValue() throws -> [String: MsgPackValue] {
        guard case let .map(pairs) = self else {
            throw MsgPackError.typeMismatch("expected map")
        }
        var dict: [String: MsgPackValue] = [:]
        for (k, v) in pairs {
            if case let .string(key) = k { dict[key] = v }
        }
        return dict
    }

    func arrayValue() throws -> [MsgPackValue] {
        guard case let .array(a) = self else {
            throw MsgPackError.typeMismatch("expected array")
        }
        return a
    }

    func stringValue() throws -> String {
        guard case let .string(s) = self else {
            throw MsgPackError.typeMismatch("expected string")
        }
        return s
    }

    func boolValue() throws -> Bool {
        guard case let .bool(b) = self else {
            throw MsgPackError.typeMismatch("expected bool")
        }
        return b
    }

    func u64Value() throws -> UInt64 {
        switch self {
        case let .uint(u): return u
        case let .int(i) where i >= 0: return UInt64(i)
        default: throw MsgPackError.typeMismatch("expected non-negative int")
        }
    }

    func stringArray() throws -> [String] {
        try arrayValue().map { try $0.stringValue() }
    }

    func stringMatrix() throws -> [[String]] {
        try arrayValue().map { try $0.stringArray() }
    }

    func u32Array() throws -> [UInt32] {
        try arrayValue().map { UInt32(truncatingIfNeeded: try $0.u64Value()) }
    }
}

extension [String: MsgPackValue] {
    func require(_ key: String) throws -> MsgPackValue {
        guard let v = self[key] else { throw MsgPackError.missingKey(key) }
        return v
    }
}
