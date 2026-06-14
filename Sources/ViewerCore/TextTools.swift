import Foundation
import CryptoKit

/// Pure, side-effect-free text-transform utilities backing the "Tools"
/// command family (TSK-292 SHA-256, TSK-294 Base64, TSK-295 random UUID).
///
/// Kept dependency-free — only Foundation + Apple's system `CryptoKit`
/// (no third-party packages) — and free of any app/UI state so every
/// transform is exhaustively unit-testable in the headless tier. The
/// command / clipboard / editor-insertion *surface* that invokes these is
/// deliberately wired separately (its UX — operate-on-selection vs.
/// clipboard round-trip — is an owner decision); this is the de-risked,
/// correctness-pinned core those surfaces share.
public enum TextTools {

    /// A fresh lowercased v4 UUID, e.g. `f47ac10b-58cc-4372-a567-0e02b2c3d479`.
    /// Lowercased because that's the dominant convention in source/config
    /// (JSON, env files) where these get pasted.
    public static func uuid() -> String {
        UUID().uuidString.lowercased()
    }

    /// Base64-encode the UTF-8 bytes of `text` (standard alphabet, padded).
    public static func base64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// Decode a Base64 string back to UTF-8 text. Returns `nil` when the
    /// input isn't decodable Base64 or the decoded bytes aren't valid UTF-8.
    /// Whitespace/newlines are tolerated (pasted or MIME-wrapped Base64); any
    /// other non-alphabet character makes the whole input invalid.
    ///
    /// We strip whitespace OURSELVES and decode with STRICT Base64 rather than
    /// lean on Foundation's `.ignoreUnknownCharacters`, because that option's
    /// handling of all-invalid input DIVERGES across Foundation versions —
    /// e.g. `"!!!"` strips to empty → older macOS returns `nil` but macOS 15+
    /// returns an empty `Data` (→ `""`, not nil) — and it also silently drops
    /// junk *mid*-string. Strict decode rejects any non-alphabet character on
    /// every OS; empty / whitespace-only content maps to `""` uniformly, which
    /// keeps the round-trip identity `base64Decode(base64Encode("")) == ""`
    /// (TSK-503).
    public static func base64Decode(_ text: String) -> String? {
        let compact = String(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        })
        if compact.isEmpty { return "" }
        guard let data = Data(base64Encoded: compact) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Lowercase hex SHA-256 of `data` (64 hex chars). The reusable core for
    /// both text and file-bytes hashing.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Lowercase hex SHA-256 of the UTF-8 bytes of `text` (64 hex chars).
    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    // MARK: - Line transforms (TSK-352 NotePad++/Sublime-style clipboard tools)

    /// Split into lines, treating `\n`, `\r\n` and `\r` each as ONE separator
    /// (Swift's `Character.isNewline` collapses `\r\n` to one grapheme), and
    /// KEEPING empty lines (so a blank line survives a round trip). Line
    /// transforms rejoin with `\n` — normalising line endings as a side effect,
    /// which is the conventional clipboard-tool behaviour.
    static func splitLines(_ s: String) -> [String] {
        s.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }

    /// Sort lines lexicographically (Unicode scalar order — deterministic across
    /// locales). `ascending: false` reverses to Z→A.
    public static func sortLines(_ s: String, ascending: Bool = true) -> String {
        let sorted = splitLines(s).sorted()
        return (ascending ? sorted : sorted.reversed()).joined(separator: "\n")
    }

    /// Drop duplicate lines, keeping the FIRST occurrence and preserving order.
    public static func uniqueLines(_ s: String) -> String {
        var seen = Set<String>()
        return splitLines(s).filter { seen.insert($0).inserted }.joined(separator: "\n")
    }

    /// Reverse the order of the lines.
    public static func reverseLines(_ s: String) -> String {
        splitLines(s).reversed().joined(separator: "\n")
    }
}

/// File-level SHA-256 checksums (surfaced in the metadata panel / "Copy
/// Checksum" actions). Distinct from `TextTools.sha256Hex(_ text:)` because a
/// file's bytes are hashed verbatim — a binary or non-UTF-8 file has no faithful
/// `String` form, and large files must not be slurped whole into memory.
/// File-checksum algorithms surfaced in the metadata panel + Copy-Checksum
/// actions (TSK-748). MD5/SHA-1 are cryptographically WEAK but still the common
/// "does this match the download" checksums users paste around, so we offer them
/// (clearly labelled) alongside the strong SHA-256/512 and the non-crypto CRC-32.
public enum ChecksumAlgorithm: String, CaseIterable, Sendable {
    case crc32, md5, sha1, sha256, sha512

    /// Human label for the UI / Copy-Checksum menu.
    public var label: String {
        switch self {
        case .crc32:  return "CRC-32"
        case .md5:    return "MD5"
        case .sha1:   return "SHA-1"
        case .sha256: return "SHA-256"
        case .sha512: return "SHA-512"
        }
    }
}

public enum FileChecksum {
    /// Streamed lowercase-hex SHA-256 of the file's RAW bytes (64 hex chars).
    /// Convenience over `hex(ofFileAt:algorithm:.sha256)` (kept for existing
    /// callers).
    public static func sha256Hex(ofFileAt url: URL, chunkSize: Int = 1 << 20) throws -> String {
        try hex(ofFileAt: url, algorithm: .sha256, chunkSize: chunkSize)
    }

