import AppKit
import AVFoundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import ViewerCore
import ViewerKit

/// Right-rail metadata panel shown for files that don't have a Source
/// view (images, audio, video, PDFs, generic binaries). Surfaces basic
/// filesystem attributes plus type-specific details fetched lazily.
/// Observable state for the panel's lazy SHA-256 section (TSK-505 part B).
/// Split out of the view so (1) the idle→computing→done/failed machine is
/// HOST-testable without rendering, and (2) the live instance is reachable
/// by the script harness (`metadata-compute-checksum`), which invokes the
/// EXACT `compute()` the panel's button is wired to — the testing mandate's
/// sanctioned fallback where in-process SwiftUI event synthesis is
/// impossible (LESSONS "in-process event synthesis"; same shape as
/// `GitPanelModel.live`).
@MainActor
final class MetadataChecksumModel: ObservableObject {
    enum State: Equatable {
        case idle, computing, done(String), failed
    }
    @Published private(set) var state: State = .idle {
        didSet { if case .done = state {} else { justCopied = false } }
    }
    /// The algorithm `compute()` will hash with. Defaults to SHA-256 (the
    /// historical single-algo behavior); the panel offers the full
    /// `ChecksumAlgorithm` set (TSK-748).
    @Published private(set) var algorithm: ChecksumAlgorithm = .sha256
    /// Transient "Copied!" affordance for the copy button (TSK-748). Set by
    /// `copyHash()`; the view shows it briefly then calls
    /// `acknowledgeCopiedFeedback()`. Cleared whenever the hash leaves `.done`.
    @Published private(set) var justCopied = false
    private(set) var url: URL?
    private let pasteboard: PasteboardIO

    /// Most recently mounted panel's model — the script-verb seam.
    private(set) static weak var live: MetadataChecksumModel?
    /// `pasteboard` is injectable so the copy action is host-testable without
    /// clobbering the developer's real `NSPasteboard.general`.
    init(pasteboard: PasteboardIO = SystemPasteboard()) {
        self.pasteboard = pasteboard
        Self.live = self
    }

    /// New file ⇒ drop any prior hash. Idempotent for the same URL so a
    /// re-render doesn't clear a computed hash.
    func configure(url: URL) {
        guard url != self.url else { return }
        self.url = url
        state = .idle
    }

    /// Switch the active algorithm. A different algorithm ⇒ any displayed hash
    /// is now for the WRONG algorithm, so drop it back to `.idle` (the user
    /// recomputes). Idempotent for the same algorithm so a re-render doesn't
    /// clear a computed hash.
    func select(algorithm: ChecksumAlgorithm) {
        guard algorithm != self.algorithm else { return }
        self.algorithm = algorithm
        state = .idle
    }

    /// Copy the computed hash to the pasteboard and raise the transient
    /// "Copied!" feedback. No-op unless a hash is currently displayed.
    func copyHash() {
        guard case .done(let hex) = state else { return }
        pasteboard.writeString(hex)
        justCopied = true
    }

    /// The view calls this after the brief feedback window elapses.
    func acknowledgeCopiedFeedback() { justCopied = false }

    /// The "Compute" button's action. Hashes OFF the main thread (a large
    /// file's disk read must not block the UI — cf. TSK-214). The identity
    /// guard drops a STALE completion: without it an in-flight hash finishing
    /// after a file switch OR an algorithm switch would overwrite the current
    /// `.idle` with a hash for the wrong file/algorithm.
    func compute() {
        guard let target = url else { return }
        let algo = algorithm
        state = .computing
        Task { [weak self] in
            let hex = await Self.hashOffMain(target, algorithm: algo)
            guard let self, self.url == target, self.algorithm == algo else { return }
            self.state = hex.map(State.done) ?? .failed
        }
    }

    nonisolated private static func hashOffMain(_ url: URL,
                                                algorithm: ChecksumAlgorithm) async -> String? {
        await Task.detached(priority: .userInitiated) {
            try? FileChecksum.hex(ofFileAt: url, algorithm: algorithm)
        }.value
    }
}

struct MetadataPanel: View {
    let url: URL
    let category: FileCategory
    /// Unified UI zoom (`DocumentModel.zoom`) — scales the metadata text + label
    /// column so the file info tracks the rest of the app chrome (TSK-271).
    var uiScale: CGFloat = 1.0

