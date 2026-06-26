import Foundation

// TSK-1256 slice 1 (model) — a STABLE, shareable element reference.
//
// "Right-click any element → Copy Reference → paste to an agent to say 'this is
// the element I mean'." The reference must (a) uniquely name an element, (b) be
// resolvable back (scroll/highlight/activate, even deep-load if unmounted), and
// (c) be agent-consumable via the AX/JS driver (TSK-1254). This file is the
// pure-logic MODEL + serialization — the host-testable foundation; the RESOLVER
// (scroll/highlight/activate/deep-load) and the right-click UI are later
// render/VM slices.
//
// One URI scheme (`mdv://`) spans both addressing worlds:
//   native chrome  → `mdv://ax/<mdv.* accessibilityIdentifier>`     (→ AXDriverCore via axQuery)
//   WebView line   → `mdv://web/<docId>/line/<n>`                   (→ cmDispatch goto-line)
//   WebView node   → `mdv://web/<docId>/sel/<css-selector>`         (→ querySelector)
//   a file (deep)  → `mdv://file/<path>?line=<n>`                   (load + reveal)
//   a tab          → `mdv://tab/<id>`

public enum ElementRef: Equatable, Sendable {
    /// Native chrome element addressed by its `mdv.*` accessibilityIdentifier
    /// (the AX path; resolves through `AXDriverCore`/`AXIdentifierCatalog`).
    case ax(identifier: String)
    /// A line in a WebView document (e.g. the CM6 editor), 1-based.
    case webLine(docId: String, line: Int)
    /// A WebView DOM node by CSS selector.
    case webSelector(docId: String, selector: String)
    /// A file, deep-loadable when not currently mounted; optional 1-based line.
    case file(path: String, line: Int?)
    /// A tab by its stable id.
    case tab(id: String)

    // MARK: Serialization

    /// The shareable string form (what "Copy Reference" puts on the pasteboard).
    public var serialized: String {
        switch self {
        case .ax(let id):
            return "mdv://ax/\(Self.encode(id))"
        case .webLine(let docId, let line):
            return "mdv://web/\(Self.encode(docId))/line/\(line)"
        case .webSelector(let docId, let selector):
            return "mdv://web/\(Self.encode(docId))/sel/\(Self.encode(selector))"
        case .file(let path, let line):
            let base = "mdv://file/\(Self.encode(path))"
            return line.map { "\(base)?line=\($0)" } ?? base
        case .tab(let id):
            return "mdv://tab/\(Self.encode(id))"
        }
    }

    /// Parse a `mdv://…` reference. Returns nil for any malformed input — a
    /// pasted ref is untrusted.
    public init?(parsing string: String) {
        let scheme = "mdv://"
        guard string.hasPrefix(scheme) else { return nil }
        let body = String(string.dropFirst(scheme.count))
        let split = body.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(split[0])
        let query = split.count > 1 ? String(split[1]) : ""
        let segs = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let host = segs.first, !host.isEmpty else { return nil }
        let rest = Array(segs.dropFirst())

        switch host {
        case "ax":
            guard rest.count == 1, !rest[0].isEmpty else { return nil }
            self = .ax(identifier: Self.decode(rest[0]))
        case "web":
            // web/<docId>/<kind>/<value>
            guard rest.count == 3, !rest[0].isEmpty else { return nil }
            let docId = Self.decode(rest[0])
            let value = Self.decode(rest[2])
            switch rest[1] {
            case "line":
                guard let n = Int(value), n >= 1 else { return nil }
                self = .webLine(docId: docId, line: n)
            case "sel":
                guard !value.isEmpty else { return nil }
                self = .webSelector(docId: docId, selector: value)
            default:
                return nil
            }
        case "file":
            guard rest.count == 1, !rest[0].isEmpty else { return nil }
            self = .file(path: Self.decode(rest[0]), line: Self.queryInt(query, key: "line"))
        case "tab":
            guard rest.count == 1, !rest[0].isEmpty else { return nil }
            self = .tab(id: Self.decode(rest[0]))
        default:
            return nil
        }
    }

    // MARK: Driver bridge

    /// For a native `.ax` ref, the `AXQuery` the out-of-process driver resolves
    /// (`AXDriverCore.find`). Nil for WebView/file/tab refs (those resolve via
    /// the JS/load paths, not the AX tree).
    public var axQuery: AXQuery? {
        if case .ax(let id) = self { return AXQuery(id) }
        return nil
    }

    // MARK: Percent-encoding (segment-safe; keeps mdv.* ids readable)

    /// Unreserved per segment: alphanumerics + `._-`. Everything else (`/`,
    /// space, CSS punctuation) is percent-encoded so a path/selector can't break
    /// the `/`-delimited parse, while `mdv.hexView` stays human-readable.
    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "._-")
        return set
    }()

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? s
    }

    private static func decode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }

    private static func queryInt(_ query: String, key: String) -> Int? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == Substring(key) { return Int(kv[1]) }
        }
        return nil
    }
}
