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
    /// Browsable archive (zip/jar/tar/tgz/tbz2 — TSK-311). Rendered via
    /// the `.preview` lens as an entry listing; HEX stays the raw lens.
    case archive
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
        "txt", "text", "log", "csv", "tsv",
        // TSK-1036: .rtf/.docx/.ods route to the source view; the loader
        // substitutes the EXTRACTED content (RtfTextExtractor / DocxTextExtractor
        // / ODSContentParser → TSV) as a READ-ONLY view (TSK-1204), so the raw
        // `{\rtf1...}` / OOXML/ODF ZIP never shows and a save can't overwrite the
        // source. (.xlsx follows.)
        "rtf", "docx", "ods",
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
    /// Conventional project files identified by their WHOLE name (they have
    /// no useful extension): build files → `.code` (worth highlighting),
    /// dotfiles / docs → `.plainText`. Keyed on the lowercased
    /// `lastPathComponent`, checked BEFORE extension rules so e.g. `Makefile`
    /// (ext "") upgrades from plain text to code. A file like `README.md`
    /// (lastPathComponent "readme.md") doesn't match "readme" → still markdown.
    private static let knownBasenames: [String: FileCategory] = [
        "dockerfile": .code, "containerfile": .code, "makefile": .code,
        "cmakelists.txt": .code, "rakefile": .code, "gemfile": .code,
        "podfile": .code, "brewfile": .code, "vagrantfile": .code,
        "justfile": .code, "procfile": .plainText, "caddyfile": .code,
        ".gitignore": .plainText, ".gitattributes": .plainText,
        ".dockerignore": .plainText, ".editorconfig": .plainText,
        ".env": .plainText, ".npmrc": .plainText, ".nvmrc": .plainText,
        ".gitconfig": .plainText, ".prettierrc": .code, ".eslintrc": .code,
        ".babelrc": .code, ".bashrc": .code, ".zshrc": .code,
        ".bash_profile": .code, ".zprofile": .code, ".profile": .code,
        ".inputrc": .plainText, ".curlrc": .plainText, ".wgetrc": .plainText,
        "license": .plainText, "licence": .plainText, "readme": .plainText,
        "changelog": .plainText, "authors": .plainText, "notice": .plainText,
        "copying": .plainText, "todo": .plainText, "contributors": .plainText,
        "codeowners": .plainText, "version": .plainText,
    ]
    /// Plain-text-ish config/lock extensions not worth a code grammar — keep
    /// them out of the WKWebView/CM6 editor path; they render in the cheap
    /// NSTextView source view. (Owner ask: allow-list known plain-text formats.)
    private static let configExtensions: Set<String> = [
        "conf", "config", "ini", "cfg", "properties", "prefs", "env",
        "lock", "list", "dockerignore", "gitignore", "gitattributes",
        "editorconfig", "npmrc", "nvmrc", "terraformrc", "dist", "sample",
        "example", "tmpl", "template", "resolved", "sum", "pem", "crt", "csr",
    ]

    public static func category(for url: URL) -> FileCategory {
        // Whole-name match first (catches extension-less project files +
        // dotfiles, and upgrades Makefile/Dockerfile to code).
        if let byName = knownBasenames[url.lastPathComponent.lowercased()] {
            return byName
        }
        let ext = url.pathExtension.lowercased()

        if mermaidExtensions.contains(ext) { return .mermaid }
        if markdownExtensions.contains(ext) { return .markdown }
        if plainTextExtensions.contains(ext) { return .plainText }
        if configExtensions.contains(ext) { return .plainText }
        if htmlExtensions.contains(ext) { return .html }
        if codeExtensions.contains(ext) { return .code }
        if imageExtensions.contains(ext) { return .image }
        if audioExtensions.contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        if ext == "pdf" { return .pdf }
        if sqliteExtensions.contains(ext) { return .sqlite }
        // Archives (TSK-311). Two-part extensions (.tar.gz/.tar.bz2) don't
        // round-trip through `pathExtension`, so match on the whole name —
        // the same suffix set ArchiveCatalog.kind serves.
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") || name.hasSuffix(".jar")
            || name.hasSuffix(".tar") || name.hasSuffix(".tgz")
            || name.hasSuffix(".tar.gz") || name.hasSuffix(".tbz2")
            || name.hasSuffix(".tar.bz2") {
            return .archive
        }

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
