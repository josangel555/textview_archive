import Foundation

/// Pure-logic search for the HEX viewer. Two query modes:
///
/// * `.hex`  — user types whitespace-separated hex bytes
///             (`"de ad be ef"`, `"DEADBEEF"`, `"de adbe ef"`).
///             Parsed into a `[UInt8]` pattern. Reject if any
///             non-hex char survives or if the resulting nibble
///             count is odd within a token (`"de a"` -> reject).
///
/// * `.ascii` — user types a plain string; we take its UTF-8 bytes.
///              Empty string -> no matches.
///
/// `find` returns offsets where the pattern starts inside the
/// supplied `Data`. We use **non-overlapping** matches (Sublime /
/// VSCode convention): for `Data([0xAA, 0xAA, 0xAA])` searching for
/// `[0xAA, 0xAA]`, the result is `[0]`, not `[0, 1]`.
public enum HexSearchMode: Sendable, Equatable {
    case hex
    case ascii
}

public enum HexSearchEngine {

    /// Parse a user query into a byte pattern. Returns `nil` if the
    /// query is invalid for the given mode (caller should surface a
    /// muted error / disabled state in the UI). Returns an empty
    /// array if the user hasn't typed anything yet.
    public static func parse(_ query: String, mode: HexSearchMode) -> [UInt8]? {
        switch mode {
        case .ascii:
            return Array(query.utf8)
        case .hex:
            // Split on whitespace; each token must be an even-length
            // hex string. Allows the user to paste `DEADBEEF` as one
            // token OR space-separate `de ad be ef`.
            let tokens = query
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
            if tokens.isEmpty { return [] }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(tokens.reduce(0) { $0 + $1.count / 2 })
            for token in tokens {
                // Must be hex digits only, even length.
                if token.isEmpty { continue }
                if token.count % 2 != 0 { return nil }
                var idx = token.startIndex
                while idx < token.endIndex {
                    let next = token.index(idx, offsetBy: 2)
                    let pair = token[idx..<next]
                    guard let b = UInt8(pair, radix: 16) else { return nil }
                    bytes.append(b)
                    idx = next
                }
            }
            return bytes
        }
    }

    /// Non-overlapping byte-sequence search.
    /// `pattern` empty -> `[]`. `pattern.count > data.count` -> `[]`.
    public static func find(pattern: [UInt8], in data: Data) -> [Int] {
        if pattern.isEmpty || pattern.count > data.count { return [] }
        var hits: [Int] = []
        let n = data.count
        let m = pattern.count
        // Bounded buffer scan; Data subscripting is O(1) on contiguous
        // storage. We deliberately don't bring in Boyer-Moore for a
        // 4 MB cap and short patterns.
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            let limit = n - m
            while i <= limit {
                var matched = true
                for j in 0..<m {
                    if base[i + j] != pattern[j] { matched = false; break }
                }
                if matched {
                    hits.append(i)
                    i += m   // non-overlapping
                } else {
                    i += 1
                }
            }
        }
        return hits
    }

    /// Convenience: parse + find in one call. Returns empty on
    /// invalid query.
    public static func search(_ query: String,
                              mode: HexSearchMode,
                              in data: Data) -> [Int] {
        guard let pattern = parse(query, mode: mode), !pattern.isEmpty else {
            return []
        }
        return find(pattern: pattern, in: data)
    }

    /// All offsets of a single byte value (overlapping is meaningless
    /// for length-1 patterns; this is what click-to-highlight calls).
    public static func offsets(ofByte byte: UInt8, in data: Data) -> [Int] {
        var hits: [Int] = []
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<data.count where base[i] == byte {
                hits.append(i)
            }
        }
        return hits
    }
}
