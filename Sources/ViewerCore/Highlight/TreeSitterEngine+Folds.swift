import Foundation
import SwiftTreeSitter
import ViewerKit

/// Fold-region computation. Lives in its own file to keep the
/// highlighter (`TreeSitterEngine`) focused on tokenization. Shares
/// the engine's per-language language-handle resolver via the existing
/// `languageHandle(for:)` method (file-private elsewhere; exposed
/// internally here via this same module).
extension TreeSitterEngine {

    // MARK: Public API

    /// Returns the fold regions for `text` in `language`, or an empty
    /// array if the language has no fold support or `text` exceeds
    /// `highlightMaxBytes`. Results are cached on `(language, hash)`.
    ///
    /// Cold parse + query of a 10K-line JSON file should complete in
    /// well under 50 ms on Apple Silicon; see `FoldRegionBenchTests`.
    /// Most cost is the TS parse itself — the query phase iterates
    /// matches once and emits one region per match.
    public func computeFolds(
        text: String, language: HighlightLanguage
    ) async -> [FoldRegion] {
        guard language != .plainText else { return [] }
        guard text.utf8.count <= highlightMaxBytes else { return [] }

        let hash = Self.contentHash(text)
        if let hit = foldCacheLookup(language: language, hash: hash) {
            return hit
        }

        // Compute off the calling task's actor. The work is CPU-bound
        // (parse + walk) and the engine is `@unchecked Sendable`.
        let regions = await Task.detached(priority: .userInitiated) {
            Self.shared.computeFoldsSync(text: text, language: language)
        }.value

        foldCacheStore(language: language, hash: hash, regions: regions)
        return regions
    }

    /// Synchronous variant for tests and benchmarks. Bypasses the
    /// per-language async cache.
    public func computeFoldsSync(
        text: String, language: HighlightLanguage
    ) -> [FoldRegion] {
        guard language != .plainText else { return [] }
        guard text.utf8.count <= highlightMaxBytes else { return [] }
        guard let bundle = foldBundle(for: language) else { return [] }

        let parser = Parser()
        do { try parser.setLanguage(bundle.language) }
        catch { return [] }

        guard let tree = parser.parse(text) else { return [] }
        guard let root = tree.rootNode else { return [] }

        // Total line count for trailing fold ends (markdown heading
        // folds need it). Counted via newlines; a file that doesn't
        // end with `\n` still has its trailing chunk as a line.
        let totalLines: Int = {
            var n = 1
            for b in text.utf8 where b == 0x0A { n += 1 }
            // If text ends in newline, last "line" is empty but
            // NSTextView counts it; preserve that.
            return n
        }()

        var out: [FoldRegion] = []
        out.reserveCapacity(64)

        let cursor = bundle.query.execute(node: root, in: tree)
        // Markdown headings are captured here but post-processed below
        // into span-to-next-heading folds. Stash them separately.
        var headings: [(line: Int, level: Int)] = []

        for match in cursor {
            for cap in match.captures {
                guard let name = cap.name else { continue }
                let node = cap.node
                // Use tree-sitter's pointRange — row is 0-based line
                // number, exactly what we want. Avoids us rolling a
                // byte→line mapper (which had subtle off-by-ones with
                // documents that did / didn't end in `\n`).
                let pr = node.pointRange
                let startLine = Int(pr.lowerBound.row) + 1
                // End point's row points at the line where the node's
                // closing token sits. When the node ends exactly at a
                // line boundary (column 0), the row is one past the
                // last visual line of the node — back off in that case
                // so a `}` at the start of line N doesn't claim line
                // N+1.
                var endLine = Int(pr.upperBound.row) + 1
                if pr.upperBound.column == 0 && endLine > startLine {
                    endLine -= 1
                }

                // Heading captures are SINGLE-line nodes — process them
                // before the multi-line guard so we can stash them for
                // the heading-fold post-pass. We compute the heading
                // level from the source line directly (the # count at
                // the start, after any leading whitespace) — tree-sitter
                // emits `atx_h<N>_marker` children but those would
                // require a parametric query per level.
                if name == "fold.heading" {
                    let level = Self.atxHeadingLevel(forLine: startLine, in: text)
                    headings.append((line: startLine, level: level))
                    continue
                }

                guard endLine > startLine else { continue }   // skip single-line

                guard let kind = Self.kind(forCapture: name) else { continue }
                out.append(FoldRegion(startLine: startLine,
                                      endLine: min(endLine, totalLines),
                                      kind: kind))
            }
        }

        // Materialise heading folds (markdown only).
        if !headings.isEmpty {
            headings.sort { $0.line < $1.line }
            for (i, h) in headings.enumerated() {
                // End = (line - 1) of the next heading at level ≤ h.level.
                // Falls back to last line of the file.
                var end = totalLines
                for j in (i + 1)..<headings.count {
                    if headings[j].level <= h.level {
                        end = headings[j].line - 1
                        break
                    }
                }
                if end > h.line {
                    out.append(FoldRegion(startLine: h.line,
                                          endLine: end,
                                          kind: .heading))
                }
            }
        }

        // Dedup: nested grammars can occasionally yield the same range
        // under two captures (e.g. an XML element that is also captured
        // by a parent rule). Hashing on (start,end,kind) collapses dups.
        var seen = Set<FoldRegion>()
        var deduped: [FoldRegion] = []
        deduped.reserveCapacity(out.count)
        for r in out where seen.insert(r).inserted {
            deduped.append(r)
        }
        // Sort for stable downstream behavior: start ASC, end DESC so
        // outer folds appear before inner — `smallestRegion` still
        // wins because it picks min span explicitly.
        deduped.sort { a, b in
            if a.startLine != b.startLine { return a.startLine < b.startLine }
            return a.endLine > b.endLine
        }
        return deduped
    }

