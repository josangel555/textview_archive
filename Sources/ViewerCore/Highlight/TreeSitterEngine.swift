import Foundation
import SwiftTreeSitter
// Eager keeplist — these grammars stay statically linked into ViewerCore
// (and therefore the executable). Rationale per docs/TREESITTER_LAZY_LOAD.md:
//   - JSON: jq integration, settings, workspaces — hot on launch.
//   - Swift: the app's own source — opened often during development.
//   - Markdown: every .md open does code-fence folding; first-tap
//     dylib latency would be visible.
// TSK-854: this engine no longer highlights (rust-only via
// RustHighlightAdapter) — it survives only for code-FOLDS + structural
// search, so its grammar set is now exactly those features' languages.
// The lazy remainder (XML, JS, TS) loads through GrammarLoader at first-use.
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

    // MARK: Fold storage
    //
    // Lives alongside the highlight cache rather than as a separate
    // actor: cheaper than a hop and the lock is only held across
    // dictionary ops (never across parsing). All mutation happens
    // through the `TreeSitterEngine+Folds.swift` extension.
    internal let foldLock = NSLock()
    internal var foldBundles: [HighlightLanguage: FoldBundle] = [:]
    internal var foldFailed:  Set<HighlightLanguage> = []
    internal var foldCache:   [HighlightLanguage: FoldCacheEntry] = [:]

    /// Tokenize `text` using `language`. Returns NSRange-keyed runs
    /// (UTF-16 offsets) suitable for direct application to AppKit /
    /// SwiftUI attributed strings. Empty array means "don't highlight":
    /// unsupported language, oversized file, or any internal failure
    /// — never throws, because highlighting is best-effort decoration.
    public func tokenize(_ text: String, language: HighlightLanguage) -> [HighlightRun] {
        guard language != .plainText else { return [] }
        guard text.utf8.count <= highlightMaxBytes else { return [] }
        let tokToken = PerfSignpost.begin(.highlight, "TreeSitterEngine.tokenize")
        defer { PerfSignpost.end(tokToken) }
        guard let bundle = bundle(for: language) else { return [] }

        let parser = Parser()
        do { try parser.setLanguage(bundle.language) }
        catch { return [] }

        let parseToken = PerfSignpost.begin(.highlight, "ts.parse")
        guard let tree = parser.parse(text) else { PerfSignpost.end(parseToken); return [] }
        guard let root = tree.rootNode else { PerfSignpost.end(parseToken); return [] }
        PerfSignpost.end(parseToken)

        var runs: [HighlightRun] = []
        runs.reserveCapacity(256)
        let iterToken = PerfSignpost.begin(.highlight, "ts.query-iterate")
        let cursor = bundle.query.execute(node: root, in: tree)
        // Evaluate query predicates so gated captures don't fire
        // unconditionally. Without this, `((identifier) @type
        // (#match? @type "^[A-Z]"))` matched EVERY identifier, so a
        // lowercase `myThing` resolved to `.type` (the last-emitted
        // capture wins in paintOver). `resolve(with:)` keeps only matches
        // whose `#match?`/`#eq?`/`#any-of?` predicates hold. The default
        // group-membership provider returns false, so `#is-not? local`
        // (which would need a locals query we don't run) is treated as
        // satisfied — i.e. NO capture that renders today is dropped, only
        // wrongly-firing regex/eq-gated ones are filtered out.
        // Predicate text resolution against a cached UTF-16 code-unit
        // buffer instead of `text as NSString` + a fresh
        // `substring(with:)` per eval. SwiftTreeSitter parses with
        // UTF-16LE encoding, so a node's `range` (and the range handed
        // to this provider) is in UTF-16 offsets — `units` is exactly
        // that coordinate space. The old path bridged the whole file to
        // `NSString` and allocated a new `String` (via ObjC dispatch)
        // for every gated capture's text; on a large file with many
        // `#match?`/`#eq?` captures that is per-pass alloc churn. Here
        // the buffer is materialized once and each resolution builds a
        // String straight from the in-range code units — one minimal
        // allocation, no ObjC hop. Behaviour is byte-identical to
        // `NSString.substring(with:)`: identical coordinate space,
        // identical out-of-range guard, and `String(utf16CodeUnits:)`
        // preserves lone surrogates the same way a substring would.
        let units = Array(text.utf16)
        let predicateContext = Predicate.Context(textProvider: { range, _ in
            Self.predicateSubstring(in: units, range: range)
        })
        for match in cursor.resolve(with: predicateContext) {
            for cap in match.captures {
                guard let name = cap.name,
                      let kind = CaptureMap.kind(forCapture: name) else { continue }
                let r = cap.range
                guard r.length > 0, r.location != NSNotFound else { continue }
                runs.append(HighlightRun(range: r, kind: kind))
            }
        }
        PerfSignpost.end(iterToken)

        // Sort + resolve overlaps. TreeSitter queries can emit nested
        // captures (e.g. a function-call inside a method body). For
        // single-color highlighting we want the LAST run (in cursor
        // order) covering each position — matches editor intuition
        // that nested-specific captures override their parent.
        return PerfSignpost.withInterval(.highlight, "ts.paintOver") {
            Self.paintOver(runs: runs, textCount: text.utf16.count)
        }
    }

    /// Resolve a predicate `textProvider` query against a cached UTF-16
    /// code-unit buffer. `range` is in UTF-16 offsets (SwiftTreeSitter
    /// parses UTF-16LE, so a node's NSRange is UTF-16-based — see
    /// `Encoding+Helpers`). Returns nil for an out-of-range request
    /// (same as the old `NSString.substring(with:)` guard), an empty
    /// string for a zero-length range, else the in-range code units as
    /// a `String`. Byte-identical to `(text as NSString).substring(with:)`
    /// — including lone-surrogate preservation — but with no NSString
    /// bridge and a single minimal allocation per call (the old path
    /// dispatched into ObjC and allocated a fresh String per gated
    /// capture every tokenize pass). Static + internal so the equivalence
    /// can be pinned directly against `NSString.substring` in tests.
    internal static func predicateSubstring(
        in units: [unichar], range: NSRange
    ) -> String? {
        guard range.location != NSNotFound, range.location >= 0,
              range.length >= 0,
              range.location + range.length <= units.count else { return nil }
        // Empty slice → "" (matches NSString.substring(with:) for a
        // zero-length range). Also dodges the nil baseAddress an empty
        // backing array yields under withUnsafeBufferPointer.
        guard range.length > 0 else { return "" }
        return units.withUnsafeBufferPointer { buf in
            String(utf16CodeUnits: buf.baseAddress! + range.location,
                   count: range.length)
        }
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
            // The one-time per-language Query(language:data:) compile — the
            // bulk of cold-start tokenize cost. Bracketed so a profiler can
            // tell a cold (compile-included) tokenize from a warm one.
            let query = try PerfSignpost.withInterval(.highlight, "ts.query-compile") {
                try Query(language: language, data: data)
            }
            let bundle = LangBundle(language: language, query: query)
            lock.lock(); cache[lang] = bundle; lock.unlock()
            return bundle
        } catch {
            lock.lock(); failed.insert(lang); lock.unlock()
            return nil
        }
    }

    // MARK: - Cache warm-up (TSK-619)

    /// Precompile (language, query) bundles so a later synchronous
    /// caller hits a warm cache. The first `Query(language:data:)`
    /// compile for a grammar costs hundreds of ms (measured: ~400ms
    /// debug / ~130ms release for swift) and the HTMLRenderer fence
    /// path tokenizes SYNCHRONOUSLY on the main actor — so an unwarmed
    /// first MD open stalls main for the whole compile. Calling this
    /// from a background task at launch moves that cost off the user's
    /// first open. Safe from any thread: `bundle(for:)` is what the
    /// concurrent first-touch path already runs, and a racing real
    /// caller simply blocks on the per-language compile lock for the
    /// remainder of the in-flight compile instead of paying it all.
    ///
    /// TSK-840 — two phases. `prioritizing` languages compile FIRST and
    /// in order: these are the ones a racing first open needs
    /// synchronously (markdown drives the rendered-MD fence path, which
    /// tokenizes on the main actor; the opened file's language), so a
    /// first open blocks on at most those, not the whole batch. The
    /// remainder then compile CONCURRENTLY across cores — `bundle(for:)`
    /// is thread-safe (the outer lock guards only the dict + per-language
    /// lock fetch; a per-language `NSLock` serializes each slow compile;
    /// distinct languages compile independently — see its doc), and
    /// `GrammarLoader.load` is built for concurrent first-touch — so a
    /// concurrent sweep collapses the ~Nx serial wall (≈231ms on one
    /// thread, measured) to ≈ceil(N/cores). `concurrentPerform` blocks
    /// its caller, which is fine: the launch site is a detached utility
    /// task whose only job is this warm.
    public func warm(_ languages: [HighlightLanguage],
                     prioritizing first: [HighlightLanguage] = []) {
        // Phase 1: the synchronously-needed languages, serially, in order.
        var prioritized = Set<HighlightLanguage>()
        for lang in first where lang != .plainText {
            _ = bundle(for: lang)
            prioritized.insert(lang)
        }
        // Phase 2: everything else, concurrently across cores.
        let rest = languages.filter { $0 != .plainText && !prioritized.contains($0) }
        guard !rest.isEmpty else { return }
        DispatchQueue.concurrentPerform(iterations: rest.count) { i in
            _ = bundle(for: rest[i])
        }
    }

    /// True when `language`'s bundle is compiled and cached (a
    /// subsequent `tokenize` will not pay the query compile).
    public func isWarm(_ language: HighlightLanguage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cache[language] != nil
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
    /// TSK-854: this engine no longer drives HIGHLIGHTING (that is rust-only
    /// via `RustHighlightAdapter`). It survives ONLY for code-FOLDS +
    /// structural search, so the bundled Swift grammar set is now exactly the
    /// languages those features need — json/swift/markdown (eager) +
    /// xml/javascript/typescript/tsx (lazy). The 8 grammars that existed only
    /// as the deleted highlight fallback (python, bash, java, c, cpp, csharp,
    /// rust, lua) were dropped along with their dylibs to reclaim the ~16 MB
    /// double-carry; the Rust core still highlights all of them. A future Rust
    /// fold-region port (no FFI today) lets the rest of this engine retire.
    internal func languageHandle(for lang: HighlightLanguage) -> Language? {
        switch lang {
        // Keeplist — static link.
        case .swift:      return Language(language: tree_sitter_swift())
        case .json:       return Language(language: tree_sitter_json())
        case .markdown:   return Language(language: tree_sitter_markdown())

        // Lazy — dlopen via GrammarLoader. These are the languages with
        // bundled FOLD queries (see `foldQueryURL`); structural search can
        // also use them.
        case .xml:        return GrammarLoader.load(.xml)
        case .javascript: return GrammarLoader.load(.javascript)
        case .typescript: return GrammarLoader.load(.typescript)
        case .tsx:        return GrammarLoader.load(.tsx)

        // Highlight-only languages: the Rust core covers them; the Swift
        // engine no longer bundles their grammars (no folds, no fallback).
        default:          return nil
        }
    }

    /// Returns the URL of our vendored .scm for a language. Lookup goes through
    /// `Bundle.viewerCoreResources` (TSK-1257) so it resolves from the packaged
    /// app's `Contents/Resources` AND the xctest harness — not the dev-only
    /// `.build` path the raw `Bundle.module` accessor hardcodes.
    private func queryURL(for lang: HighlightLanguage) -> URL? {
        // TSK-854: only the languages with a bundled Swift grammar (see
        // `languageHandle`) have a reachable highlight query. The Swift
        // highlighter is gone — these queries serve nothing user-facing now
        // (highlighting is rust-only); they remain reachable only via the
        // diagnostic `HighlightParityHarness`/test path that still tokenizes
        // through this engine for the kept fold grammars.
        let stem: String
        switch lang {
        case .swift:      stem = "swift-highlights"
        case .json:       stem = "json-highlights"
        case .xml:        stem = "xml-highlights"
        case .javascript: stem = "javascript-highlights"
        case .typescript: stem = "typescript-highlights"
        // TSX reuses the TypeScript highlights query: every node type it
        // references exists in the (superset) TSX grammar, so it compiles
        // and colors the TS portions correctly.
        case .tsx:        stem = "typescript-highlights"
        case .markdown:   stem = "markdown-highlights"
        default:          return nil
        }
        return Bundle.viewerCoreResources.url(
            forResource: stem, withExtension: "scm", subdirectory: "Queries"
        )
    }
}
