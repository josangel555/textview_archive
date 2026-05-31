import Foundation
import ViewerKit

public enum DocumentState: Sendable {
    case empty
    case loaded(TextFile)
    case binary(BinaryFile)
    case error(LoadFailure)
    /// Native preview (image/audio/video/PDF). We don't need to read
    /// the file contents into Swift memory — the renderer (NSImageView
    /// / AVPlayer / PDFView) takes the URL directly and handles
    /// streaming itself. We just need to know the kind.
    case preview(URL, FileCategory)
    /// File materialization is in flight. Used when a lazy tab is
    /// selected and we kick the read on a background queue rather than
    /// blocking the main thread; the UI shows a placeholder while we
    /// transition to `.loaded` / `.binary` / `.error`. The URL is the
    /// file we're loading so the placeholder can name it.
    case loading(URL)

    public struct LoadFailure: Equatable, Sendable {
        public let url: URL
        public let message: String

        public init(url: URL, message: String) {
            self.url = url
            self.message = message
        }
    }
}

/// Equatable by (case, url, byteCount) — explicitly NOT by file
/// contents. Synthesized Equatable would O(N) compare the full file
/// bytes on every SwiftUI diff. Where deep content equality matters
/// (rare — file watcher reload), callers compare TextFile fields
/// directly.
extension DocumentState: Equatable {
    public static func == (lhs: DocumentState, rhs: DocumentState) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty):
            return true
        case (.loaded(let a), .loaded(let b)):
            return a.url == b.url
                && a.byteCount == b.byteCount
                && a.encoding == b.encoding
        case (.binary(let a), .binary(let b)):
            return a.url == b.url && a.byteCount == b.byteCount
        case (.error(let a), .error(let b)):
            return a == b
        case (.preview(let lu, let lc), .preview(let ru, let rc)):
            return lu == ru && lc == rc
        case (.loading(let lu), .loading(let ru)):
            return lu == ru
        default:
            return false
        }
    }
}

/// Loads a file URL into a `DocumentState`. Pure logic; no UI imports.
public struct DocumentController: Sendable {
    public let loader: TextFileLoader
    public let binaryLoader: BinaryFileLoader

    public init(
        loader: TextFileLoader = TextFileLoader(),
        binaryLoader: BinaryFileLoader = BinaryFileLoader()
    ) {
        self.loader = loader
        self.binaryLoader = binaryLoader
    }

    public func open(url: URL) -> DocumentState {
        // Native-preview fast path: detect by extension/UTI before
        // even attempting the text loader. Skips reading huge media
        // files into Swift memory just to fail-back to a viewer that
        // doesn't need the bytes anyway.
        let category = FileTypeDetector.category(for: url)
        switch category {
        case .image, .audio, .video, .pdf, .sqlite:
            // Only declare a preview if the file actually exists +
            // is readable; otherwise route to the error path.
            if FileManager.default.isReadableFile(atPath: url.path) {
                return .preview(url, category)
            } else {
                return .error(.init(url: url, message: "File could not be read."))
            }
        default:
            break
        }
        do {
            let file = try loader.load(url: url)
            return .loaded(file)
        } catch FileLoadError.binaryFile {
            // Seamless fall-through to the hex viewer.
            do {
                let binary = try binaryLoader.load(url: url)
                return .binary(binary)
            } catch let error as FileLoadError {
                return .error(.init(url: url, message: Self.message(for: error)))
            } catch {
                return .error(.init(url: url, message: "\(error)"))
            }
        } catch let error as FileLoadError {
            return .error(.init(url: url, message: Self.message(for: error)))
        } catch {
            return .error(.init(url: url, message: "\(error)"))
        }
    }

    /// T9: pinned to en-US-POSIX so "5.0 MB" doesn't become "5,0 MB" on
    /// fr_FR. Hoisted to a static — previously allocated per error.
    private static let mbFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    public static func message(for error: FileLoadError) -> String {
        switch error {
        case .fileNotFound:
            return "File not found."
        case .notReadable:
            return "File could not be read."
        case .decodingFailed:
            return "File is not valid UTF-8 or Latin-1 text."
        case .tooLarge(let bytes, let ceiling):
            let mb = Double(bytes) / 1_048_576.0
            let formatted = mbFormatter.string(from: NSNumber(value: mb)) ?? "\(mb)"
            // Express the ceiling in whole MB — it's a configured power-
            // of-two limit (512 MiB by default), so a clean integer reads
            // better than "512.0". Carrying the ceiling makes this read as
            // a hard cap, not an arbitrary refusal of a merely-big file.
            let ceilingMB = ceiling / 1_048_576
            return "File is too large (\(formatted) MB) — exceeds the \(ceilingMB) MB read limit."
        case .binaryFile:
            return "File appears to be binary (contains NUL bytes)."
        }
    }
}