    // MARK: Capture → kind

    /// Mapping from `.scm` capture-name to `FoldRegion.Kind`. Keep in
    /// sync with the queries under `Highlight/Queries/<lang>-folds.scm`.
    internal static func kind(forCapture name: String) -> FoldRegion.Kind? {
        switch name {
        case "fold.object":          return .object
        case "fold.array":           return .array
        case "fold.function":        return .function
        case "fold.type":            return .type
        case "fold.codeFence":       return .codeFence
        case "fold.comment":         return .comment
        case "fold.stringLiteral":   return .stringLiteral
        case "fold.element":         return .element
        case "fold.heading":         return .heading
        case "fold.other":           return .other
        // Legacy: bare `@fold` (no suffix) → `.other`. Lets us accept
        // upstream-vendored folds.scm files unchanged.
        case "fold":                 return .other
        default:                     return nil
        }
    }

    // MARK: Line index

    /// Build `[byteOffsetOfStartOfLine_i]`, one entry per 1-based line.
    /// Index 0 is unused; index 1 is byte 0 (start of line 1). The
    /// last index points at the start of the last real line — there
    /// is NO synthetic "after-EOF" entry, so `lineStarts.count - 1`
    /// equals the true line count.
    ///
    /// Tree-sitter reports byte offsets in the source string's UTF-8
    /// encoding. We walk the UTF-8 view once to find newline positions.
    /// O(N) in input size. Output is in *UTF-8 bytes*, matching what
    /// `node.byteRange` returns.
    internal static func lineStarts(in text: String) -> [Int] {
        var starts: [Int] = [0, 0]   // dummy at 0, line-1 starts at 0
        let utf8 = text.utf8
        var byte = 0
        for b in utf8 {
            byte += 1
            if b == 0x0A { starts.append(byte) }   // '\n'
        }
        // If `text` ends in '\n' we already appended the next line's
        // start; otherwise the trailing content is line N already
        // covered by the previous newline append (or the initial
        // line-1 entry for a single-line file).
        //
        // Note: an empty trailing line *exists* in NSTextView's count
        // for a file that ends in '\n'. The last `starts` entry sits
        // exactly at EOF in that case, representing that empty line.
        return starts
    }

