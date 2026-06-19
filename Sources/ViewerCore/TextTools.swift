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

    /// Strip trailing spaces/tabs from every line (newlines preserved; output
    /// rejoined with `\n`).
    public static func trimTrailingWhitespace(_ s: String) -> String {
        splitLines(s).map { line -> String in
            var l = Substring(line)
            while let c = l.last, c == " " || c == "\t" { l = l.dropLast() }
            return String(l)
        }.joined(separator: "\n")
    }

    // MARK: - Editor line power-ops (TSK-675 — duplicate / move up-down)

    /// Result of an editor line transform: the rewritten document text plus the
    /// 0-based, inclusive line range the editor should RE-SELECT afterwards (so
    /// "duplicate" leaves the copy selected, and "move" keeps the same lines
    /// selected as they travel). `lineRange` is in the SAME 0-based-inclusive
    /// convention the inputs use; `lowerBound == upperBound` is a single line.
    public struct LineOpResult: Equatable, Sendable {
        public let text: String
        public let lineRange: ClosedRange<Int>
        public init(text: String, lineRange: ClosedRange<Int>) {
            self.text = text
            self.lineRange = lineRange
        }
    }

    /// Split `text` into lines while remembering whether the document ended with
    /// a trailing newline. Unlike `splitLines`, this is LOSSLESS for the
    /// trailing-newline distinction the editor cares about: `"a\nb"` → (`["a","b"]`,
    /// hasTrailingNewline:false) but `"a\nb\n"` → (`["a","b"]`, true). All three
    /// newline flavours (`\n`, `\r\n`, `\r`) count as one separator and the
    /// rejoin normalises to `\n` (matching the other line transforms). An empty
    /// document is a single empty line with no trailing newline.
    static func editorLines(_ text: String) -> (lines: [String], hasTrailingNewline: Bool) {
        if text.isEmpty { return ([""], false) }
        let parts = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)
        // A trailing separator yields a final empty element; treat that as
        // "document ends in a newline" and drop the phantom empty line, so the
        // line COUNT matches what the editor shows (N lines, not N+1).
        guard let last = parts.last else { return ([""], false) }
        if last.isEmpty && parts.count > 1 {
            return (Array(parts.dropLast()), true)
        }
        return (parts, false)
    }

    /// Rejoin editor lines with `\n`, restoring the trailing-newline marker.
    private static func joinEditorLines(_ lines: [String], hasTrailingNewline: Bool) -> String {
        let body = lines.joined(separator: "\n")
        return hasTrailingNewline ? body + "\n" : body
    }

    /// Clamp a possibly out-of-bounds line range to the valid `[0, count-1]`
    /// document bounds, returning `nil` for an empty doc. (`ClosedRange` already
    /// guarantees `lowerBound <= upperBound`, so only the document edges need
    /// clamping — a selection that scrolled past EOF after an external edit.)
    static func clampLineRange(_ range: ClosedRange<Int>, lineCount: Int) -> ClosedRange<Int>? {
        guard lineCount > 0 else { return nil }
        let lo = max(0, min(range.lowerBound, lineCount - 1))
        let hi = max(0, min(range.upperBound, lineCount - 1))
        return lo...hi
    }

    /// Duplicate the lines in `lineRange` (0-based, inclusive), inserting an
    /// EXACT copy immediately BELOW the original block, and return the new text
    /// with the selection moved onto the freshly-inserted copy (so a repeat keeps
    /// growing the block, matching VS Code / Sublime "Duplicate Line(s)"). The
    /// duplicated copy carries a trailing newline into the document when the
    /// original block was the last line and the file had no trailing newline —
    /// i.e. duplicating the last unterminated line yields `…last\nlast` (the
    /// original line gains a terminator, the copy does not), never `…lastlast`.
    /// Out-of-range / reversed inputs are clamped; an empty document is a no-op
    /// returning a single-line selection at 0.
    public static func duplicateLines(_ text: String, lineRange: ClosedRange<Int>) -> LineOpResult {
        var (lines, hasTrailingNewline) = editorLines(text)
        guard let range = clampLineRange(lineRange, lineCount: lines.count) else {
            return LineOpResult(text: text, lineRange: 0...0)
        }
        let block = Array(lines[range])
        // Insert the copy directly after the original block.
        lines.insert(contentsOf: block, at: range.upperBound + 1)
        // If the original block was the file's last line and there was no
        // trailing newline, the inserted copy is now the last line; the document
        // still has no trailing newline, and the original line is separated from
        // its copy by the join's `\n`. No special-casing needed: joinEditorLines
        // with the SAME hasTrailingNewline reproduces exactly that.
        let count = range.upperBound - range.lowerBound + 1
        let newLower = range.upperBound + 1
        let newSelection = newLower...(newLower + count - 1)
        return LineOpResult(
            text: joinEditorLines(lines, hasTrailingNewline: hasTrailingNewline),
            lineRange: newSelection)
    }

    /// Move the lines in `lineRange` (0-based, inclusive) up (`by: -1`) or down
    /// (`by: +1`) by ONE position, swapping past the adjacent line, and return
    /// the new text with the selection following the moved block. A move that
    /// would push the block past the top (`by < 0` at line 0) or bottom (`by > 0`
    /// at the last line) is a NO-OP that returns the original text and the
    /// clamped selection unchanged — matching every editor's bounds behaviour.
    /// Only `±1` is honoured; any other `by` is treated as no movement (clamped
    /// to its sign would over-reach for multi-step, which the editor never asks).
    /// Trailing-newline presence is preserved across the move.
    public static func moveLines(_ text: String, lineRange: ClosedRange<Int>, by: Int) -> LineOpResult {
        var (lines, hasTrailingNewline) = editorLines(text)
        guard let range = clampLineRange(lineRange, lineCount: lines.count) else {
            return LineOpResult(text: text, lineRange: 0...0)
        }
        let step = by < 0 ? -1 : (by > 0 ? 1 : 0)
        // Bounds / no-op: can't move up past 0, down past the last line, or with
        // a zero step.
        if step == 0
            || (step < 0 && range.lowerBound == 0)
            || (step > 0 && range.upperBound == lines.count - 1) {
            return LineOpResult(
                text: joinEditorLines(lines, hasTrailingNewline: hasTrailingNewline),
                lineRange: range)
        }
        let block = Array(lines[range])
        lines.removeSubrange(range)
        // After removal, the block reinserts at its original lower bound shifted
        // by the step (the adjacent line has filled the gap).
        let insertAt = range.lowerBound + step
        lines.insert(contentsOf: block, at: insertAt)
        let newSelection = insertAt...(insertAt + block.count - 1)
        return LineOpResult(
            text: joinEditorLines(lines, hasTrailingNewline: hasTrailingNewline),
            lineRange: newSelection)
    }

    // MARK: - Encode / decode (clipboard dev tools, TSK-352)

    /// Percent-encode for a URL: everything except the RFC 3986 *unreserved*
    /// set (`A–Z a–z 0–9 - . _ ~`) is escaped — so a space becomes `%20`,
    /// not `+`. Returns the input unchanged in the (practically impossible)
    /// event Foundation can't encode it.
    public static func urlEncode(_ s: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// Decode percent-escapes. Returns `nil` on a malformed escape sequence.
    public static func urlDecode(_ s: String) -> String? {
        s.removingPercentEncoding
    }

    /// Escape the five HTML-significant characters (`&` first, so it doesn't
    /// double-encode the ones below).
    public static func htmlEncode(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }

    /// Decode HTML entities: the common named ones (`&amp; &lt; &gt; &quot;
    /// &apos; &#39;`) plus numeric `&#dd;` / `&#xhh;`. The exact inverse of
    /// `htmlEncode` for any text it produced; unknown entities are left as-is.
    public static func htmlDecode(_ s: String) -> String {
        var result = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&",
               let semi = s[i...].firstIndex(of: ";"),
               s.distance(from: i, to: semi) <= 12,
               let decoded = decodeHTMLEntity(String(s[s.index(after: i)..<semi])) {
                result.append(decoded)
                i = s.index(after: semi)
                continue
            }
            result.append(s[i])
            i = s.index(after: i)
        }
        return result
    }

    private static func decodeHTMLEntity(_ e: String) -> Character? {
        switch e {
        case "amp":          return "&"
        case "lt":           return "<"
        case "gt":           return ">"
        case "quot":         return "\""
        case "apos", "#39":  return "'"
        default:
            if e.hasPrefix("#x") || e.hasPrefix("#X"),
               let code = UInt32(e.dropFirst(2), radix: 16),
               let sc = Unicode.Scalar(code) { return Character(sc) }
            if e.hasPrefix("#"), let code = UInt32(e.dropFirst()),
               let sc = Unicode.Scalar(code) { return Character(sc) }
            return nil
        }
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
    case trimTrailing  = "tools.trimTrailing"
    case urlEncode     = "tools.urlEncode"
    case urlDecode     = "tools.urlDecode"
    case htmlEncode    = "tools.htmlEncode"
    case htmlDecode    = "tools.htmlDecode"

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
        case .trimTrailing:  return "Trim Trailing Whitespace"
        case .urlEncode:     return "URL Encode"
        case .urlDecode:     return "URL Decode"
        case .htmlEncode:    return "HTML Encode"
        case .htmlDecode:    return "HTML Decode"
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
        case .trimTrailing:  return trimTrailingWhitespace(input ?? "")
        case .urlEncode:     return urlEncode(input ?? "")
        case .urlDecode:     return input.flatMap(urlDecode)
        case .htmlEncode:    return htmlEncode(input ?? "")
        case .htmlDecode:    return htmlDecode(input ?? "")
        }
    }
}
