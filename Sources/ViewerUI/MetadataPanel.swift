import AppKit
import AVFoundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import ViewerKit

/// Right-rail metadata panel shown for files that don't have a Source
/// view (images, audio, video, PDFs, generic binaries). Surfaces basic
/// filesystem attributes plus type-specific details fetched lazily.
struct MetadataPanel: View {
    let url: URL
    let category: FileCategory

    @State private var rows: [Row] = []
    @State private var loadTask: Task<Void, Never>?

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
            }
            .padding(12)
        }
        .frame(width: 260)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 0.5)
        }
        .task(id: url) {
            // `.task(id:)` already cancels the previous task on URL
            // change — but the *detached* tasks we kick off inside
            // `loadTypeMetadata` are NOT bound to this cooperative
            // scope. Track + cancel them explicitly so rapid tab
            // flips don't pile up AVAsset / ImageIO work.
            loadTask?.cancel()
            loadTask = Task { await loadTypeMetadata() }
            await loadTask?.value
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
            out.append(Row("Modified", dateFmt.string(from: modified)))
        }
        if let created = attrs[.creationDate] as? Date {
            out.append(Row("Created", dateFmt.string(from: created)))
        }
        if let utType = UTType(filenameExtension: url.pathExtension) {
            out.append(Row("UTI", utType.identifier))
        }
        return out
    }

    internal static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: - Type-specific (lazy)

    private var typeLabel: String {
        switch category {
        case .image: return "Image"
        case .audio: return "Audio"
        case .video: return "Video"
        case .pdf:   return "PDF"
        case .sqlite: return "Database"
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
        default:      new = []
        }
        await MainActor.run { self.rows = new }
    }

    private static func imageMetadata(url: URL) async -> [Row] {
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
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
            // EXIF subset
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                if let cam = exif[kCGImagePropertyExifLensModel] as? String {
                    out.append(Row("Lens", cam))
                }
                if let iso = exif[kCGImagePropertyExifISOSpeedRatings] as? [Int],
                   let first = iso.first { out.append(Row("ISO", "\(first)")) }
                if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double {
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
            }
            return out
        }.value
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
                }
            }
            return out
        }.value
    }

    private static func pdfMetadata(url: URL) -> [Row] {
        guard let doc = PDFDocument(url: url) else { return [] }
        var out: [Row] = []
        out.append(Row("Pages", "\(doc.pageCount)"))
        if let attrs = doc.documentAttributes {
            if let title = attrs[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
                out.append(Row("Title", title))
            }
            if let author = attrs[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty {
                out.append(Row("Author", author))
            }
            if let producer = attrs[PDFDocumentAttribute.producerAttribute] as? String {
                out.append(Row("Producer", producer))
            }
        }
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
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            body()
        }
    }

    @ViewBuilder
    private func row(_ r: Row) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(r.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(r.value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
