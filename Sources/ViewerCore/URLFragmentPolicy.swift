import Foundation

/// Same-document fragment detection, shared by the HTML/Markdown/CodeMirror
/// navigation policies (previously a private `isSameDocumentFragment` copied
/// verbatim in three places).
public enum URLFragmentPolicy {
    /// True when `url` is a pure same-document fragment navigation relative
    /// to `documentURL` — it has a non-empty fragment AND matches the
    /// current document on scheme+host+path+query (i.e. only the `#anchor`
    /// differs). With no current document, a scheme-less fragment URL counts
    /// as same-doc (the rare pre-first-load case).
    ///
    /// Compared field-by-field rather than via a `URLComponents` round-trip:
    /// newer Foundation (macOS 15.6.1+) reserializes scheme-only URLs like
    /// `about:blank`, which broke fragment-stripping equality checks.
    public static func isSameDocument(_ url: URL, as documentURL: URL?) -> Bool {
        guard let fragment = url.fragment, !fragment.isEmpty else { return false }
        guard let doc = documentURL else { return url.scheme == nil }
        return url.scheme == doc.scheme
            && url.host == doc.host
            && url.path == doc.path
            && url.query == doc.query
    }
}
