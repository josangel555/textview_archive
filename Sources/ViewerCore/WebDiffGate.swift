import Foundation

/// TSK-1596 (owner 2026-07-24) — the WEB diff view: the `.diff` lens renders in
/// a WKWebView (`diffweb.html` + the vendored `@codemirror/merge` diff engine)
/// instead of the SwiftUI `DiffView`.
///
/// SHIPS ON. The owner explicitly retired the SwiftUI diff from maintenance
/// ("no plans to maintain the existing implementation") — it survives ONLY as
/// the review-mode renderer (comment threads / composer) until the review
/// follow-up ports those. `MDV_WEB_DIFF=0` (env) or `mdv.webDiffView=false`
/// (defaults) is the kill-switch back to the SwiftUI renderer.
public enum WebDiffGate {
    public static let defaultsKey = "mdv.webDiffView"
    static let envKey = "MDV_WEB_DIFF"

    public static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> Bool {
        let env = environment ?? ProcessInfo.processInfo.environment
        if let v = env[envKey] { return v == "1" }
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.bool(forKey: defaultsKey)
        }
        return true   // ships ON (owner 2026-07-24)
    }
}

/// TSK-1596 — the diff view's intra-line highlight granularity, the owner's
/// "Line diff | Word diff | Char diff" picker. Maps 1:1 onto the vendored
/// `@codemirror/merge` primitives in `diffweb.html`:
///   - `.line` → no intra-line marks (whole-row add/remove tint only)
///   - `.word` → `CM.presentableDiff` (change ranges cleaned to word boundaries)
///   - `.char` → `CM.diff` (raw character-precise change ranges)
/// Persisted app-wide under `defaultsKey` (the picker is a preference, not
/// per-tab state).
public enum DiffGranularity: String, CaseIterable, Sendable {
    case line, word, char

    public static let defaultsKey = "mdv.diffGranularity"
    public static let `default`: DiffGranularity = .word

    public var displayName: String {
        switch self {
        case .line: return "Line"
        case .word: return "Word"
        case .char: return "Char"
        }
    }

    /// Resolve a persisted raw value; garbage / missing → the default.
    public static func resolve(_ raw: String?) -> DiffGranularity {
        raw.flatMap(DiffGranularity.init(rawValue:)) ?? .default
    }
}

/// TSK-1598 (owner 2026-07-24) — the web diff view's layout preferences.
/// Both app-wide (like the granularity), both persisted:
///   - WRAP: long lines wrap at EXACTLY the window width (no h-scroll, rows
///     never narrower than the window — the TSK-1595 class). Ships ON — the
///     owner's complaint was the indefinite horizontal extent. OFF = the
///     single-line + horizontal-scroll layout.
///   - FILE NAV: the changed-files tree on the diff's left edge (click a file
///     → jump to its block). Ships ON.
public enum DiffViewPrefs {
    public static let wrapKey = "mdv.diffWrap"
    public static let wrapDefault = true
    public static let fileNavKey = "mdv.diffFileNav"
    public static let fileNavDefault = true
}

/// TSK-1596/1599 — the Swift→page wire payload for `diffweb.html`: an
/// envelope `{ pre, files }` where `pre` is the commit preamble (message /
/// author / date from `git show`, nil for a plain patch) and `files` is the
/// parsed `UnifiedDiff` tree as compact JSON. Field names are single letters
/// because a big commit diff serializes thousands of line entries; the page
/// contract is documented in `diffweb.html`'s header comment.
///
///   file: { op, np, add (isNew), del (isDeleted), bin, ren,
///           ob/nb (old/new blob shas off the patch's `index` line — back the
///           per-file "view Old / New version" buttons; absent when the patch
///           carries no index line), hunks: [...] }
///   hunk: { h (header), lines: [...] }
///   line: { k (0 ctx | 1 added | 2 removed | 3 noNewline), o (old line no),
///           n (new line no), t (text) }
public enum DiffWebPayload {

    struct WireEnvelope: Encodable {
        let pre: String?
        let files: [WireFile]
    }
    struct WireFile: Encodable {
        let op: String
        let np: String
        let add: Bool
        let del: Bool
        let bin: Bool
        let ren: Bool
        let ob: String?
        let nb: String?
        let hunks: [WireHunk]
    }
    struct WireHunk: Encodable {
        let h: String
        let lines: [WireLine]
    }
    struct WireLine: Encodable {
        let k: Int
        let o: Int?
        let n: Int?
        let t: String
    }

    static func kindCode(_ kind: UnifiedDiff.Line.Kind) -> Int {
        switch kind {
        case .context:   return 0
        case .added:     return 1
        case .removed:   return 2
        case .noNewline: return 3
        }
    }

    /// Per-file (oldBlob, newBlob) shas scanned from the RAW patch's
    /// `index <old>..<new>[ <mode>]` lines, in `diff --git` order — the rust
    /// parser deliberately drops these header lines, and the blob shas are
    /// what `git cat-file` needs for the Old/New version buttons. Pure +
    /// host-tested. Entries without an index line yield (nil, nil); all-zero
    /// shas (added/deleted sides) are normalized to nil.
    public static func blobPairs(_ diffText: String) -> [(old: String?, new: String?)] {
        var pairs: [(old: String?, new: String?)] = []
        var lastFilled = true   // only the FIRST index line after each diff --git counts
        for line in diffText.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                pairs.append((nil, nil))
                lastFilled = false
            } else if line.hasPrefix("index "), !lastFilled, !pairs.isEmpty {
                lastFilled = true
                let body = line.dropFirst("index ".count)
                let range = body.split(separator: " ").first ?? ""
                let parts = range.split(separator: ".", omittingEmptySubsequences: true)
                guard parts.count == 2 else { continue }
                func norm(_ s: Substring) -> String? {
                    let str = String(s)
                    return str.allSatisfy({ $0 == "0" }) ? nil : str
                }
                pairs[pairs.count - 1] = (norm(parts[0]), norm(parts[1]))
            }
        }
        return pairs
    }

    /// Encode a raw unified-diff text as the page's `{pre, files}` envelope:
    /// rust-parses the tree, extracts the commit preamble, and aligns the
    /// blob-sha pairs by file order. Deterministic key order (sortedKeys) so
    /// tests can pin the wire shape.
    public static func json(diffText: String) -> String {
        json(RustDiffAdapter.parse(diffText),
             preamble: CommitDiffSummary.preamble(diffText),
             blobs: blobPairs(diffText))
    }

    /// Envelope encoder over an already-parsed tree (test seam + callers that
    /// parsed for other reasons). `blobs` aligns by index; short arrays pad nil.
    public static func json(
        _ files: [UnifiedDiff.File],
        preamble: String? = nil,
        blobs: [(old: String?, new: String?)] = []
    ) -> String {
        let wire = files.enumerated().map { (i, f) in
            WireFile(
                op: f.oldPath, np: f.newPath,
                add: f.isNew, del: f.isDeleted,
                bin: f.isBinary, ren: f.isRename,
                ob: i < blobs.count ? blobs[i].old : nil,
                nb: i < blobs.count ? blobs[i].new : nil,
                hunks: f.hunks.map { h in
                    WireHunk(h: h.header, lines: h.lines.map { l in
                        WireLine(k: kindCode(l.kind),
                                 o: l.oldLineNo, n: l.newLineNo, t: l.content)
                    })
                })
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(WireEnvelope(pre: preamble, files: wire)),
              let json = String(data: data, encoding: .utf8) else { return "{\"files\":[]}" }
        return json
    }
}
