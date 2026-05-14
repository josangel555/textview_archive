import Foundation
import UniformTypeIdentifiers

public enum FileCategory: String, Equatable, Sendable, CaseIterable {
    case markdown
    case plainText
    case code
    case html
    case binary
    case unknown
}

public enum FileTypeDetector {
    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn"
    ]
    private static let plainTextExtensions: Set<String> = [
        "txt", "text", "log", "csv", "tsv"
    ]
    private static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]
    private static let codeExtensions: Set<String> = [
        "swift", "py", "js", "ts", "jsx", "tsx", "go", "rs", "c", "cpp", "cc",
        "h", "hpp", "java", "kt", "rb", "sh", "zsh", "bash", "json", "yaml",
        "yml", "toml", "xml", "sql", "lua", "pl", "php", "scala", "clj", "ex"
    ]

    public static func category(for url: URL) -> FileCategory {
        let ext = url.pathExtension.lowercased()

        if markdownExtensions.contains(ext) { return .markdown }
        if plainTextExtensions.contains(ext) { return .plainText }
        if htmlExtensions.contains(ext) { return .html }
        if codeExtensions.contains(ext) { return .code }

        if ext.isEmpty {
            return .plainText
        }

        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .html) { return .html }
            if type.conforms(to: .sourceCode) { return .code }
            if type.conforms(to: .plainText) { return .plainText }
        }
        return .unknown
    }
}
