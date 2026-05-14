import Foundation

public enum DocumentState: Equatable, Sendable {
    case empty
    case loaded(TextFile)
    case error(LoadFailure)

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

    public init(loader: TextFileLoader = TextFileLoader()) {
        self.loader = loader
    }

    public func open(url: URL) -> DocumentState {
        do {
            let file = try loader.load(url: url)
            return .loaded(file)
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
            return String(format: "File is too large (%.1f MB).", mb)
        }
    }
}
