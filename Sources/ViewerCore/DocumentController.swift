import Foundation
import ViewerKit

public enum DocumentState: Equatable, Sendable {
    case empty
    case loaded(TextFile)
    case binary(BinaryFile)
    case error(LoadFailure)
    /// Native preview (image/audio/video/PDF). We don't need to read
    /// the file contents into Swift memory — the renderer (NSImageView
    /// / AVPlayer / PDFView) takes the URL directly and handles
    /// streaming itself. We just need to know the kind.
    case preview(URL, FileCategory)

    public struct LoadFailure: Equatable, Sendable {
        public let url: URL
        public let message: String

        public init(url: URL, message: String) {
            self.url = url
            self.message = message
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

    public static func message(for error: FileLoadError) -> String {
        switch error {
        case .fileNotFound:
            return "File not found."
        case .notReadable:
            return "File could not be read."
        case .decodingFailed:
            return "File is not valid UTF-8 or Latin-1 text."
        case .tooLarge(let bytes):
            let mb = Double(bytes) / 1_048_576.0
            // T9: pin to en-US-POSIX so "5.0 MB" doesn't become "5,0 MB" on fr_FR.
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
            let formatted = formatter.string(from: NSNumber(value: mb)) ?? "\(mb)"
            return "File is too large (\(formatted) MB)."
        case .binaryFile:
            return "File appears to be binary (contains NUL bytes)."
        }
    }
}
