import Foundation
import UniformTypeIdentifiers

public enum FileCategory: String, Equatable, Sendable, CaseIterable {
    case markdown
    /// Standalone mermaid diagram (.mmd / .mermaid). Rendered through the
    /// same WKWebView path as markdown by wrapping the raw source in a
    /// single mermaid fenced block; see `HTMLRenderer.visitCodeBlock`.
    case mermaid
    case plainText
    case code
    case html
    case binary
    case image
    case audio
    case video
    case pdf
    case sqlite
    case unknown
}

public enum FileTypeDetector {
    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn"
    ]
    /// Standalone mermaid diagram files. Checked *before* markdown so
    /// `.mermaid` extension doesn't false-positive as markdown (it isn't
    /// in `markdownExtensions`, but list-order discipline is cheap).
    private static let mermaidExtensions: Set<String> = ["mmd", "mermaid"]
    private static let plainTextExtensions: Set<String> = [
        "txt", "text", "log", "csv", "tsv"
    ]
    private static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]
    private static let codeExtensions: Set<String> = [
        "swift", "py", "js", "ts", "jsx", "tsx", "go", "rs", "c", "cpp", "cc",
        "h", "hpp", "java", "kt", "rb", "sh", "zsh", "bash", "json", "yaml",
        "yml", "toml", "xml", "sql", "lua", "pl", "php", "scala", "clj", "ex"
    ]
    /// Image formats NSImageView can decode natively (no third-party
    /// libraries needed). HEIC/HEIF use Image I/O via NSImage.
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif",
        "webp", "ico", "icns", "svg"
    ]
    /// Audio formats AVPlayer supports out of the box.
    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus",
        "caf", "au"
    ]
    /// Video formats AVPlayer supports out of the box.
    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "avi", "mkv", "webm", "wmv", "flv", "mpg",
        "mpeg", "3gp"
    ]
    private static let sqliteExtensions: Set<String> = [
        "sqlite", "sqlite3", "db", "db3"
    ]

    public static func category(for url: URL) -> FileCategory {
        let ext = url.pathExtension.lowercased()

        if mermaidExtensions.contains(ext) { return .mermaid }
        if markdownExtensions.contains(ext) { return .markdown }
        if plainTextExtensions.contains(ext) { return .plainText }
        if htmlExtensions.contains(ext) { return .html }
        if codeExtensions.contains(ext) { return .code }
        if imageExtensions.contains(ext) { return .image }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        if ext == "pdf" { return .pdf }
        if sqliteExtensions.contains(ext) { return .sqlite }

        if ext.isEmpty {
            return .plainText
        }

        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .html) { return .html }
            if type.conforms(to: .sourceCode) { return .code }
            if type.conforms(to: .plainText) { return .plainText }
            if type.conforms(to: .image) { return .image }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .pdf) { return .pdf }
        }
        return .unknown
    }
}
