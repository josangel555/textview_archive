import Foundation

public enum FileLoadError: Error, Equatable {
    case fileNotFound
    case notReadable
    case decodingFailed
    case tooLarge(bytes: Int)
    case binaryFile
}

public struct TextFile: Equatable, Sendable {
    public let url: URL
    public let contents: String
    public let encoding: String.Encoding
    public let byteCount: Int

    public init(url: URL, contents: String, encoding: String.Encoding, byteCount: Int) {
        self.url = url
        self.contents = contents
        self.encoding = encoding
        self.byteCount = byteCount
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
            return TextFile(url: url, contents: sniffed, encoding: sniffedEncoding, byteCount: data.count)
        }

        // B5: binary-blob guard. Sample the first 8 KB for NUL bytes — any
        // legitimate text file is essentially never going to contain a NUL.
        // Catches `/bin/ls`, archives, images, etc. that otherwise round-trip
        // through Latin-1 as gigabytes of nonsense.
        if Self.looksBinary(data) {
            throw FileLoadError.binaryFile
        }

        if let s = String(data: data, encoding: .utf8) {
            return TextFile(url: url, contents: s, encoding: .utf8, byteCount: data.count)
        }
        if let s = String(data: data, encoding: .isoLatin1) {
            return TextFile(url: url, contents: s, encoding: .isoLatin1, byteCount: data.count)
        }
        throw FileLoadError.decodingFailed
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
