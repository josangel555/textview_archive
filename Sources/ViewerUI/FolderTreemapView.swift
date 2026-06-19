import SwiftUI
import ViewerCore
import ViewerKit

/// Bundle-analyzer-style treemap of a folder's contents (TSK-506). Scans
/// the folder's immediate children (`FolderSizeStats.scan`, off-main),
/// lays them out as size-proportional rectangles
/// (`TreemapLayout.squarify`), and paints the rects + labels in a single
/// SwiftUI `Canvas`. Largest consumers dominate the area, so "what is
/// eating this folder" reads at a glance — the disk-usage analog of the
/// git-stats `FolderStatsView`.
///
/// Pure renderer over its `@StateObject` model: tile color comes from the
/// shared file-icon `IconCategory` palette (so a `.swift` tile matches its
/// sidebar chip), label legibility is size-gated (tiny tiles draw no text
/// rather than clipped noise). Rendering is `Canvas`-only — no per-tile
/// SwiftUI view — so a thousand-file folder stays one draw pass.
struct FolderTreemapView: View {
    @ObservedObject var doc: DocumentModel
    @StateObject private var model: FolderTreemapModel

    /// `folder` is the directory to analyze; the host supplies a fresh URL
    /// and the view reloads on change.
    init(doc: DocumentModel, folder: URL) {
        self.doc = doc
        _model = StateObject(wrappedValue: FolderTreemapModel(folder: folder))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if model.isLoading {
                loadingRow
            } else if model.stats?.entries.isEmpty ?? true {
                emptyRow
            } else {
                treemap
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.loadIfNeeded() }
        .onChange(of: model.folderKey) { _, _ in model.reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.folder.lastPathComponent)
                .font(.system(size: doc.uiSize(11), weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let stats = model.stats {
                Text(byteString(stats.totalBytes))
                    .font(.system(size: doc.uiSize(10), design: .monospaced))
                    .foregroundStyle(.secondary)
                if stats.truncated {
                    Text("partial")
                        .font(.system(size: doc.uiSize(8), weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Measuring folder…")
                .font(.system(size: doc.uiSize(11)))
                .foregroundStyle(.secondary)
        }
        .frame(height: 60)
    }

    private var emptyRow: some View {
        Text("This folder is empty.")
            .font(.system(size: doc.uiSize(11)))
            .foregroundStyle(.tertiary)
            .frame(height: 60)
    }

    // MARK: - Treemap canvas

    private var treemap: some View {
        // Square-ish aspect by default; the host can wrap in a frame to
        // resize. A fixed default height keeps it usable inline in a
        // sidebar card while still tiling whatever width it's given.
        let entries = model.stats?.entries ?? []
        return Canvas { ctx, size in
            let bounds = CGRect(origin: .zero, size: size)
            let tiles = TreemapLayout.squarify(
                entries.map { (id: $0.id, weight: Double($0.byteSize)) },
                in: bounds
            )
            let byID = Dictionary(
                uniqueKeysWithValues: entries.map { ($0.id, $0) })
            for tile in tiles {
                guard let e = byID[tile.id] else { continue }
                draw(tile: tile, entry: e, in: &ctx)
            }
        }
        .frame(height: 200)
        .background(Color(white: 0.5).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // Make the whole pipeline observable to a layout/proportion change
        // without re-decoding the file tree.
        .accessibilityLabel(Text(accessibilitySummary(entries)))
    }

    /// Paint one tile: filled rounded-rect in the category background,
    /// hairline border, and — when the tile is big enough — the name +
    /// size in the category foreground. Tiny tiles draw fill only.
    private func draw(
        tile: TreemapTile<String>,
        entry: FolderSizeEntry,
        in ctx: inout GraphicsContext
    ) {
        let rect = tile.rect.insetBy(dx: 1, dy: 1)
        guard rect.width > 0, rect.height > 0 else { return }
        let palette = Self.palette(for: entry)
        let shape = Path(roundedRect: rect, cornerRadius: 3)
        ctx.fill(shape, with: .color(palette.background))
        ctx.stroke(shape, with: .color(palette.foreground.opacity(0.25)), lineWidth: 0.5)

        // Only label tiles with room for at least the name line. Below
        // this threshold a label would clip into illegible noise.
        guard rect.width >= 44, rect.height >= 22 else { return }

        let nameText = Text(entry.name)
            .font(.system(size: max(8, doc.uiSize(10)), weight: .medium))
            .foregroundStyle(palette.foreground)
        var resolvedName = ctx.resolve(nameText)
        resolvedName.shading = .color(palette.foreground)
        ctx.draw(
            resolvedName,
            in: CGRect(x: rect.minX + 4, y: rect.minY + 3,
                       width: rect.width - 8, height: 14))

        // Size sub-line only when there's a second row to spare.
        if rect.height >= 36 {
            let sizeText = Text(byteString(entry.byteSize))
                .font(.system(size: max(7, doc.uiSize(9)), design: .monospaced))
                .foregroundStyle(palette.foreground.opacity(0.75))
            ctx.draw(
                ctx.resolve(sizeText),
                in: CGRect(x: rect.minX + 4, y: rect.minY + 17,
                           width: rect.width - 8, height: 12))
        }
    }

    // MARK: - Color / formatting

    /// Map a scanned entry to the shared file-icon palette so a treemap
    /// tile matches the file's sidebar chip color. Directories use the
    /// folder palette; files classify by extension via `FileIconClassifier`.
    static func palette(for entry: FolderSizeEntry) -> IconCategory.Pair {
        let url = URL(fileURLWithPath: entry.name)
        let kind = FileIconClassifier.icon(for: url, isDirectory: entry.isDirectory)
        switch kind {
        case .chip(_, let category), .glyph(_, let category):
            return category.palette
        case .folder(let state):
            return state.palette
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func accessibilitySummary(_ entries: [FolderSizeEntry]) -> String {
        let top = entries.prefix(3)
            .map { "\($0.name) \(byteString($0.byteSize))" }
            .joined(separator: ", ")
        return "Folder treemap. Largest: \(top)"
    }
}

/// View-model for `FolderTreemapView`. Lazy off-main scan; cancels a prior
/// scan before starting a new one. Narrow `@Published` surface, mirroring
/// `FolderStatsModel`.
@MainActor
final class FolderTreemapModel: ObservableObject {
    let folder: URL
    /// Stable identity for the current folder so the view can `.onChange`
    /// to detect a host-driven swap.
    let folderKey: String

    @Published private(set) var stats: FolderSizeStats?
    @Published private(set) var isLoading = false

    private var scanTask: Task<Void, Never>?
    private var loaded = false

    init(folder: URL) {
        self.folder = folder
        self.folderKey = folder.standardizedFileURL.path
    }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        reload()
    }

    func reload() {
        scanTask?.cancel()
        isLoading = true
        let target = folder
        scanTask = Task { @MainActor [weak self] in
            // Scan off the main actor — pure filesystem I/O + arithmetic.
            let result = await Task.detached(priority: .userInitiated) {
                FolderSizeStats.scan(
                    folder: target,
                    isCancelled: { Task.isCancelled })
            }.value
            guard let self, !Task.isCancelled else { return }
            self.stats = result
            self.isLoading = false
        }
    }
}
