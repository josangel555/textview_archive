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
    /// MessagePack bin family (0xc4/c5/c6) — the remote envelope's opaque
    /// body (TSK-652 stage 2). Additive: nothing in the pre-remote wire
    /// emits bin.
    case binary([UInt8])

    static func == (lhs: MsgPackValue, rhs: MsgPackValue) -> Bool {
        switch (lhs, rhs) {
        case (.nilValue, .nilValue): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.uint(a), .uint(b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.binary(a), .binary(b)): return a == b
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
    /// Container nesting exceeded `MsgPackReader.maxDepth`. The reader recurses
    /// per `array`/`map` level, so an adversarial frame of repeated container
    /// tags (e.g. ~8M `0x91` fixarray bytes inside a sub-16 MiB remote envelope)
    /// would overflow the native stack -> uncatchable SIGSEGV. The cap turns
    /// that DoS into a typed, catchable throw (TSK-965).
    case tooDeep
}

struct MsgPackReader {
    /// Maximum container nesting `decode()` will descend before throwing
    /// `MsgPackError.tooDeep`. Each `array`/`map` level is a native recursion
    /// frame; without a bound an adversarial frame of repeated container tags
    /// overflows the stack -> uncatchable SIGSEGV on the remote path
    /// (`RemoteTransport` admits up to a 16 MiB envelope, ~8M `0x91` tags deep).
    /// 128 matches the Rust core's JSON-parse `MAX_DEPTH` (`format.rs`) and is
    /// far deeper than any real `to_vec_named` response (the wire envelope is a
    /// shallow named map whose body is an opaque `bin`; the deepest decoded
    /// shape — `stringMatrix`, array-of-array-of-string — is depth 3).
    static let maxDepth = 128

    private let bytes: [UInt8]
    private var pos: Int = 0

    init(_ data: [UInt8]) { self.bytes = data }
    init(_ data: Data) { self.bytes = [UInt8](data) }
    /// Read `data` starting at `offset` — the zero-copy decode path for a
    /// length-prefixed frame: pass the WHOLE frame + the body offset (4) instead
    /// of copying `frame[4...]` into a fresh `[UInt8]` (TSK-564). `bytes` stays
    /// 0-indexed (the full frame); only the cursor starts past the prefix, so the
    /// bounds checks (`pos <= bytes.count - n`) and `finish()` (`pos == count`,
    /// reached after the body) hold unchanged.
    init(_ data: [UInt8], startingAt offset: Int) {
        self.bytes = data
        self.pos = offset
    }

    private mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw MsgPackError.truncated }
        defer { pos += 1 }
        return bytes[pos]
    }

    private mutating func uintN(_ n: Int) throws -> UInt64 {
        guard n >= 0, pos <= bytes.count - n else { throw MsgPackError.truncated }
        var v: UInt64 = 0
        for i in 0..<n { v = (v << 8) | UInt64(bytes[pos + i]) }
        pos += n
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

    /// `depth` is the current container-nesting level (0 at the top call).
    /// `array`/`map` recurse with `depth + 1`; once it would exceed
    /// `maxDepth` the reader throws `MsgPackError.tooDeep` BEFORE descending,
    /// bounding native stack use to a fixed maximum regardless of input size.
    mutating func decode(depth: Int = 0) throws -> MsgPackValue {
        guard depth <= Self.maxDepth else { throw MsgPackError.tooDeep }
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
        case 0xc4: return .binary(try bin(Int(try uintN(1))))
        case 0xc5: return .binary(try bin(Int(try uintN(2))))
        case 0xc6: return .binary(try bin(Int(try uintN(4))))
        case 0xda: return .string(try str(Int(try uintN(2))))
        case 0xdb: return .string(try str(Int(try uintN(4))))
        case 0x90...0x9f: return try array(Int(tag & 0x0f), depth: depth) // fixarray
        case 0xdc: return try array(Int(try uintN(2)), depth: depth)
        case 0xdd: return try array(Int(try uintN(4)), depth: depth)
        case 0x80...0x8f: return try map(Int(tag & 0x0f), depth: depth)   // fixmap
        case 0xde: return try map(Int(try uintN(2)), depth: depth)
        case 0xdf: return try map(Int(try uintN(4)), depth: depth)
        default: throw MsgPackError.unsupportedTag(tag)
        }
    }

    /// Assert the whole body was consumed by the preceding `decode()`. The
    /// frame's length prefix promises the body is fully accounted for; a body
    /// that is one valid value FOLLOWED by extra bytes otherwise decodes
    /// successfully and silently drops the trailing bytes, masking a class of
    /// framing / version-skew bugs. Consumers should call this after the
    /// top-level `decode()` (see `CsvSession` decode sites) so trailing garbage
    /// surfaces as a `typeMismatch` rather than passing unnoticed.
    mutating func finish() throws {
        guard pos == bytes.count else {
            throw MsgPackError.typeMismatch("trailing bytes")
        }
    }

    private mutating func bin(_ n: Int) throws -> [UInt8] {
        guard n >= 0, pos <= bytes.count - n else { throw MsgPackError.truncated }
        defer { pos += n }
        return Array(bytes[pos..<pos + n])
    }

    private mutating func str(_ n: Int) throws -> String {
        guard n >= 0, pos <= bytes.count - n else { throw MsgPackError.truncated }
        // `String(decoding:as:)` is non-failing (it substitutes U+FFFD for
        // invalid sequences) and decodes the slice in place — no transient
        // `[UInt8]` copy. The Rust core only ever emits valid UTF-8, so the
        // replacement-char path is unreachable in practice; we trade the old
        // strict `typeMismatch` reject for zero per-cell allocation, matching
        // the reader's role as a trusted-producer decoder.
        let s = String(decoding: bytes[pos..<pos + n], as: UTF8.self)
        pos += n
        return s
    }

    private mutating func array(_ n: Int, depth: Int) throws -> MsgPackValue {
        var out: [MsgPackValue] = []
        // Clamp the reserve to the bytes actually remaining: every MessagePack
        // element is >= 1 byte (its tag), so `remaining` is a lossless upper
        // bound on the real element count. Reserving the raw declared `n`
        // (up to ~4.29e9 from `array16/32`) before reading a single element is
        // an OOM-abort vector — a 9-byte body claiming 4.29e9 elements would
        // drive a ~34 GB allocation that no `catch` can recover (abort, not
        // throw). The `for` loop still fails with `.truncated` once the body
        // runs out, so a short-but-large-count frame errors cleanly.
        out.reserveCapacity(min(n, max(0, bytes.count - pos)))
        for _ in 0..<n { out.append(try decode(depth: depth + 1)) }
        return .array(out)
    }

    private mutating func map(_ n: Int, depth: Int) throws -> MsgPackValue {
        var out: [(MsgPackValue, MsgPackValue)] = []
        // Same OOM-abort guard as `array`: a map pair is >= 2 bytes, so the
        // remaining byte count bounds the pair count too (clamp is conservative
        // but always >= the real count). See `array` for the rationale.
        out.reserveCapacity(min(n, max(0, bytes.count - pos)))
        for _ in 0..<n {
            let k = try decode(depth: depth + 1)
            let v = try decode(depth: depth + 1)
            out.append((k, v))
        }
        return .map(out)
    }
}

