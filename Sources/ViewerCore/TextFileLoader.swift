import Foundation

public enum FileLoadError: Error, Equatable {
    case fileNotFound
    case notReadable
    case decodingFailed
    case tooLarge(bytes: Int)
    case binaryFile
}

public struct TextFile: Sendable {
    public let url: URL
    public let contents: String
    public let encoding: String.Encoding
    public let byteCount: Int
    /// Mtime captured at `TextFileLoader.load` time from
    /// `attributesOfItem(atPath:)[.modificationDate]`. `nil` only when
    /// the filesystem failed to report a mtime (rare — synthetic
    /// in-memory `TextFile`s constructed by tests).
    ///
    /// Used as part of derived-product cache keys (rendered HTML,
    /// highlight runs) so a same-byte-length file-watcher reload
    /// (`# Hello\n` → `# World\n`) invalidates without paying an
    /// O(N) content hash on every SwiftUI body re-eval. APFS mtime
    /// is nanosecond-resolution so a back-to-back edit-and-reload
    /// produces a distinct timestamp.
    public let modifiedTime: Date?

    public init(
        url: URL,
        contents: String,
        encoding: String.Encoding,
        byteCount: Int,
        modifiedTime: Date? = nil
    ) {
        self.url = url
        self.contents = contents
        self.encoding = encoding
        self.byteCount = byteCount
        self.modifiedTime = modifiedTime
    }
}

/// Equatable by metadata only — full `contents` compare would be O(N).
/// `byteCount` change detects file-watcher reloads (post-write the
/// file size virtually always differs); for the pathological "edit
/// in place same length" case, callers that need bit-equality compare
/// `contents` explicitly.
///
/// `modifiedTime` is intentionally NOT part of equality — it's the
/// cache-key channel, not the "are these the same file?" check. Two
/// loads of an unchanged file constructed at different wall times
/// still compare equal so SwiftUI doesn't see redundant diff churn.
extension TextFile: Equatable {
    public static func == (lhs: TextFile, rhs: TextFile) -> Bool {
        lhs.url == rhs.url
            && lhs.byteCount == rhs.byteCount
            && lhs.encoding == rhs.encoding
    }
}

public struct TextFileLoader: Sendable {
    /// Maximum file size for in-memory loading. Larger files will throw.
    /// Phase 0 keeps a hard cap; a streaming/mmap loader comes with the hex viewer (Phase 6).
    public let maxBytes: Int

    public init(maxBytes: Int = 32 * 1024 * 1024) {
        self.maxBytes = maxBytes
    }