    /// 1-based line number containing the given UTF-8 byte offset.
    /// Binary-search on `lineStarts`. O(log N). Clamps the result to
    /// the valid 1..(lineStarts.count - 1) range.
    internal static func lineNumber(forByte byte: Int, in lineStarts: [Int]) -> Int {
        let maxLine = max(1, lineStarts.count - 1)
        // lineStarts[i] = byte offset of line i (i ≥ 1).
        // We want max i s.t. lineStarts[i] ≤ byte.
        var lo = 1
        var hi = maxLine
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= byte {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return lo
    }

    /// Compute the ATX heading level (# count) for the heading on the
    /// given 1-based line. Walks the line until it sees a non-`#` (after
    /// optional leading whitespace). Capped at 6. Defaults to 1 on
    /// malformed inputs.
    internal static func atxHeadingLevel(forLine line: Int, in text: String) -> Int {
        // Find the start of `line` by counting `\n`s.
        let utf8 = Array(text.utf8)
        var seenLines = 1
        var i = 0
        while seenLines < line && i < utf8.count {
            if utf8[i] == 0x0A { seenLines += 1 }
            i += 1
        }
        guard seenLines == line else { return 1 }
        // Skip leading whitespace (markdown allows up to 3 spaces).
        while i < utf8.count, utf8[i] == 0x20 || utf8[i] == 0x09 { i += 1 }
        // Count `#`s.
        var level = 0
        while i < utf8.count, utf8[i] == 0x23, level < 6 {
            level += 1
            i += 1
        }
        return level == 0 ? 1 : level
    }

    // MARK: Content hashing

    /// FNV-1a 64 over the UTF-8 view. Fast, no allocation, collision
    /// rate fine for cache-keying on a per-tab basis. Matches the same
    /// hash style used by the highlight engine elsewhere.
    internal static func contentHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return h
    }

    // MARK: Per-language bundle (folds.scm)

    /// Lazy load of `<lang>-folds.scm`. Reuses the engine's
    /// `languageHandle(for:)` for the C symbol. Cached & failure-memoed
    /// inside `TreeSitterEngine` via the shared `foldBundles` storage
    /// in the main type's stored properties (see end of this file).
    fileprivate func foldBundle(for lang: HighlightLanguage) -> FoldBundle? {
        foldLock.lock()
        if let hit = foldBundles[lang] { foldLock.unlock(); return hit }
        if foldFailed.contains(lang)   { foldLock.unlock(); return nil }
        foldLock.unlock()

        guard let language = languageHandle(for: lang),
              let url = foldQueryURL(for: lang) else {
            foldLock.lock(); foldFailed.insert(lang); foldLock.unlock()
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let q = try Query(language: language, data: data)
            let b = FoldBundle(language: language, query: q)
            foldLock.lock(); foldBundles[lang] = b; foldLock.unlock()
            return b
        } catch {
            foldLock.lock(); foldFailed.insert(lang); foldLock.unlock()
            return nil
        }
    }

    private func foldQueryURL(for lang: HighlightLanguage) -> URL? {
        let stem: String
        switch lang {
        case .json:       stem = "json-folds"
        case .xml:        stem = "xml-folds"
        case .swift:      stem = "swift-folds"
        case .javascript: stem = "javascript-folds"
        case .typescript: stem = "typescript-folds"
        case .markdown:   stem = "markdown-folds"
        default:          return nil
        }
        return Bundle.module.url(
            forResource: stem, withExtension: "scm", subdirectory: "Queries"
        )
    }

    // MARK: Result cache

    fileprivate func foldCacheLookup(
        language: HighlightLanguage, hash: UInt64
    ) -> [FoldRegion]? {
        foldLock.lock(); defer { foldLock.unlock() }
        guard let entry = foldCache[language], entry.hash == hash else {
            return nil
        }
        return entry.regions
    }

    fileprivate func foldCacheStore(
        language: HighlightLanguage, hash: UInt64, regions: [FoldRegion]
    ) {
        foldLock.lock()
        foldCache[language] = FoldCacheEntry(hash: hash, regions: regions)
        foldLock.unlock()
    }

    /// Test-only: drop all fold caches so a cold-parse benchmark runs
    /// the actual work each call.
    public func _testOnly_clearFoldCaches() {
        foldLock.lock()
        foldCache.removeAll()
        foldLock.unlock()
    }
}

/// Per-language compiled fold query, parallel to the highlight bundle.
internal struct FoldBundle {
    let language: Language
    let query: Query
}

internal struct FoldCacheEntry {
    let hash: UInt64
    let regions: [FoldRegion]
}
