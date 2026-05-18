import Foundation
import SwiftTreeSitter
// Eager keeplist — these grammars stay statically linked into ViewerCore
// (and therefore the executable). Rationale per docs/TREESITTER_LAZY_LOAD.md:
//   - JSON: jq integration, settings, workspaces — hot on launch.
//   - Swift: the app's own source — opened often during development.
//   - Markdown: every .md open does code-fence highlighting; first-tap
//     dylib latency would be visible.
// Everything else (XML, Python, JS, TS, Bash, plus Phase 5 grammars)
// loads through GrammarLoader at first-use.
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterSwift
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
    /// Per-language lock used to serialize the slow `Query` compile so
    /// concurrent first-touchers don't both compile and race the write.
    /// Guarded by `lock`.
    private var compileLocks: [HighlightLanguage: NSLock] = [:]
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
        // single-color highlighting we want the LAST run (in cursor
        // order) covering each position — matches editor intuition
        // that nested-specific captures override their parent.
        return Self.paintOver(runs: runs, textCount: text.utf16.count)
    }

    /// Sweep-line resolution of overlapping highlight runs. Later
    /// runs (higher input index) win where they overlap. O(K log K)
    /// in run count — independent of text length. Replaces an older
    /// per-character canvas that allocated `O(textCount)` storage and
    /// was the dominant cost on multi-hundred-KB files.
    internal static func paintOver(
        runs: [HighlightRun], textCount: Int
    ) -> [HighlightRun] {
        guard !runs.isEmpty, textCount > 0 else { return [] }

        struct Event {
            let pos: Int
            let isOpen: Bool
            let idx: Int
            let kind: TokenKind
        }
        var events: [Event] = []
        events.reserveCapacity(runs.count * 2)
        for (i, r) in runs.enumerated() {
            let lo = max(0, r.range.location)
            let hi = min(textCount, r.range.location + r.range.length)
            guard lo < hi else { continue }
            events.append(Event(pos: lo, isOpen: true,  idx: i, kind: r.kind))
            events.append(Event(pos: hi, isOpen: false, idx: i, kind: r.kind))
        }
        events.sort { a, b in
            if a.pos != b.pos { return a.pos < b.pos }
            // Close-before-open at same position prevents a one-tick
            // window where two runs are simultaneously active just so
            // one can hand off to the next.
            return !a.isOpen && b.isOpen
        }

        // Active set kept sorted ascending by `idx`. Topmost (last)
        // entry has the highest input-order priority — that's the
        // kind the segment between events should paint with.
        var active: [Int] = []
        var kindByIdx: [Int: TokenKind] = [:]
        var out: [HighlightRun] = []
        out.reserveCapacity(runs.count)
        var lastPos = 0

        func emit(from lo: Int, to hi: Int) {
            guard hi > lo, let topIdx = active.last,
                  let kind = kindByIdx[topIdx] else { return }
            // Coalesce with previous output if same kind and contiguous.
            if let prev = out.last, prev.kind == kind,
               prev.range.location + prev.range.length == lo {
                out[out.count - 1] = HighlightRun(
                    range: NSRange(location: prev.range.location,
                                   length: hi - prev.range.location),
                    kind: kind)
            } else {
                out.append(HighlightRun(
                    range: NSRange(location: lo, length: hi - lo),
                    kind: kind))
            }
        }

        for e in events {
            emit(from: lastPos, to: e.pos)
            if e.isOpen {
                // Sorted insert by idx.
                let insertAt = active.firstIndex(where: { $0 > e.idx })
                    ?? active.count
                active.insert(e.idx, at: insertAt)
                kindByIdx[e.idx] = e.kind
            } else {
                if let pos = active.firstIndex(of: e.idx) {
                    active.remove(at: pos)
                }
                kindByIdx.removeValue(forKey: e.idx)
            }
            lastPos = e.pos
        }
        return out
    }

    /// Lazily load (language, query) for a `HighlightLanguage`. Returns
    /// nil if either the C symbol or the bundled .scm is missing.
    ///
    /// Per-language one-shot compile: a small per-language NSLock
    /// serializes the slow `Query(language:data:)` compile so two
    /// concurrent first-touchers for the same language don't both
    /// compile, then race to overwrite the cache with distinct `Query`
    /// objects whose ARC fate is then non-deterministic. Different
    /// languages still parallelise — the outer `lock` is only held
    /// for the dict lookup and to fetch the per-language lock.
    private func bundle(for lang: HighlightLanguage) -> LangBundle? {
        lock.lock()
        if let hit = cache[lang]   { lock.unlock(); return hit }
        if failed.contains(lang)   { lock.unlock(); return nil }
        let perLangLock = compileLock(for: lang)
        lock.unlock()

        perLangLock.lock()
        defer { perLangLock.unlock() }

        // Re-check after acquiring the per-language lock: a peer
        // thread that won the race has now stored the bundle.
        lock.lock()
        if let hit = cache[lang]   { lock.unlock(); return hit }
        if failed.contains(lang)   { lock.unlock(); return nil }
        lock.unlock()

        guard let language = languageHandle(for: lang),
              let queryURL = queryURL(for: lang) else {
            lock.lock(); failed.insert(lang); lock.unlock()
            return nil
        }

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

    /// Per-language compile lock. Lazily allocated so we don't pay for
    /// languages the user never touches. Caller must hold `self.lock`.
    private func compileLock(for lang: HighlightLanguage) -> NSLock {
        if let l = compileLocks[lang] { return l }
        let l = NSLock()
        compileLocks[lang] = l
        return l
    }

    /// Returns a SwiftTreeSitter `Language` for a HighlightLanguage,
    /// dispatching to either the statically-linked keeplist symbol or
    /// to the runtime `GrammarLoader` dlopen path.
    ///
    /// Adding a new language: add a case to the appropriate branch
    /// here and add a `Queries/<x>-highlights.scm` file. Keeplist
    /// changes also need a static dep in Package.swift; lazy
    /// languages need a new `GrammarLoader.Grammar` case + dynamic
    /// library product.
    private func languageHandle(for lang: HighlightLanguage) -> Language? {
        switch lang {
        // Keeplist — static link.
        case .swift:      return Language(language: tree_sitter_swift())
        case .json:       return Language(language: tree_sitter_json())
        case .markdown:   return Language(language: tree_sitter_markdown())

        // Lazy — dlopen via GrammarLoader. The `.shell` case maps to
        // the bash grammar (the upstream `.sh`/`.zsh`/`.bash` files
        // all parse as bash for our purposes).
        case .xml:        return GrammarLoader.load(.xml)
        case .python:     return GrammarLoader.load(.python)
        case .javascript: return GrammarLoader.load(.javascript)
        case .typescript: return GrammarLoader.load(.typescript)
        case .shell:      return GrammarLoader.load(.bash)

        // Phase 5 grammars — wired through GrammarLoader once the
        // wrapper targets land. Returning nil here means "highlighting
        // unavailable for this language"; the engine memoizes that
        // failure so we don't retry.
        case .java:       return GrammarLoader.load(.java)
        case .c:          return GrammarLoader.load(.c)
        case .cpp:        return GrammarLoader.load(.cpp)
        case .rust:       return GrammarLoader.load(.rust)

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
