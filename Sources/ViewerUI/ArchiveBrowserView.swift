import SwiftUI
import ViewerCore

/// TSK-311 / TSK-1469 — the archive `.preview` lens: a read-only entry
/// listing (left) with a live PREVIEW pane (right) and a visible EXTRACT
/// affordance for zip/jar/tar/tgz/tbz2 tabs. Single-click selects an entry
/// and peeks it (text/image/binary/too-big, via `ArchiveEntryPreview`);
/// "Extract & Open" (or double-click) extracts the single entry into a temp
/// file and opens it through the normal open path.
///
/// Listing, preview reads, and extraction all run OFF-MAIN (subprocesses /
/// capped file reads); the view shows progress / error envelopes meanwhile.
/// No mutation of the archive — this is a viewer lens, not an archive manager.
struct ArchiveBrowserView: View {
    let url: URL
    let uiScale: CGFloat
    /// The app's open hook (the same one the image sibling-browser uses).
    /// nil hides the extract/open affordance but keeps listing + preview.
    let onOpenEntry: ((URL) -> Void)?

    @State private var entries: [ArchiveCatalog.Entry] = []
    @State private var truncated = false
    @State private var loadError: String?
    @State private var loading = true
    @State private var extracting: String?          // entry name mid-extract
    @State private var selected: ArchiveCatalog.Entry?
    @State private var preview: ArchiveEntryPreview?
    @State private var previewLoading = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                Spacer(); ProgressView("Reading archive…"); Spacer()
            } else if let loadError {
                Spacer()
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                HSplitView {
                    listing.frame(minWidth: 220)
                    detail.frame(minWidth: 240)
                }
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
        .background(selected?.id == entry.id
            ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openEntry(entry) }
        .onTapGesture(count: 1) { select(entry) }
        .help(entry.isDirectory ? entry.name : "Click to preview · double-click to extract & open")
        .accessibilityIdentifier("mdv.archive.entry.\(entry.name)")
    }

    // MARK: - detail / preview pane

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let selected {
                detailHeader(selected)
                Divider()
                ScrollView { previewBody }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
                Text("Select an entry to preview")
                    .font(.system(size: 12 * uiScale))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .accessibilityIdentifier("mdv.archive.preview")
    }

    private func detailHeader(_ entry: ArchiveCatalog.Entry) -> some View {
        HStack(spacing: 8) {
            Text((entry.name as NSString).lastPathComponent)
                .font(.system(size: 12 * uiScale, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            if !entry.isDirectory, onOpenEntry != nil {
                Button {
                    openEntry(entry)
                } label: {
                    Label("Extract & Open", systemImage: "arrow.up.doc")
                }
                .controlSize(.small)
                .disabled(extracting != nil)
                .accessibilityIdentifier("mdv.archive.extract")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var previewBody: some View {
        if previewLoading {
            ProgressView("Loading preview…").padding()
        } else {
            switch preview {
            case .text(let s, let truncated):
                VStack(alignment: .leading, spacing: 4) {
                    if truncated {
                        Text("Preview truncated (first \(ArchiveEntryPreview.previewCap / 1024) KB)")
                            .font(.system(size: 10 * uiScale)).foregroundStyle(.secondary)
                    }
                    Text(s)
                        .font(.system(size: 11 * uiScale, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
            case .image(let data, _):
                if let img = NSImage(data: data) {
                    Image(nsImage: img).resizable().scaledToFit().padding(12)
                } else {
                    previewNote("Image data could not be decoded.")
                }
            case .binary(let n):
                previewNote("Binary file — \(byteStr(n)). Extract to open it.")
            case .tooBig(let n):
                previewNote("Too large to preview inline (\(byteStr(n))). Extract to open it.")
            case .unreadable(let reason):
                previewNote(reason)
            case nil:
                previewNote("No preview.")
            }
        }
    }

    private func previewNote(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11 * uiScale))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    private func byteStr(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    // MARK: - actions

    private func select(_ entry: ArchiveCatalog.Entry) {
        selected = entry
        preview = nil
        // The listing's declared size decides whether we extract at all
        // (huge entries never get pulled just to peek — TSK-1469).
        switch ArchiveEntryPreview.previewPlan(
            sizeBytes: entry.sizeBytes, isDirectory: entry.isDirectory) {
        case .skip(let p):
            preview = p
        case .read:
            loadPreview(entry)
        }
    }

    private func loadPreview(_ entry: ArchiveCatalog.Entry) {
        previewLoading = true
        let archive = url
        let name = entry.name
        let size = entry.sizeBytes
        Task {
            let result: ArchiveEntryPreview = await Task.detached(priority: .userInitiated) {
                do {
                    let tmp = try ArchiveCatalog.extractEntry(named: name, from: archive)
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    let bytes = Self.cappedRead(tmp, cap: ArchiveEntryPreview.previewCap + 1)
                    return ArchiveEntryPreview.classify(name: name, bytes: bytes, fullSize: size)
                } catch {
                    return ArchiveEntryPreview.failed(error)
                }
            }.value
            // Ignore a stale load if the selection moved on.
            guard selected?.name == name else { return }
            preview = result
            previewLoading = false
        }
    }

    /// Read at most `cap` bytes from `url` — a peek, never the whole file.
    nonisolated private static func cappedRead(_ url: URL, cap: Int) -> Data {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? h.close() }
        return (try? h.read(upToCount: cap)) ?? Data()
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
