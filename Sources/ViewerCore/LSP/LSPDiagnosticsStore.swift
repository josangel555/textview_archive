import Foundation

/// @MainActor store of LSP diagnostics, keyed by file URL. Driven by
/// `textDocument/publishDiagnostics` notifications routed from
/// `LSPClient` → `LSPPool` → here. Read by the "Problems" sidebar
/// section and (in a future pass) the inline-squiggle decorator.
///
/// Replace-by-URL semantics per LSP spec: each `publishDiagnostics`
/// notification carries the *current* set for that URI. Servers
/// re-send empty arrays to clear stale entries; we honor that — an
/// empty publish removes all diagnostics for that file.
///
/// Filtering helpers (`forSeverity`, `errorsOnly`) exist for the
/// sidebar pill counts; the store itself stays severity-agnostic.
@MainActor
public final class LSPDiagnosticsStore: ObservableObject {

    @Published public private(set) var byURL: [URL: [LSPDiagnostic]] = [:]

    public init() {}

    /// Replace all diagnostics for a single URL. Empty `diagnostics`
    /// clears the URL's entry from the dict (so `byURL.count` doubles
    /// as "files with problems").
    public func replace(url: URL, with diagnostics: [LSPDiagnostic]) {
        if diagnostics.isEmpty {
            byURL.removeValue(forKey: url)
        } else {
            byURL[url] = diagnostics
        }
    }

    /// Remove all diagnostics for a URL — used when the file is closed
    /// or the language server crashes (stale data is worse than none).
    public func clear(url: URL) {
        byURL.removeValue(forKey: url)
    }

    /// Clear everything. Bound to "Reload All" + app-quit hooks.
    public func clearAll() {
        byURL.removeAll()
    }

    /// All diagnostics, flat across files. Ordered by URL path then
    /// by line — the sidebar can render this straight without
    /// re-sorting.
    public var allFlat: [(url: URL, diagnostic: LSPDiagnostic)] {
        let sortedURLs = byURL.keys.sorted { $0.path < $1.path }
        var out: [(URL, LSPDiagnostic)] = []
        for url in sortedURLs {
            let diags = byURL[url] ?? []
            let sorted = diags.sorted { lhs, rhs in
                if lhs.range.start.line != rhs.range.start.line {
                    return lhs.range.start.line < rhs.range.start.line
                }
                return lhs.range.start.character < rhs.range.start.character
            }
            for d in sorted { out.append((url, d)) }
        }
        return out
    }

    /// Filtered view by severity. Errors-only is the most common pill;
    /// keep this O(n) and don't memoize — diagnostic counts are small
    /// even on a moderately broken workspace (<1k rows).
    public func filtered(by severity: LSPDiagnostic.Severity) -> [(url: URL, diagnostic: LSPDiagnostic)] {
        return allFlat.filter { $0.diagnostic.severity == severity }
    }

    public var errorsOnly: [(url: URL, diagnostic: LSPDiagnostic)] {
        return filtered(by: .error)
    }

    /// Total count for the sidebar header pill. Equivalent to
    /// `allFlat.count` but skips the sort + tuple alloc.
    public var totalCount: Int {
        byURL.values.reduce(0) { $0 + $1.count }
    }

    public var errorCount: Int {
        byURL.values.reduce(0) { $0 + $1.count { $0.severity == .error } }
    }

    public var warningCount: Int {
        byURL.values.reduce(0) { $0 + $1.count { $0.severity == .warning } }
    }

    public var informationCount: Int {
        byURL.values.reduce(0) { $0 + $1.count { $0.severity == .information } }
    }

    public var hintCount: Int {
        byURL.values.reduce(0) { $0 + $1.count { $0.severity == .hint } }
    }

    /// Number of files with at least one diagnostic — the "N files with
    /// problems" the sidebar header summarizes. Equals `byURL.count`
    /// because empty publishes remove the key (see `replace`).
    public var fileCount: Int {
        byURL.count
    }
}