    /// Streamed lowercase-hex checksum of the file's RAW bytes for `algorithm`.
    /// Reads in bounded `chunkSize` chunks folded into an incremental hasher, so
    /// peak memory stays ~`chunkSize` regardless of file size. Throws if the file
    /// can't be opened/read. (TSK-748.)
    public static func hex(ofFileAt url: URL, algorithm: ChecksumAlgorithm,
                           chunkSize: Int = 1 << 20) throws -> String {
        switch algorithm {
        case .crc32:  return try streamCRC32(ofFileAt: url, chunkSize: chunkSize)
        case .md5:    return try stream(Insecure.MD5(), ofFileAt: url, chunkSize: chunkSize)
        case .sha1:   return try stream(Insecure.SHA1(), ofFileAt: url, chunkSize: chunkSize)
        case .sha256: return try stream(SHA256(), ofFileAt: url, chunkSize: chunkSize)
        case .sha512: return try stream(SHA512(), ofFileAt: url, chunkSize: chunkSize)
        }
    }

    /// Fold a file's chunks through any CryptoKit `HashFunction`, hex-encoded.
    private static func stream<H: HashFunction>(_ hasher: H, ofFileAt url: URL,
                                                chunkSize: Int) throws -> String {
        var h = hasher
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // `read(upToCount:)` returns nil at EOF on some OS versions and an empty
        // `Data` on others — treat both as end-of-file.
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            h.update(data: chunk)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func streamCRC32(ofFileAt url: URL, chunkSize: Int) throws -> String {
        var crc = CRC32()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            crc.update(chunk)
        }
        return String(format: "%08x", crc.value)
    }
}

/// Streaming CRC-32 (IEEE 802.3 / zlib / gzip: reflected, poly 0xEDB88320,
/// init 0xFFFFFFFF, final XOR 0xFFFFFFFF). Hand-rolled — no zlib dep — for the
/// non-crypto "quick integrity" checksum users compare against `crc32`/`gzip`.
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }
    private var crc: UInt32 = 0xFFFF_FFFF
    mutating func update(_ data: Data) {
        for b in data {
            crc = Self.table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
    }
    var value: UInt32 { crc ^ 0xFFFF_FFFF }
}

/// Command-ready, surface-agnostic catalog of the Tools verbs. A future
/// command/clipboard/editor surface iterates `allCases` to register each as
/// a palette action, then calls `TextTools.apply(_:to:)` with the input it
/// has on hand (clipboard string or editor selection) — so this layer does
/// NOT commit to a particular UX. `rawValue` doubles as the canonical
/// `scriptVerb` for `CommandDescriptor`.
public enum TextToolVerb: String, CaseIterable, Sendable {
    case generateUUID  = "tools.uuid"
    case sha256        = "tools.sha256"
    case base64Encode  = "tools.base64Encode"
    case base64Decode  = "tools.base64Decode"
    case sortLinesAsc  = "tools.sortLinesAsc"
    case sortLinesDesc = "tools.sortLinesDesc"
    case uniqueLines   = "tools.uniqueLines"
    case reverseLines  = "tools.reverseLines"
    case upperCase     = "tools.upperCase"
    case lowerCase     = "tools.lowerCase"

    /// Human-readable command title (palette / menu label).
    public var title: String {
        switch self {
        case .generateUUID:  return "Generate UUID"
        case .sha256:        return "SHA-256 (hex)"
        case .base64Encode:  return "Base64 Encode"
        case .base64Decode:  return "Base64 Decode"
        case .sortLinesAsc:  return "Sort Lines (A→Z)"
        case .sortLinesDesc: return "Sort Lines (Z→A)"
        case .uniqueLines:   return "Remove Duplicate Lines"
        case .reverseLines:  return "Reverse Lines"
        case .upperCase:     return "UPPERCASE"
        case .lowerCase:     return "lowercase"
        }
    }

    /// `false` for generators (`.generateUUID` ignores input); `true` for
    /// transforms that consume the current selection/clipboard text.
    public var transformsInput: Bool { self != .generateUUID }
}

public extension TextTools {
    /// Apply a `TextToolVerb` to optional input text (an editor selection or
    /// the clipboard). Returns the result, or `nil` when a transform fails
    /// (e.g. `.base64Decode` on non-Base64 input). `.generateUUID` ignores
    /// `input`. The whole Tools surface bottoms out here, so the actual
    /// transforms stay in one tested place regardless of how they're invoked.
    static func apply(_ verb: TextToolVerb, to input: String?) -> String? {
        switch verb {
        case .generateUUID:  return uuid()
        case .sha256:        return sha256Hex(input ?? "")
        case .base64Encode:  return base64Encode(input ?? "")
        case .base64Decode:  return input.flatMap(base64Decode)
        case .sortLinesAsc:  return sortLines(input ?? "", ascending: true)
        case .sortLinesDesc: return sortLines(input ?? "", ascending: false)
        case .uniqueLines:   return uniqueLines(input ?? "")
        case .reverseLines:  return reverseLines(input ?? "")
        case .upperCase:     return (input ?? "").uppercased()
        case .lowerCase:     return (input ?? "").lowercased()
        }
    }
}
