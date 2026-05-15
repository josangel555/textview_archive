import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterJSON
import TreeSitterJavaScript
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterSwift
import TreeSitterTypeScript
import TreeSitterXML
import ViewerKit

/// TreeSitter-backed syntax highlighter.
///
/// Owns per-language `Language` + compiled `Query` pointers; reuses
/// them across calls (query compilation is the bulk of cold-start
/// work). Parses are stateless from the engine's POV — we build a new
/// `Parser` per call so concurrent calls on different languages don't
/// contend for parser state.
///
/// We use an `NSLock` around the per-language caches rather than an
/// `actor` because callers exist in both async (DocumentModel,
/// background Tasks) and synchronous (HTMLRenderer's tree visitor)
/// contexts. The lock is held only across hash lookups — never across
/// a tokenize — so it never becomes a contention point in practice.
public final class TreeSitterEngine: @unchecked Sendable {

    public static let shared = TreeSitterEngine()

    private struct LangBundle {
        let language: Language
        let query: Query
    }

    private let lock = NSLock()
    private var cache: [HighlightLanguage: LangBundle] = [:]
    /// Languages we've tried and failed to load. Cache the failure so
    /// we don't re-try on every call (rare; usually a missing .scm).
    private var failed: Set<HighlightLanguage> = []

    /// Tokenize `text` using `language`. Returns NSRange-keyed runs
    /// (UTF-16 offsets) suitable for direct application to AppKit /
    /// SwiftUI attributed strings. Empty array means "don't highlight":
    /// unsupported language, oversized file, or any internal failure
    /// — never throws, because highlighting is best-effort decoration.
    public func tokenize(_ text: String, language: HighlightLanguage) -> [HighlightRun] {
        guard language != .plainText else { return [] }
        guard text.utf8.count <= highlightMaxBytes else { return [] }
        guard let bundle = bundle(for: language) else { return [] }

        let parser = Parser()
        do { try parser.setLanguage(bundle.language) }
        catch { return [] }

        guard let tree = parser.parse(text) else { return [] }
        guard let root = tree.rootNode else { return [] }

        var runs: [HighlightRun] = []
        runs.reserveCapacity(256)
        let cursor = bundle.query.execute(node: root, in: tree)
        for match in cursor {
            for cap in match.captures {
                guard let name = cap.name,
                      let kind = CaptureMap.kind(forCapture: name) else { continue }
                let r = cap.range
                guard r.length > 0, r.location != NSNotFound else { continue }
                runs.append(HighlightRun(range: r, kind: kind))
            }
        }

        // Sort + resolve overlaps. TreeSitter queries can emit nested
        // captures (e.g. a function-call inside a method body). For
        // single-color highlighting we want the most-specific match per
        // character — which, by query ordering convention, is the one
        // that comes LAST in the cursor stream. We resolve by:
        //   1. Sorting by start ascending, then length DESCENDING so
        //      the broadest run is first per start position.
        //   2. Walking left-to-right; each new run trims/skips ranges
        //      already claimed by an earlier (broader-or-equal) run.
        // Simpler model that matches editor intuition: later runs win.
        // We implement that with a paint-over array.
        return paintOver(runs: runs, textCount: (text as NSString).length)
    }

    /// "Paint over" resolution: walk runs in cursor order, later writes
    /// over earlier per character. Produces a flat, non-overlapping
    /// list — exactly what the renderer expects.
    private func paintOver(runs: [HighlightRun], textCount: Int) -> [HighlightRun] {
        guard !runs.isEmpty, textCount > 0 else { return [] }
        var canvas = [TokenKind?](repeating: nil, count: textCount)
        for run in runs {
            let lo = max(0, run.range.location)
            let hi = min(textCount, run.range.location + run.range.length)
            guard lo < hi else { continue }
            for i in lo..<hi { canvas[i] = run.kind }
        }
        // Collapse adjacent same-kind cells into runs.
        var out: [HighlightRun] = []
        out.reserveCapacity(runs.count)
        var i = 0
        while i < textCount {
            guard let kind = canvas[i] else { i += 1; continue }
            var j = i + 1
            while j < textCount, canvas[j] == kind { j += 1 }
            out.append(HighlightRun(range: NSRange(location: i, length: j - i), kind: kind))
            i = j
        }
        return out
    }

    /// Lazily load (language, query) for a `HighlightLanguage`. Returns
    /// nil if either the C symbol or the bundled .scm is missing.
    /// Lock is held only across the dictionary reads/writes — the
    /// (potentially slow) `Query` compile happens outside the lock so
    /// concurrent calls for different languages don't serialize.
    private func bundle(for lang: HighlightLanguage) -> LangBundle? {
        lock.lock()
        if let hit = cache[lang]   { lock.unlock(); return hit }
        if failed.contains(lang)   { lock.unlock(); return nil }
        lock.unlock()

        guard let langPtr = tsLanguagePointer(for: lang),
              let queryURL = queryURL(for: lang) else {
            lock.lock(); failed.insert(lang); lock.unlock()
            return nil
        }

        let language = Language(language: langPtr)
        do {
            let data = try Data(contentsOf: queryURL)
            let query = try Query(language: language, data: data)
            let bundle = LangBundle(language: language, query: query)
            lock.lock(); cache[lang] = bundle; lock.unlock()
            return bundle
        } catch {
            lock.lock(); failed.insert(lang); lock.unlock()
            return nil
        }
    }

    /// Returns the C-level `TSLanguage *` pointer for a language. New
    /// grammars added later only need a line here + a Queries/<x>.scm.
    private func tsLanguagePointer(for lang: HighlightLanguage) -> OpaquePointer? {
        switch lang {
        case .swift:      return tree_sitter_swift()
        case .json:       return tree_sitter_json()
        case .xml:        return tree_sitter_xml()
        case .python:     return tree_sitter_python()
        case .javascript: return tree_sitter_javascript()
        case .typescript: return tree_sitter_typescript()
        case .markdown:   return tree_sitter_markdown()
        case .shell:      return tree_sitter_bash()
        default:          return nil
        }
    }

    /// Returns the URL of our vendored .scm for a language. Lookup is
    /// `Bundle.module` so it works in both the app bundle and the
    /// xctest harness.
    private func queryURL(for lang: HighlightLanguage) -> URL? {
        let stem: String
        switch lang {
        case .swift:      stem = "swift-highlights"
        case .json:       stem = "json-highlights"
        case .xml:        stem = "xml-highlights"
        case .python:     stem = "python-highlights"
        case .javascript: stem = "javascript-highlights"
        case .typescript: stem = "typescript-highlights"
        case .markdown:   stem = "markdown-highlights"
        case .shell:      stem = "bash-highlights"
        default:          return nil
        }
        return Bundle.module.url(
            forResource: stem, withExtension: "scm", subdirectory: "Queries"
        )
    }
}
