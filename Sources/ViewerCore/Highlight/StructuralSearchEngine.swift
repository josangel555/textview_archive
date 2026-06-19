import Foundation
import SwiftTreeSitter
import ViewerKit

/// AST-match engine for `StructuralQuery`. Parses `text` in a language, walks
/// the resulting tree, and returns every node that satisfies the query along
/// with its captures and ranges.
///
/// Lives as a `TreeSitterEngine` extension so it shares the engine's existing
/// `languageHandle(for:)` resolver, the `highlightMaxBytes` size guard, and the
/// per-call `Parser` discipline (a fresh parser per call → no shared parser
/// state across concurrent searches). Mirrors `TreeSitterEngine+Folds.swift`.
///
/// The matcher is PURE host logic (parse + tree walk + field/text checks) — no
/// rendering, no WebView, no main-actor coupling — so it's fully host-testable.
///
/// ## Offset units
/// SwiftTreeSitter parses through the UTF-16 path (`Parser.parse(_:)` feeds
/// `TSInputEncodingUTF16LE`), and its `Node.range` accessor returns an
/// `NSRange` ALREADY in UTF-16 code units — the AppKit / `NSTextView` /
/// SwiftUI text model. So we consume `node.range` directly: no byte↔unit
/// conversion, and a multi-byte / emoji prefix does NOT shift a match's range.
/// Source text for a node is sliced from the string's UTF-16 view at that
/// `NSRange`, which round-trips correctly for any BMP / surrogate-pair content.
extension TreeSitterEngine {

    /// Run `query` against `text` parsed as `language`. Returns matches in
    /// document order (ascending start offset). Empty when the language can't
    /// load, `text` exceeds `highlightMaxBytes`, or nothing matches — never
    /// throws (search is best-effort, same contract as `tokenize`).
    ///
    /// v1 scopes the supported grammar to whatever `languageHandle(for:)`
    /// resolves; the pattern grammar itself (`StructuralQuery`) is
    /// language-agnostic — node-kind strings are simply the grammar's named
    /// node types for that language.
    public func structuralSearch(
        _ query: StructuralQuery,
        in text: String,
        language: HighlightLanguage
    ) -> [StructuralMatch] {
        guard language != .plainText else { return [] }
        guard text.utf8.count <= highlightMaxBytes else { return [] }
        guard let language = languageHandle(for: language) else { return [] }

        let parser = Parser()
        do { try parser.setLanguage(language) }
        catch { return [] }

        guard let tree = parser.parse(text), let root = tree.rootNode else { return [] }

        // UTF-16 code units of the source, indexed by `node.range` (NSRange).
        // Slicing this view by an NSRange recovers a node's source text.
        let utf16 = Array(text.utf16)

        var matches: [StructuralMatch] = []
        matches.reserveCapacity(32)

        // Pre-order DFS. We test EVERY node against the top pattern (matches
        // can nest — a function inside a function — and downstream UIs want
        // them all). Visiting children in `child(at:)` order (document order)
        // and appending on visit yields ascending-start output without a final
        // sort. Recursion (not an explicit stack) keeps sibling order natural;
        // syntax trees are shallow relative to node count and TS guards depth.
        func visit(_ node: Node) {
            if let m = match(node, against: query, utf16: utf16) {
                matches.append(m)
            }
            for i in 0..<node.childCount {
                if let child = node.child(at: i) { visit(child) }
            }
        }
        visit(root)
        return matches
    }

    // MARK: - Matching

    /// Attempt to match `node` against `query`. Returns a `StructuralMatch`
    /// (with merged captures) on success, `nil` otherwise.
    private func match(
        _ node: Node,
        against query: StructuralQuery,
        utf16: [UInt16]
    ) -> StructuralMatch? {
        // 1. Kind gate. Empty `kinds` == wildcard (any kind).
        let kind = node.nodeType ?? ""
        if !query.kinds.isEmpty, !query.kinds.contains(kind) { return nil }

        var captures: [String: StructuralCapture] = [:]

        // Root capture: the whole node's text + range.
        if let capName = query.captureAs {
            insert(capture: makeCapture(name: capName, node: node, utf16: utf16), into: &captures)
        }

        // 2. Field constraints (AND). Any failure rejects the node.
        for constraint in query.fieldConstraints {
            guard let fieldNode = node.child(byFieldName: constraint.field) else { return nil }
            let fieldText = sourceText(of: fieldNode, utf16: utf16)
            switch constraint.predicate {
            case .textEquals(let want):
                if fieldText != want { return nil }
            case .textContains(let want):
                if !fieldText.contains(want) { return nil }
            case .kindEquals(let want):
                if (fieldNode.nodeType ?? "") != want { return nil }
            case .capture(let name):
                insert(
                    capture: StructuralCapture(name: name, text: fieldText, range: fieldNode.range),
                    into: &captures)
            }
        }

        // 3. Child patterns: each must match SOME descendant. Merge the
        // descendant's captures up into this match (outermost-wins on clash).
        for childPattern in query.childPatterns {
            guard let descMatch = firstDescendantMatch(
                under: node, against: childPattern, utf16: utf16
            ) else { return nil }
            for (_, cap) in descMatch.captures { insert(capture: cap, into: &captures) }
        }

        return StructuralMatch(kind: kind, range: node.range, captures: captures)
    }

    /// First descendant of `node` (excluding `node` itself) matching `query`,
    /// in document order. Used to satisfy a child pattern.
    private func firstDescendantMatch(
        under node: Node,
        against query: StructuralQuery,
        utf16: [UInt16]
    ) -> StructuralMatch? {
        for i in 0..<node.childCount {
            guard let child = node.child(at: i) else { continue }
            if let m = match(child, against: query, utf16: utf16) { return m }
            if let deeper = firstDescendantMatch(under: child, against: query, utf16: utf16) {
                return deeper
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Outermost / earliest binding wins: never overwrite an existing capture.
    private func insert(capture: StructuralCapture, into dict: inout [String: StructuralCapture]) {
        if dict[capture.name] == nil { dict[capture.name] = capture }
    }

    private func makeCapture(name: String, node: Node, utf16: [UInt16]) -> StructuralCapture {
        StructuralCapture(name: name, text: sourceText(of: node, utf16: utf16), range: node.range)
    }

    /// Source text covered by a node, sliced from the UTF-16 buffer at the
    /// node's `NSRange`. Defends against an out-of-bounds / inverted range
    /// (returns "" rather than trapping) — node ranges are always valid, but
    /// the guard keeps a malformed grammar from crashing a search.
    private func sourceText(of node: Node, utf16: [UInt16]) -> String {
        let r = node.range
        guard r.location != NSNotFound, r.location >= 0, r.length >= 0,
              r.location + r.length <= utf16.count else { return "" }
        let slice = utf16[r.location ..< (r.location + r.length)]
        return String(decoding: slice, as: UTF16.self)
    }
}
