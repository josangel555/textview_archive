import Foundation

public struct BinaryFile: Sendable {
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

/// Equatable by metadata only — Data compare would be O(N) up to 4 MB.
extension BinaryFile: Equatable {
    public static func == (lhs: BinaryFile, rhs: BinaryFile) -> Bool {
        lhs.url == rhs.url
            && lhs.totalByteCount == rhs.totalByteCount
            && lhs.isTruncated == rhs.isTruncated
            && lhs.data.count == rhs.data.count
    }
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
        // Guard the (symlink-resolved) target is a *regular* file before we
        // open a handle. `fileExists` is true for directories, fifos,
        // sockets and devices too; opening one of those for a length-capped
        // `readData` can block forever (a fifo with no writer) or mislead the
        // truncation logic. `attributesOfItem(atPath:)` `lstat`s — it does
        // NOT follow symlinks — so resolve first, then check the *target*'s
        // type. `link -> regular` is accepted; `link -> dir`, fifo, socket
        // and device are rejected as not-readable. We do all subsequent work
        // (open + size) against the resolved path so a symlink swapped between
        // the guard and the open (TOCTOU) can't redirect us to a non-regular
        // target.
        let resolvedURL = url.resolvingSymlinksInPath()
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path)
        guard (attrs?[.type] as? FileAttributeType) == .typeRegular else {
            throw FileLoadError.notReadable
        }
        let data: Data
        let readMore: Bool
        do {
            // Read at most maxBytes — Data(contentsOf:) doesn't take a length;
            // use FileHandle for a capped read. We read one byte *past* the
            // cap so truncation is derived from the read itself, not a
            // pre-stat size that a concurrent writer/truncation could make
            // stale (TOCTOU). If the extra byte comes back, the file is
            // larger than the cap and we drop it from the buffer.
            let handle = try FileHandle(forReadingFrom: resolvedURL)
            defer { try? handle.close() }
            let buf = handle.readData(ofLength: maxBytes + 1)
            readMore = buf.count > maxBytes
            // Re-base to a 0-indexed `Data` (a `prefix` slice keeps the
            // parent's start index; downstream hex math assumes 0-based).
            data = readMore ? Data(buf.prefix(maxBytes)) : buf
        } catch {
            throw FileLoadError.notReadable
        }
        // `total` and `isTruncated` are reconciled off the read, not the
        // stat: the read is the source of truth for "is there more than we
        // have in the buffer". The stat is only consulted to put a *number*
        // on the banner when we know the file is bigger than the cap.
        let total: Int
        if readMore {
            // File is larger than the cap. Use the stat size for the banner
            // figure, but never let it claim a size <= the buffer (a
            // concurrent shrink / unreliable stat must not contradict the
            // fact that we just read more than `data.count` bytes). Negative
            // sizes are clamped to 0 before the floor is applied.
            let statTotal = (attrs?[.size] as? Int).map { max($0, 0) } ?? 0
            total = max(statTotal, data.count + 1)
        } else {
            // We reached EOF within the cap — what we read *is* the whole
            // file. Keeping total == byteCount avoids an inconsistent
            // (total > byteCount, isTruncated == false) BinaryFile.
            total = data.count
        }
        return BinaryFile(
            url: url,
            data: data,
            totalByteCount: total,
            // Truncation is what the read told us, not the (possibly stale)
            // stat — `readMore` is authoritative.
            isTruncated: readMore
        )
    }
}
