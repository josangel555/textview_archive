import Foundation

/// A single foldable region in a parsed document.
///
/// Lines are **1-based and inclusive**. `startLine == endLine` is
/// disallowed; the engine drops single-line matches before they reach
/// callers (folding a one-line region has no visual effect and would
/// waste a chevron slot in the gutter).
///
/// Why a struct + value semantics: fold regions cross from the parser
/// (background actor) to the document model (`@MainActor`) and live
/// inside `Set`s for collapsed-state lookup. `Hashable` is exact —
/// two regions with the same `(startLine, endLine, kind)` ARE the
/// same fold from the user's POV, even if the underlying byte ranges
/// drift between re-parses.
public struct FoldRegion: Hashable, Sendable, Codable {
    public let startLine: Int    // 1-based, inclusive
    public let endLine: Int      // 1-based, inclusive
    public let kind: Kind

    public init(startLine: Int, endLine: Int, kind: Kind) {
        self.startLine = startLine
        self.endLine   = endLine
        self.kind      = kind
    }

    /// Number of lines this region covers (always ≥ 2 — see top doc).
    @inlinable public var lineCount: Int { endLine - startLine + 1 }

    /// Number of lines that disappear from view when this region is
    /// collapsed. The first line stays visible (it gets the ellipsis
    /// glyph appended); only `endLine - startLine` lines are hidden.
    @inlinable public var hiddenLineCount: Int { endLine - startLine }

    public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
        case object         // { ... } JSON / JS object literal
        case array          // [ ... ] JSON / JS array literal
        case function       // function / closure body
        case type           // class / struct / enum / interface body
        case codeFence      // ``` ... ``` in markdown
        case comment        // /* ... */ or run of // ... comments
        case stringLiteral  // multi-line string ("""…""", `…`)
        case element        // XML / JSX element
        case heading        // markdown heading → next-heading region
        case other          // generic ≥2-line container we recognized
    }
}

/// Per-document set of folds plus the user's collapsed selection.
/// Lives on `DocumentModel` alongside other per-tab state.
///
/// `collapsed` is a `Set<FoldRegion>` not `Set<UUID>` because the
/// region's `(startLine, endLine, kind)` triple IS the identity; after
/// a re-parse, regions that still exist at the same location remain
/// collapsed, regions that moved/disappeared cleanly drop out.
public struct FoldState: Sendable, Equatable, Codable {
    public var regions: [FoldRegion]
    public var collapsed: Set<FoldRegion>

    public init(regions: [FoldRegion] = [], collapsed: Set<FoldRegion> = []) {
        self.regions  = regions
        self.collapsed = collapsed
    }

    /// Replace the region list (e.g. after a re-parse) while keeping
    /// the `collapsed` set semantically stable: any previously
    /// collapsed region that no longer appears in `newRegions` is
    /// dropped. O(R) on the size of `collapsed`.
    public mutating func updateRegions(_ newRegions: [FoldRegion]) {
        self.regions = newRegions
        guard !collapsed.isEmpty else { return }
        let present = Set(newRegions)
        collapsed.formIntersection(present)
    }

    /// Smallest enclosing fold region for a given 1-based line, or nil
    /// if the line isn't inside any fold. "Smallest" = inner-most;
    /// disambiguates nested braces (e.g. caret in a function whose body
    /// contains an object literal → returns the object).
    public func smallestRegion(containing line: Int) -> FoldRegion? {
        var best: FoldRegion?
        var bestSpan = Int.max
        for r in regions where r.startLine <= line && line <= r.endLine {
            if r.lineCount < bestSpan {
                best = r
                bestSpan = r.lineCount
            }
        }
        return best
    }

    /// Regions whose `startLine` equals `line`. Used by the gutter to
    /// render a chevron on every fold-start line.
    public func regionsStarting(at line: Int) -> [FoldRegion] {
        regions.filter { $0.startLine == line }
    }
}
