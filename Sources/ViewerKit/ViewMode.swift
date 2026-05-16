import Foundation

/// How a file is currently being displayed. The set of available
/// modes varies by file type; the always-on baseline is `source`
/// + `hex`, with `rendered` and `formatted` opt-in for files that
/// support them.
public enum ViewMode: String, Equatable, Sendable, CaseIterable {
    case rendered    // markdown only: WKWebView-rendered HTML
    case source      // every text file: NSTextView with syntax highlight
    case formatted   // JSON / XML / etc.: pretty-printed source
    case table       // csv / tsv: column-major grid
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
        if cat == .markdown { modes.insert(.rendered, at: 0) }
        if Self.supportsFormatting(url) { modes.append(.formatted) }
        // CSV / TSV files get a table mode. Default-on for these
        // extensions but `.source` stays available for raw-text view.
        if Self.supportsTable(url) { modes.insert(.table, at: 0) }
        modes.append(.hex)
        return modes
    }

    /// True for files where `.table` is a sensible default. We
    /// preselect Table mode for CSV/TSV by inserting it at the
    /// front of the picker.
    public static func defaultMode(for url: URL?) -> ViewMode {
        guard let url else { return .source }
        if Self.supportsTable(url) { return .table }
        if FileTypeDetector.category(for: url) == .markdown { return .rendered }
        return .source
    }

    private static let formatterExtensions: Set<String> = [
        "json", "jsonl", "xml", "plist", "xib", "storyboard", "svg",
        "html", "htm", "xhtml"
    ]

    private static let tableExtensions: Set<String> = [
        "csv", "tsv"
    ]

    private static func supportsFormatting(_ url: URL) -> Bool {
        formatterExtensions.contains(url.pathExtension.lowercased())
    }

    private static func supportsTable(_ url: URL) -> Bool {
        tableExtensions.contains(url.pathExtension.lowercased())
    }
}
