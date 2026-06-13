import SwiftUI
import ViewerCore

/// TSK-311 — the archive `.preview` lens: a read-only entry listing for
/// zip/jar/tar/tgz/tbz2 tabs. Double-click a file entry to extract it
/// (single entry, stdout pipe — see `ArchiveCatalog`'s zip-slip notes)
/// into a temp file and open it through the normal open path.
///
/// Listing + extraction both run OFF-MAIN (subprocesses); the view shows
/// a progress / error envelope meanwhile. No mutation of the archive —
/// this is a viewer lens, not an archive manager.
struct ArchiveBrowserView: View {
    let url: URL
    let uiScale: CGFloat
    /// The app's open hook (the same one the image sibling-browser uses).
    /// nil (e.g. a future embedding without open support) hides the
    /// double-click affordance but keeps the listing readable.
    let onOpenEntry: ((URL) -> Void)?

    @State private var entries: [ArchiveCatalog.Entry] = []
    @State private var truncated = false
    @State private var loadError: String?
    @State private var loading = true
    @State private var extracting: String?   // entry name mid-extract

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                Spacer()
                ProgressView("Reading archive…")
                Spacer()
            } else if let loadError {
                Spacer()
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                listing
            }
        }
        .task(id: url) { await load() }
        .accessibilityIdentifier("mdv.archive.browser")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "archivebox")
                .foregroundStyle(Palette.secondaryLabel)
            Text(url.lastPathComponent)
                .font(.system(size: 12 * uiScale, weight: .semibold))
            Spacer()
            Text(truncated
                 ? "\(entries.count)+ entries (truncated)"
                 : "\(entries.count) entries")
                .font(.system(size: 11 * uiScale))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Palette.windowBackground)
    }

    private var listing: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    row(entry)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func row(_ entry: ArchiveCatalog.Entry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .font(.system(size: 11 * uiScale))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(entry.name)
                .font(.system(size: 12 * uiScale, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            if extracting == entry.name {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 8)
            if let size = entry.sizeBytes {
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(size), countStyle: .file))
                    .font(.system(size: 10 * uiScale))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openEntry(entry) }
        .help(entry.isDirectory ? entry.name : "Double-click to extract and open")
        .accessibilityIdentifier("mdv.archive.entry.\(entry.name)")
    }

    private func load() async {
        loading = true
        loadError = nil
        let target = url
        let result: Result<(entries: [ArchiveCatalog.Entry], truncated: Bool), Error> =
            await Task.detached(priority: .userInitiated) {
                Result { try ArchiveCatalog.list(target) }
            }.value
        switch result {
        case .success(let listing):
            entries = listing.entries
            truncated = listing.truncated
        case .failure(let error):
            loadError = "Could not read the archive (\(error))."
        }
        loading = false
    }

    private func openEntry(_ entry: ArchiveCatalog.Entry) {
        guard !entry.isDirectory, let onOpenEntry, extracting == nil else { return }
        extracting = entry.name
        let archive = url
        let name = entry.name
        Task {
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                Result { try ArchiveCatalog.extractEntry(named: name, from: archive) }
            }.value
            extracting = nil
            if case .success(let tempURL) = result {
                onOpenEntry(tempURL)
            }
        }
    }
}
