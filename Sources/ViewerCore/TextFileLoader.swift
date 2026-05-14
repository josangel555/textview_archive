import Foundation

public enum FileLoadError: Error, Equatable {
    case fileNotFound
    case notReadable
    case decodingFailed
    case tooLarge(bytes: Int)
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

        if let s = String(data: data, encoding: .utf8) {
            return TextFile(url: url, contents: s, encoding: .utf8, byteCount: data.count)
        }
        if let s = String(data: data, encoding: .isoLatin1) {
            return TextFile(url: url, contents: s, encoding: .isoLatin1, byteCount: data.count)
        }
        throw FileLoadError.decodingFailed
    }
}