// MARK: - Typed accessors over a decoded map

extension MsgPackValue {
    var isNil: Bool {
        if case .nilValue = self { return true }
        return false
    }

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

    /// Direct, allocation-free lookup of a string-keyed field in a `.map` value.
    ///
    /// `mapValue()` materializes the WHOLE map into a throwaway
    /// `[String: MsgPackValue]` dict and then the caller pulls a handful of keys
    /// back out — pure throwaway work, paid once PER row when decoding a
    /// response array (e.g. one find/fuzzy/grep hit per element). When the caller
    /// only needs a few fields out of a small map, scanning the pair-array in
    /// place is cheaper than building (and immediately discarding) the dict:
    /// no Dictionary allocation, no per-key hashing, no copy.
    ///
    /// Maps the Rust core emits are small (a row is ~3-6 fields), so the linear
    /// scan is faster than the dict round-trip in practice; it returns the FIRST
    /// match, matching `mapValue()`'s last-writer-wins only on duplicate keys
    /// (the core never emits duplicates). Returns `nil` if the key is absent.
    /// Throws `typeMismatch` if `self` is not a map — same contract as
    /// `mapValue()` on a shape error, so callers fail identically.
    func field(_ key: String) throws -> MsgPackValue? {
        guard case let .map(pairs) = self else {
            throw MsgPackError.typeMismatch("expected map")
        }
        for (k, v) in pairs where k == .string(key) { return v }
        return nil
    }

