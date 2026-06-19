import Foundation

/// URL-template expansion for "open external service" plugin actions —
/// the foundation for office/web integrations (Docs, Wiki, Code Review,
/// CodeSearch, code browsers). These integrations all reduce to the
/// same shape: take a URL template that references the current host
/// context and open it in the user's browser, e.g.
///
///   `https://codesearch.example.com/search?q={query}`
///   `https://wiki.example.com/page?file={filename}`
///   `https://cr.example.com/changes?path={path}&line={line}`
///
/// This type is the **pure, deterministic, sans-IO** core of that
/// feature: template + context → a validated `URL` (or a typed
/// failure). It owns three security/correctness concerns so the
/// AppKit "open the URL" tail can stay dumb:
///
///   1. **Placeholder substitution** with per-component percent-
///      encoding — a path or query value is escaped for the query-
///      string position it lands in, so a filename with `&`, `?`, `#`,
///      or spaces can't break out of its slot or inject extra params.
///   2. **Scheme allowlist** — only `https`/`http` survive. A template
///      (or a substituted value that recombines into) `file:`,
///      `javascript:`, `data:`, or a custom scheme is rejected. This
///      is the perimeter that keeps a "web integration" from becoming
///      a local-file or script-exec primitive (sibling of
///      `URLSchemePolicy`).
///   3. **Well-formedness** — the expanded string must parse as a
///      `URL` with a host. A template that can't form a real URL is a
///      manifest error surfaced at expand time, not a silent no-op.
///
/// Keeping this host-testable (no `NSWorkspace`, no UI) means the
/// office-integration matrix — odd filenames, injection attempts,
/// missing placeholders, hostile schemes — is all unit-coverable.
public enum PluginURLTemplate {

    /// The host context a template can interpolate. Every field is the
    /// raw, *unescaped* value; `expand` does the percent-encoding so
    /// the manifest author never has to (and can't get it wrong).
    public struct Context: Sendable, Equatable {
        /// Absolute filesystem path of the focused document, if any.
        public let path: String?
        /// Last path component of the focused document (its filename).
        public let filename: String?
        /// The user's current text selection, if any.
        public let selection: String?
        /// A free-text query (e.g. the command-palette argument the
        /// user typed for a "search in CodeSearch" command).
        public let query: String?
        /// 1-based caret line in the focused document, if known.
        public let line: Int?

        public init(
            path: String? = nil,
            filename: String? = nil,
            selection: String? = nil,
            query: String? = nil,
            line: Int? = nil
        ) {
            self.path = path
            self.filename = filename
            self.selection = selection
            self.query = query
            self.line = line
        }

        /// Resolve a placeholder name to its raw value, deriving
        /// `filename` from `path` when only `path` was supplied so a
        /// caller that knows the path needn't redundantly pass both.
        func rawValue(for placeholder: String) -> String? {
            switch placeholder {
            case "path": return path
            case "filename":
                if let filename { return filename }
                if let path { return (path as NSString).lastPathComponent }
                return nil
            case "selection": return selection
            case "query": return query
            case "line": return line.map(String.init)
            default: return nil
            }
        }
    }

    /// Why an expansion was rejected. Carried into the plugin load
    /// report / audit log so a misconfigured integration is diagnosable
    /// rather than mysteriously inert.
    public enum Failure: Error, Sendable, Equatable {
        /// The template references `{name}` but the context had no value
        /// for it (and it wasn't optional). Carries the placeholder name.
        case missingPlaceholder(String)
        /// The template references `{name}` where `name` is not a known
        /// placeholder. A manifest typo, surfaced rather than silently
        /// left literal.
        case unknownPlaceholder(String)
        /// A `{` with no matching `}` (or vice-versa). Malformed template.
        case unbalancedBraces
        /// The expanded string didn't parse as a URL, or had no host.
        case malformedURL
        /// The expanded URL's scheme isn't in the allowlist (`https`/
        /// `http`). Carries the offending scheme (empty string if none).
        case disallowedScheme(String)
    }

    /// Schemes a web-integration template may resolve to. Deliberately
    /// tiny — anything else (file, javascript, data, ftp, a custom app
    /// scheme) is a rejection. `http` is permitted for intranet
    /// services that haven't moved to TLS, matching the reality of
    /// internal corp tools; callers that want HTTPS-only can post-check.
    public static let allowedSchemes: Set<String> = ["https", "http"]

    /// The set of placeholder names a template may use. Surfacing this
    /// lets the manifest validator reject typos at load time.
    public static let knownPlaceholders: Set<String> =
        ["path", "filename", "selection", "query", "line"]

    /// Expand `template` against `context` and return a validated URL.
    ///
    /// Substituted values are percent-encoded for safe placement in a
    /// URL query/path. A placeholder whose context value is `nil` fails
    /// with `.missingPlaceholder` (rather than expanding to empty) so a
    /// "search {query}" command can't silently open a contextless URL.
    public static func expand(
        template: String,
        context: Context
    ) -> Result<URL, Failure> {
        let substituted: String
        switch substitute(template: template, context: context) {
        case .success(let s): substituted = s
        case .failure(let f): return .failure(f)
        }

        guard let url = URL(string: substituted),
              let host = url.host, !host.isEmpty else {
            return .failure(.malformedURL)
        }
        let scheme = (url.scheme ?? "").lowercased()
        guard allowedSchemes.contains(scheme) else {
            return .failure(.disallowedScheme(scheme))
        }
        return .success(url)
    }

    /// Replace every `{placeholder}` with the percent-encoded raw value
    /// from `context`. Literal `{` / `}` are not otherwise meaningful in
    /// a URL, so we treat any `{` as the start of a placeholder; an
    /// unmatched `{` is `.unbalancedBraces`.
    static func substitute(
        template: String,
        context: Context
    ) -> Result<String, Failure> {
        var out = ""
        out.reserveCapacity(template.count)
        var idx = template.startIndex
        while idx < template.endIndex {
            let ch = template[idx]
            if ch == "}" {
                // A `}` with no open `{` is malformed.
                return .failure(.unbalancedBraces)
            }
            if ch == "{" {
                guard let close = template[idx...].firstIndex(of: "}") else {
                    return .failure(.unbalancedBraces)
                }
                let nameStart = template.index(after: idx)
                let name = String(template[nameStart..<close])
                guard knownPlaceholders.contains(name) else {
                    return .failure(.unknownPlaceholder(name))
                }
                guard let raw = context.rawValue(for: name) else {
                    return .failure(.missingPlaceholder(name))
                }
                out += percentEncode(raw)
                idx = template.index(after: close)
                continue
            }
            out.append(ch)
            idx = template.index(after: idx)
        }
        return .success(out)
    }

    /// Percent-encode a substituted value for a URL query/path slot.
    /// We start from `.urlQueryAllowed` and then additionally escape the
    /// sub-delimiters that are legal in a query *as a whole* but would
    /// let a value forge structure inside it — `&` (param separator),
    /// `=` (key/value), `+` (space in form-encoding), `?`, `#`, `/`.
    /// This keeps a filename like `a&b=c d.txt` confined to one value.
    static func percentEncode(_ raw: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#/")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
