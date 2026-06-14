import Foundation

/// Summary metadata for an archive file, for the file-info panel's "Archive"
/// section (TSK-807). Reuses the read-only `ArchiveCatalog` listing (system
/// `unzip`/`tar`, no deps). Returns `[]` for a non-archive or an unreadable
/// archive, so a misdetected file degrades quietly.
///
/// Pure-ish (filesystem + system tools) and host-testable against a real
/// fixture archive — see `ArchiveFileInfoTests`.
public enum ArchiveFileInfo {

    public struct Row: Equatable, Sendable {
        public let label: String
        public let value: String
        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    /// Format, file count (with a `+` when the listing was capped), folder
    /// count (omitted when zero), and total uncompressed size where the lister
    /// reports per-entry sizes (zip; tar kinds list name-only).
    public static func summaryRows(for url: URL) -> [Row] {
        guard let kind = ArchiveCatalog.kind(for: url) else { return [] }
        guard let listing = try? ArchiveCatalog.list(url) else { return [] }

        var out: [Row] = []
        out.append(Row("Format", kindLabel(kind)))

        let files = listing.entries.filter { !$0.isDirectory }
        let folders = listing.entries.filter { $0.isDirectory }
        out.append(Row("Files", "\(files.count)\(listing.truncated ? "+" : "")"))
        if !folders.isEmpty {
            out.append(Row("Folders", "\(folders.count)"))
        }

        let sizes = files.compactMap { $0.sizeBytes }
        if !sizes.isEmpty {
            let total = sizes.reduce(0, +)
            out.append(Row("Uncompressed",
                           ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)))
        }
        return out
    }

    private static func kindLabel(_ kind: ArchiveCatalog.Kind) -> String {
        switch kind {
        case .zip:    return "Zip"
        case .tar:    return "Tar"
        case .tarGz:  return "Tar (gzip)"
        case .tarBz2: return "Tar (bzip2)"
        }
    }
}