    public func load(url: URL) throws -> TextFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileLoadError.fileNotFound
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int, size > maxBytes {
            throw FileLoadError.tooLarge(bytes: size)
        }
        // Captured once at load time so derived-product caches (rendered
        // HTML, highlight runs) can key off it without re-stat'ing the
        // file on every body re-eval. APFS gives nanosecond resolution,
        // so a back-to-back rewrite of the same byte length still
        // produces a distinct timestamp — invalidates the cache where
        // the prior `byteCount`-only key would have served stale output.
        let mtime = attrs?[.modificationDate] as? Date

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FileLoadError.notReadable
        }

        // B4: sniff byte-order-marks before guessing — UTF-16 / UTF-8 BOMs are
        // unambiguous. Without this, a UTF-16-LE file decodes to garbage every-
        // other-NUL via the Latin-1 fallback (and reports "Latin-1").
        if let (sniffed, sniffedEncoding) = Self.decodeViaBOM(data) {
            return TextFile(
                url: url, contents: sniffed, encoding: sniffedEncoding,
                byteCount: data.count, modifiedTime: mtime
            )
        }

        // B5: binary-blob guard. Sample the first 8 KB for NUL bytes — any
        // legitimate text file is essentially never going to contain a NUL.
        // Catches `/bin/ls`, archives, images, etc. that otherwise round-trip
        // through Latin-1 as gigabytes of nonsense.
        if Self.looksBinary(data) {
            // BUT: UTF-16 files without a BOM also contain NUL bytes (one
            // per ASCII char). They look "binary" to the NUL heuristic.
            // Probe both endianness before falling back to .binaryFile,
            // so common Windows / Notepad files don't go to the hex view.
            if let s = Self.decodeUTF16WithoutBOM(data) {
                return TextFile(
                    url: url, contents: s.string,
                    encoding: s.encoding, byteCount: data.count,
                    modifiedTime: mtime
                )
            }
            throw FileLoadError.binaryFile
        }

        if let s = String(data: data, encoding: .utf8) {
            return TextFile(
                url: url, contents: s, encoding: .utf8,
                byteCount: data.count, modifiedTime: mtime
            )
        }
        if let s = String(data: data, encoding: .isoLatin1) {
            return TextFile(
                url: url, contents: s, encoding: .isoLatin1,
                byteCount: data.count, modifiedTime: mtime
            )
        }
        throw FileLoadError.decodingFailed
    }

    /// Attempt to decode `data` as UTF-16 (either endianness) when the
    /// caller has already ruled out BOM-prefixed UTF-16. Used as a
    /// fallback after `looksBinary` triggers, to catch BOM-less UTF-16
    /// files that appear binary because of interleaved NUL bytes.
    ///
    /// Heuristic: ASCII-heavy UTF-16 has NUL at EVERY odd byte (LE) or
    /// EVERY even byte (BE). Anything weaker than ~80% of slots being
    /// NUL in one parity is almost certainly real binary content.
    /// Requires the sample to be at least 32 bytes, otherwise the
    /// signal is too weak to trust.
    static func decodeUTF16WithoutBOM(_ data: Data) -> (string: String, encoding: String.Encoding)? {
        guard data.count >= 32, data.count % 2 == 0 else { return nil }
        let sample = data.prefix(2048)
        let n = sample.count
        // Count NUL positions in even/odd byte slots. UTF-16 LE ASCII
        // text has NUL at every odd index; UTF-16 BE ASCII at every
        // even index. Random binary distributes NULs evenly.
        var oddNULs = 0
        var evenNULs = 0
        var oddNonZero = 0
        var evenNonZero = 0
        for i in 0..<n {
            let byte = sample[sample.startIndex + i]
            if i % 2 == 0 {
                if byte == 0 { evenNULs += 1 } else { evenNonZero += 1 }
            } else {
                if byte == 0 { oddNULs += 1 } else { oddNonZero += 1 }
            }
        }
        // Require ≥ 80% of one parity slot to be NUL AND the other
        // parity to be non-NUL ≥ 80% — the ASCII-heavy UTF-16 fingerprint.
        let halfSlots = n / 2
        let strong = (halfSlots * 8) / 10  // 80%
        if oddNULs >= strong, evenNonZero >= strong,
           let s = String(data: data, encoding: .utf16LittleEndian) {
            return (s, .utf16LittleEndian)
        }
        if evenNULs >= strong, oddNonZero >= strong,
           let s = String(data: data, encoding: .utf16BigEndian) {
            return (s, .utf16BigEndian)
        }
        return nil
    }

    // MARK: - Encoding detection

    static func decodeViaBOM(_ data: Data) -> (String, String.Encoding)? {
        guard data.count >= 2 else { return nil }
        let b0 = data[0], b1 = data[1]
        // UTF-16 LE (FF FE)
        if b0 == 0xFF && b1 == 0xFE {
            if let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) {
                return (s, .utf16LittleEndian)
            }
        }
        // UTF-16 BE (FE FF)
        if b0 == 0xFE && b1 == 0xFF {
            if let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) {
                return (s, .utf16BigEndian)
            }
        }
        // UTF-8 (EF BB BF)
        if data.count >= 3 && b0 == 0xEF && b1 == 0xBB && data[2] == 0xBF {
            if let s = String(data: data.dropFirst(3), encoding: .utf8) {
                return (s, .utf8)
            }
        }
        return nil
    }

    static func looksBinary(_ data: Data) -> Bool {
        let sample = data.prefix(8192)
        for byte in sample where byte == 0 {
            return true
        }
        return false
    }
}
