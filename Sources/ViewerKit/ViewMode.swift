import Foundation

/// How a file is currently being displayed. The set of available
/// modes varies by file type; the always-on baseline is `source`
/// + `hex`, with `rendered` and `formatted` opt-in for files that
/// support them.
public enum ViewMode: String, Equatable, Sendable, CaseIterable, Codable {
    case rendered    // markdown only: WKWebView-rendered HTML
    case source      // every text file: NSTextView with syntax highlight
    case editor      // text files: editable NSTextView (in-memory buffer until ⌘S)
    case formatted   // JSON / XML / etc.: pretty-printed source
    case table       // csv / tsv: column-major grid
    case diff        // .diff / .patch: per-hunk colored DiffView
    case hex         // every file: byte grid
}

/// Computes which view modes are reachable for a given URL. Always
/// includes `.source` + `.hex`. Adds `.rendered` for markdown and
/// `.formatted` when the URL has a registered pretty-printer.
public enum ViewModeOptions {
    public static func availableModes(for url: URL?) -> [ViewMode] {
        guard let url else { return [.source, .hex] }
        var modes: [ViewMode] = [.source]
        let cat = FileTypeDetector.category(for: url)
        if cat == .markdown || cat == .mermaid { modes.insert(.rendered, at: 0) }
        if Self.supportsFormatting(url) { modes.append(.formatted) }
        // CSV / TSV files get a table mode. Default-on for these
        // extensions but `.source` stays available for raw-text view.
        if Self.supportsTable(url) { modes.insert(.table, at: 0) }
        // .diff / .patch files get the dedicated DiffView as default,
        // with `.source` still available for raw-text inspection.
        if Self.supportsDiff(url) { modes.insert(.diff, at: 0) }
        // Editor mode — editable plain-text buffer. Available for any
        // file we'd otherwise show as text; excluded for image / audio
        // / video / pdf / sqlite (which never have a text view to edit)
        // and for `.diff` files (editing a unified-diff representation
        // would silently desync from the actual repo state).
        if Self.supportsEditor(url) {
            // Slot right after `.source` so the picker reads
            // Source | Editor | Formatted | … from left to right.
            if let sourceIdx = modes.firstIndex(of: .source) {
                modes.insert(.editor, at: sourceIdx + 1)
            } else {
                modes.append(.editor)
            }
        }
        modes.append(.hex)
        return modes
    }

    /// True for files where `.table` is a sensible default. We
    /// preselect Table mode for CSV/TSV by inserting it at the
    /// front of the picker.
    public static func defaultMode(for url: URL?) -> ViewMode {
        guard let url else { return .source }
        if Self.supportsDiff(url) { return .diff }
        if Self.supportsTable(url) { return .table }
        let cat = FileTypeDetector.category(for: url)
        if cat == .markdown || cat == .mermaid { return .rendered }
        return .source
    }

    private static let formatterExtensions: Set<String> = [
        "json", "jsonl", "xml", "plist", "xib", "storyboard", "svg",
        "html", "htm", "xhtml"
    ]

    private static let tableExtensions: Set<String> = [
        "csv", "tsv"
    ]

    private static let diffExtensions: Set<String> = [
        "diff", "patch"
    ]

    private static func supportsFormatting(_ url: URL) -> Bool {
        formatterExtensions.contains(url.pathExtension.lowercased())
    }

    private static func supportsTable(_ url: URL) -> Bool {
        tableExtensions.contains(url.pathExtension.lowercased())
    }

    private static func supportsDiff(_ url: URL) -> Bool {
        diffExtensions.contains(url.pathExtension.lowercased())
    }

    /// Editor (in-memory writable buffer) is offered for any file we
    /// classify as text-shaped. Binary categories (image / audio /
    /// video / pdf / sqlite) plus the diff-renderer category are
    /// excluded — the user would be editing a derived representation
    /// or a non-text payload.
    public static func supportsEditor(_ url: URL) -> Bool {
        if supportsDiff(url) { return false }
        switch FileTypeDetector.category(for: url) {
        case .markdown, .mermaid, .plainText, .code, .html:
            return true
        case .image, .audio, .video, .pdf, .sqlite, .binary, .unknown:
            return false
        }
    }
}
