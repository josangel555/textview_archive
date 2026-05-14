import Foundation

public struct BinaryFile: Equatable, Sendable {
    public let url: URL
    public let data: Data
    public let totalByteCount: Int
    public let isTruncated: Bool

    public init(url: URL, data: Data, totalByteCount: Int, isTruncated: Bool) {
        self.url = url
        self.data = data
        self.totalByteCount = totalByteCount
        self.isTruncated = isTruncated
    }

    public var byteCount: Int { data.count }
}

/// Reads up to `maxBytes` of the file into memory for the hex viewer.
/// Memory-mapped reads are a follow-up — today we cap reads at 4 MB so
/// the hex view stays responsive for ad-hoc binary inspection without
/// blowing main-thread memory.
public struct BinaryFileLoader: Sendable {
    public let maxBytes: Int

    public init(maxBytes: Int = 4 * 1024 * 1024) {
        self.maxBytes = maxBytes
    }

    public func load(url: URL) throws -> BinaryFile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FileLoadError.fileNotFound
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let total = (attrs?[.size] as? Int) ?? 0
        let data: Data
        do {
            // Read at most maxBytes — Data(contentsOf:) doesn't take a length;
            // use FileHandle for capped read.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = handle.readData(ofLength: maxBytes)
        } catch {
            throw FileLoadError.notReadable
        }
        return BinaryFile(
            url: url,
            data: data,
            totalByteCount: total,
            isTruncated: total > data.count
        )
    }
}