    /// `field(_:)` that throws `missingKey` when the field is absent — the
    /// allocation-free analogue of `mapValue().require(_:)` for per-row decode
    /// loops. Same error surface as the dict path so error handling is unchanged.
    func requireField(_ key: String) throws -> MsgPackValue {
        guard let v = try field(key) else { throw MsgPackError.missingKey(key) }
        return v
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

    func i64Value() throws -> Int64 {
        switch self {
        case let .int(i): return i
        case let .uint(u) where u <= UInt64(Int64.max): return Int64(u)
        default: throw MsgPackError.typeMismatch("expected int")
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

// MARK: - Encoder (Swift → Rust, the write path)

/// MessagePack ENCODER — the inverse of `MsgPackReader.decode()` over the same
/// value subset, so `MsgPackReader(v.encode()).decode() == v` round-trips. The
/// read path was all the CSV beachhead needed (Swift only decoded the core's
/// responses); Phase B of the migration (`docs/RUST_MIGRATION_PLAN_2026-06-04.md`)
/// dispatches structured COMMANDS to the core, which needs Swift→Rust encoding.
/// Hand-rolled, no dependency — mirrors the Rust side's "hand-roll the wire"
/// rule and keeps the Swift bridge dependency-free.
///
/// Tag choice is smallest-fits. `.int` always encodes to a signed tag (incl.
/// non-negative values) and `.uint` to an unsigned one, so the value's case
/// survives the round-trip exactly (the reader maps positive fixint → `.uint`,
/// `0xd0..` → `.int`). Big-endian payloads, matching the reader.
extension MsgPackValue {

    func encode() -> [UInt8] {
        var out: [UInt8] = []
        encode(into: &out)
        return out
    }

    /// The core's wire framing: a `u32`-LE length prefix + the encoded body
    /// (decision #6: DIY `u32`-LE length prefix). Matches `wire::encode_frame`.
    func frame() -> [UInt8] {
        MsgPackFraming.frame(encode())
    }
}

/// Frame raw body bytes (the transport seam works at the byte level; the
/// value-tree `frame()` above delegates here).
enum MsgPackFraming {
    static func frame(_ body: [UInt8]) -> [UInt8] {
        let n = UInt32(truncatingIfNeeded: body.count)
        var out: [UInt8] = [
            UInt8(n & 0xff), UInt8((n >> 8) & 0xff),
            UInt8((n >> 16) & 0xff), UInt8((n >> 24) & 0xff),
        ]
        out.append(contentsOf: body)
        return out
    }
}

extension MsgPackValue {
    private func encode(into out: inout [UInt8]) {
        switch self {
        case .nilValue: out.append(0xc0)
        case .bool(let b): out.append(b ? 0xc3 : 0xc2)
        case .uint(let u): Self.encodeUInt(u, into: &out)
        case .int(let i): Self.encodeInt(i, into: &out)
        case .string(let s): Self.encodeString(s, into: &out)
        case .binary(let b):
            // bin32 unconditionally — mirrors the server's encoder; bodies
            // can be big and the 5-byte header is noise at that size.
            out.append(0xc6)
            Self.appendBE(UInt64(b.count), 4, &out)
            out.append(contentsOf: b)
        case .array(let a):
            Self.encodeLength(a.count, fix: 0x90, tag16: 0xdc, tag32: 0xdd, into: &out)
            for e in a { e.encode(into: &out) }
        case .map(let pairs):
            Self.encodeLength(pairs.count, fix: 0x80, tag16: 0xde, tag32: 0xdf, into: &out)
            for (k, v) in pairs { k.encode(into: &out); v.encode(into: &out) }
        }
    }

    private static func encodeUInt(_ u: UInt64, into out: inout [UInt8]) {
        if u < 0x80 { out.append(UInt8(u)) }                       // positive fixint
        else if u <= 0xff { out.append(0xcc); out.append(UInt8(u)) }
        else if u <= 0xffff { out.append(0xcd); appendBE(u, 2, &out) }
        else if u <= 0xffff_ffff { out.append(0xce); appendBE(u, 4, &out) }
        else { out.append(0xcf); appendBE(u, 8, &out) }
    }

    private static func encodeInt(_ i: Int64, into out: inout [UInt8]) {
        if i >= -32 && i < 0 {
            out.append(UInt8(bitPattern: Int8(truncatingIfNeeded: i)))  // negative fixint
        } else if i >= -128 && i <= 127 {
            out.append(0xd0); out.append(UInt8(bitPattern: Int8(truncatingIfNeeded: i)))
        } else if i >= -32768 && i <= 32767 {
            out.append(0xd1); appendBE(UInt64(bitPattern: i), 2, &out)
        } else if i >= -2_147_483_648 && i <= 2_147_483_647 {
            out.append(0xd2); appendBE(UInt64(bitPattern: i), 4, &out)
        } else {
            out.append(0xd3); appendBE(UInt64(bitPattern: i), 8, &out)
        }
    }

    private static func encodeString(_ s: String, into out: inout [UInt8]) {
        let bytes = Array(s.utf8)
        let n = bytes.count
        if n < 32 { out.append(0xa0 | UInt8(n)) }                  // fixstr
        else if n <= 0xff { out.append(0xd9); out.append(UInt8(n)) }
        else if n <= 0xffff { out.append(0xda); appendBE(UInt64(n), 2, &out) }
        else { out.append(0xdb); appendBE(UInt64(n), 4, &out) }
        out.append(contentsOf: bytes)
    }

    private static func encodeLength(_ n: Int, fix: UInt8, tag16: UInt8, tag32: UInt8,
                                     into out: inout [UInt8]) {
        if n < 16 { out.append(fix | UInt8(n)) }
        else if n <= 0xffff { out.append(tag16); appendBE(UInt64(n), 2, &out) }
        else { out.append(tag32); appendBE(UInt64(n), 4, &out) }
    }

    /// Append the low `width` bytes of `v`, big-endian (matches the reader's
    /// `uintN`).
    private static func appendBE(_ v: UInt64, _ width: Int, _ out: inout [UInt8]) {
        for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
        }
    }
}