    @State private var rows: [Row] = []
    @State private var loadTask: Task<Void, Never>?

    /// Lazy file SHA-256 (TSK-505 part B) — see `MetadataChecksumModel`.
    @StateObject private var checksumModel = MetadataChecksumModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("File") {
                    ForEach(filesystemRows) { row($0) }
                }
                if !rows.isEmpty {
                    section(typeLabel) {
                        ForEach(rows) { row($0) }
                    }
                }
                section("Checksum") { checksumContent }
            }
            .padding(12)
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        .background(Palette.windowBackground.opacity(0.6))
        .overlay(alignment: .leading) {
            Rectangle().fill(Palette.separator).frame(width: 0.5)
        }
        .task(id: url) {
            // `.task(id:)` already cancels the previous task on URL
            // change — but the *detached* tasks we kick off inside
            // `loadTypeMetadata` are NOT bound to this cooperative
            // scope. Track + cancel them explicitly so rapid tab
            // flips don't pile up AVAsset / ImageIO work.
            loadTask?.cancel()
            checksumModel.configure(url: url)   // new file ⇒ drop any prior hash
            loadTask = Task { await loadTypeMetadata() }
            await loadTask?.value
        }
    }

    // MARK: - Checksum (lazy, off-main) — TSK-505 part B

    @ViewBuilder
    private var checksumContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Algorithm picker (TSK-748). Changing it drops any displayed hash
            // back to .idle so the user recomputes for the new algorithm.
            Picker("Algorithm", selection: Binding(
                get: { checksumModel.algorithm },
                set: { checksumModel.select(algorithm: $0) }
            )) {
                ForEach(ChecksumAlgorithm.allCases, id: \.self) { algo in
                    Text(algo.label).tag(algo)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .font(.system(size: 10 * uiScale))
            .accessibilityIdentifier("mdv.metadata.checksumAlgorithm")

            checksumStateContent
        }
        // Group as an AX container so the child controls (the algorithm Picker,
        // compute/copy buttons) surface to an out-of-process AX reader — a bare
        // `.accessibilityIdentifier` on a leaf isn't promoted (the empty-state /
        // VM-lane lesson). The VM render guard for TSK-748 depends on this.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mdv.metadata.checksumSection")
    }

    @ViewBuilder
    private var checksumStateContent: some View {
        let label = checksumModel.algorithm.label
        switch checksumModel.state {
        case .idle:
            Button("Compute \(label)") { checksumModel.compute() }
                .font(.system(size: 10 * uiScale))
                .buttonStyle(.link)
                .accessibilityIdentifier("mdv.metadata.computeChecksum")
        case .computing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Computing \(label)…")
                    .font(.system(size: 10 * uiScale))
                    .foregroundStyle(.secondary)
            }
        case .done(let hex):
            VStack(alignment: .leading, spacing: 4) {
                row(Row(label, hex))
                Button(checksumModel.justCopied ? "Copied!" : "Copy") {
                    checksumModel.copyHash()
                }
                .font(.system(size: 10 * uiScale))
                .buttonStyle(.link)
                .foregroundStyle(checksumModel.justCopied ? Color.green : Color.accentColor)
                .accessibilityIdentifier("mdv.metadata.copyChecksum")
                .task(id: checksumModel.justCopied) {
                    // Brief "Copied!" confirmation, then revert. Bound to the
                    // flag so each copy restarts the window; cancellation on
                    // re-render is automatic via `.task(id:)`.
                    guard checksumModel.justCopied else { return }
                    try? await Task.sleep(for: .milliseconds(1200))
                    if !Task.isCancelled { checksumModel.acknowledgeCopiedFeedback() }
                }
            }
        case .failed:
            Text("Couldn’t read file")
                .font(.system(size: 10 * uiScale))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Filesystem rows (always present)

    private var filesystemRows: [Row] {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        return Self.filesystemRows(url: url, attrs: attrs)
    }

    /// Pure: build rows from a URL + the attribute dict you'd get from
    /// `FileManager.attributesOfItem(atPath:)`. Split out so tests can
    /// pass a synthetic dict without touching the real filesystem
    /// (and without depending on locale-specific date formatting in
    /// assertions).
    internal static func filesystemRows(url: URL, attrs: [FileAttributeKey: Any]) -> [Row] {
        var out: [Row] = []
        out.append(Row("Name", url.lastPathComponent))
        out.append(Row("Path", url.path))
        if let size = attrs[.size] as? Int {
            out.append(Row("Size", ByteCountFormatter.string(fromByteCount: Int64(size),
                                                              countStyle: .file)))
        }
        if let modified = attrs[.modificationDate] as? Date {
            out.append(Row("Modified", DisplayDateFormatter.string(from: modified)))
        }
        if let created = attrs[.creationDate] as? Date {
            out.append(Row("Created", DisplayDateFormatter.string(from: created)))
        }
        // Deep filesystem metadata (TSK-348) — all already present in the
        // `attributesOfItem` dict; surfaced here. Each guarded so a sparse
        // dict (or a synthetic test fixture) only emits what it carries.
        if let mode = attrs[.posixPermissions] as? Int {
            out.append(Row("Permissions", posixModeString(mode)))
        }
        if let owner = attrs[.ownerAccountName] as? String, !owner.isEmpty {
            out.append(Row("Owner", owner))
        }
        if let group = attrs[.groupOwnerAccountName] as? String, !group.isEmpty {
            out.append(Row("Group", group))
        }
        // Only when there's MORE than one hard link — "Hard links: 1" is the
        // normal case and would be noise on every file.
        if let links = attrs[.referenceCount] as? Int, links > 1 {
            out.append(Row("Hard links", "\(links)"))
        }
        if let inode = attrs[.systemFileNumber] as? Int {
            out.append(Row("Inode", "\(inode)"))
        }
        if let utType = UTType(filenameExtension: url.pathExtension) {
            out.append(Row("UTI", utType.identifier))
        }
        return out
    }

    /// POSIX permission bits → `"644 rw-r--r--"` (octal + symbolic), the
    /// `ls -l` style. Masks to the low 9 permission bits (type/setuid bits
    /// dropped). Pure — host-tested.
    internal static func posixModeString(_ mode: Int) -> String {
        let perms = mode & 0o777
        func rwx(_ bits: Int) -> String {
            (bits & 0b100 != 0 ? "r" : "-")
                + (bits & 0b010 != 0 ? "w" : "-")
                + (bits & 0b001 != 0 ? "x" : "-")
        }
        let symbolic = rwx((perms >> 6) & 0b111)
            + rwx((perms >> 3) & 0b111)
            + rwx(perms & 0b111)
        return "\(String(perms, radix: 8)) \(symbolic)"
    }

    // MARK: - Type-specific (lazy)

    private var typeLabel: String {
        switch category {
        case .image: return "Image"
        case .audio: return "Audio"
        case .video: return "Video"
        case .pdf:   return "PDF"
        case .sqlite: return "Database"
        case .archive: return "Archive"
        case .binary: return "Binary"
        default: return "Metadata"
        }
    }

    private func loadTypeMetadata() async {
        let new: [Row]
        switch category {
        case .image:  new = await Self.imageMetadata(url: url)
        case .audio, .video: new = await Self.avMetadata(url: url)
        case .pdf:    new = Self.pdfMetadata(url: url)
        case .sqlite: new = await Self.sqliteMetadata(url: url)
        case .archive: new = await Self.archiveMetadata(url: url)
        default:      new = []
        }
        await MainActor.run { self.rows = new }
    }

    private static func imageMetadata(url: URL) async -> [Row] {
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
            return imageRows(props: props)
        }.value
    }

    /// Maps a `CGImageSource` properties dict to display rows: core image
    /// attrs + a useful EXIF / TIFF / GPS subset (TSK-348 deep metadata).
    /// Pure (no I/O) so it is host-testable with synthetic dicts. `nonisolated`
    /// because `imageMetadata` calls it from a detached (off-main) task.
    nonisolated internal static func imageRows(props: [CFString: Any]) -> [Row] {
        var out: [Row] = []
        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            out.append(Row("Dimensions", "\(w) × \(h)"))
        }
        if let color = props[kCGImagePropertyColorModel] as? String {
            out.append(Row("Color model", color))
        }
        if let depth = props[kCGImagePropertyDepth] as? Int {
            out.append(Row("Bit depth", "\(depth)"))
        }
        if let dpi = props[kCGImagePropertyDPIWidth] as? Int {
            out.append(Row("DPI", "\(dpi)"))
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let when = exif[kCGImagePropertyExifDateTimeOriginal] as? String, !when.isEmpty {
                out.append(Row("Date taken", when))
            }
            if let lens = exif[kCGImagePropertyExifLensModel] as? String, !lens.isEmpty {
                out.append(Row("Lens", lens))
            }
            if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
                out.append(Row("Focal length", String(format: "%g mm", focal)))
            }
            if let iso = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int],
               let first = iso.first { out.append(Row("ISO", "\(first)")) }
            // Guard exposure > 0 — a 0 here would divide-by-zero into "1/inf s".
            if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
                out.append(Row("Exposure", String(format: "1/%.0f s", 1.0 / exposure)))
            }
            if let aperture = exif[kCGImagePropertyExifFNumber] as? Double {
                out.append(Row("Aperture", String(format: "f/%.1f", aperture)))
            }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            if let make = tiff[kCGImagePropertyTIFFMake] as? String,
               let model = tiff[kCGImagePropertyTIFFModel] as? String {
                out.append(Row("Camera", "\(make) \(model)"))
            }
            if let software = tiff[kCGImagePropertyTIFFSoftware] as? String, !software.isEmpty {
                out.append(Row("Software", software))
            }
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let coord = gpsCoordinate(gps) {
            out.append(Row("GPS", coord))
        }
        return out
    }

    /// Formats the EXIF GPS dict to `"37.774900 N, 122.419400 W"`. The dict
    /// stores magnitudes plus N/S/E/W refs; falls back to sign when a ref is
    /// absent. Returns nil when lat/long aren't both present. Pure.
    nonisolated internal static func gpsCoordinate(_ gps: [CFString: Any]) -> String? {
        guard let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? (lat >= 0 ? "N" : "S")
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? (lon >= 0 ? "E" : "W")
        return String(format: "%.6f %@, %.6f %@", abs(lat), latRef, abs(lon), lonRef)
    }

    private static func avMetadata(url: URL) async -> [Row] {
        await Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: url)
            var out: [Row] = []
            if let duration = try? await asset.load(.duration) {
                let s = CMTimeGetSeconds(duration)
                if s.isFinite { out.append(Row("Duration", formatDuration(s))) }
            }
            let tracks = (try? await asset.load(.tracks)) ?? []
            if let video = tracks.first(where: { $0.mediaType == .video }) {
                if let size = try? await video.load(.naturalSize) {
                    out.append(Row("Dimensions", "\(Int(size.width)) × \(Int(size.height))"))
                }
                if let frameRate = try? await video.load(.nominalFrameRate) {
                    out.append(Row("Frame rate", String(format: "%.2f fps", frameRate)))
                }
                // TSK-348: video codec from the format description's FourCC.
                if let fds = try? await video.load(.formatDescriptions), let d = fds.first {
                    out.append(Row("Video codec",
                                   MediaCodecName.display(fourCC: CMFormatDescriptionGetMediaSubType(d))))
                }
            }
            if let audio = tracks.first(where: { $0.mediaType == .audio }) {
                if let formatDescs = try? await audio.load(.formatDescriptions),
                   let desc = formatDescs.first {
                    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
                    if let sampleRate = asbd?.pointee.mSampleRate {
                        out.append(Row("Sample rate", "\(Int(sampleRate)) Hz"))
                    }
                    if let channels = asbd?.pointee.mChannelsPerFrame {
                        out.append(Row("Channels", "\(channels)"))
                    }
                    // TSK-348: audio codec from the format description's FourCC.
                    out.append(Row("Audio codec",
                                   MediaCodecName.display(fourCC: CMFormatDescriptionGetMediaSubType(desc))))
                }
            }
            // Common tags (Title / Artist / Album / Year) — TSK-807. AVMetadata's
            // common-key space normalizes ID3 / iTunes / Vorbis into shared keys;
            // the pure ordering/omission/year logic is host-tested in
            // `AudioMetadataRows`.
            if let common = try? await asset.load(.commonMetadata) {
                var pairs: [(key: String, value: String?)] = []
                for item in common {
                    guard let key = item.commonKey?.rawValue else { continue }
                    let value = (try? await item.load(.stringValue)) ?? nil
                    pairs.append((key, value))
                }
                out.append(contentsOf: AudioMetadataRows.build(common: pairs).map { Row($0.label, $0.value) })
            }
            return out
        }.value
    }

    /// SQLite "Database" section (TSK-807) — object counts + total rows +
    /// encoding/page-size, read off-main via the pure `SQLiteFileInfo`.
    private static func sqliteMetadata(url: URL) async -> [Row] {
        await Task.detached(priority: .userInitiated) {
            SQLiteFileInfo.summaryRows(for: url).map { Row($0.label, $0.value) }
        }.value
    }

    /// Archive "Archive" section (TSK-807) — format + file/folder counts +
    /// uncompressed size, read off-main via the pure `ArchiveFileInfo`.
    private static func archiveMetadata(url: URL) async -> [Row] {
        await Task.detached(priority: .userInitiated) {
            ArchiveFileInfo.summaryRows(for: url).map { Row($0.label, $0.value) }
        }.value
    }

    /// Extracted PDF metadata, decoupled from PDFKit so the row-building is
    /// pure + host-testable (TSK-348). Empty/absent fields are `nil`.
    struct PDFInfo: Equatable {
        var pageCount: Int = 0
        var title: String?
        var author: String?
        var subject: String?
        var creator: String?
        var producer: String?
        var keywords: String?
        var created: Date?
        var modified: Date?
        var isEncrypted: Bool = false
        var pageSize: String?       // e.g. "612 × 792 pt" (page 1 media box)
    }

    nonisolated internal static func pdfMetadata(url: URL) -> [Row] {
        guard let doc = PDFDocument(url: url) else { return [] }
        var info = PDFInfo()
        info.pageCount = doc.pageCount
        info.isEncrypted = doc.isEncrypted
        if let attrs = doc.documentAttributes {
            func str(_ key: PDFDocumentAttribute) -> String? {
                guard let s = attrs[key] as? String, !s.isEmpty else { return nil }
                return s
            }
            info.title    = str(.titleAttribute)
            info.author   = str(.authorAttribute)
            info.subject  = str(.subjectAttribute)
            info.creator  = str(.creatorAttribute)
            info.producer = str(.producerAttribute)
            // Keywords may be a single String or an array of strings.
            if let kw = attrs[PDFDocumentAttribute.keywordsAttribute] as? String, !kw.isEmpty {
                info.keywords = kw
            } else if let arr = attrs[PDFDocumentAttribute.keywordsAttribute] as? [String],
                      !arr.isEmpty {
                info.keywords = arr.joined(separator: ", ")
            }
            info.created  = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date
            info.modified = attrs[PDFDocumentAttribute.modificationDateAttribute] as? Date
        }
        if let page = doc.page(at: 0) {
            let b = page.bounds(for: .mediaBox)
            if b.width > 0, b.height > 0 {
                info.pageSize = "\(Int(b.width.rounded())) × \(Int(b.height.rounded())) pt"
            }
        }
        return pdfRows(info)
    }

    /// Pure mapping of `PDFInfo` → display rows (TSK-348). Page count always
    /// shows; the rest are omitted when absent. Host-testable with a synthetic
    /// `PDFInfo` (no PDFKit / file IO). `nonisolated` — called off-main.
    nonisolated internal static func pdfRows(_ info: PDFInfo) -> [Row] {
        var out: [Row] = [Row("Pages", "\(info.pageCount)")]
        if let v = info.title    { out.append(Row("Title", v)) }
        if let v = info.author   { out.append(Row("Author", v)) }
        if let v = info.subject  { out.append(Row("Subject", v)) }
        if let v = info.keywords { out.append(Row("Keywords", v)) }
        if let v = info.pageSize { out.append(Row("Page Size", v)) }
        if let d = info.created  { out.append(Row("Created", DisplayDateFormatter.string(from: d))) }
        if let d = info.modified { out.append(Row("Modified", DisplayDateFormatter.string(from: d))) }
        if let v = info.creator  { out.append(Row("Creator", v)) }
        if let v = info.producer { out.append(Row("Producer", v)) }
        if info.isEncrypted { out.append(Row("Encrypted", "Yes")) }
        return out
    }

    nonisolated private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Row plumbing

    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
        init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9 * uiScale, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            body()
        }
    }

    @ViewBuilder
    private func row(_ r: Row) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(r.label)
                .font(.system(size: 10 * uiScale))
                .foregroundStyle(.secondary)
                .frame(width: 80 * uiScale, alignment: .leading)
            Text(r.value)
                .font(.system(size: 10 * uiScale, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
