import XCTest
import ViewerKit
@testable import ViewerCore
@testable import ViewerUI

/// TSK-962 — keep the CM6 host's hardcoded Lezer-tag → palette-key spec in
/// lock-step with the canonical `HighlightScopeMap`.
///
/// The editor's scope→kind table lives as a JS literal (`paletteExtensions` in
/// `Resources/codemirror/codemirror.html`); the canonical map declares the same
/// thing in Swift (`HighlightScopeMap.lezerTagsByKind`). They MUST agree, or
/// the editor paints a different set of scopes than the Source view — exactly
/// the View↔Edit divergence this epic closes. We can't run the JS host-side,
/// but we can EXTRACT the literal from the shipped HTML and diff it, so a JS
/// edit that drops/renames a tag (or maps it to a different palette key) fails
/// the host gate instead of as a silent on-screen mismatch.
///
/// Pure-logic (no WKWebView / window) — reads the bundled resource file. Host-
/// safe, not #192-gated.
final class HighlightScopeJSDriftTests: XCTestCase {

    /// Parse the `paletteExtensions` spec list out of the host HTML. Each spec
    /// is `{ tag: <X>, color: palette.<key>, ... }` where `<X>` is one Lezer
    /// tag or a `[...]` array of them. Returns `palette-key → set(tag)` exactly
    /// as the JS maps them. Returns nil if the block can't be located (so the
    /// test fails loudly rather than silently passing on an empty parse).
    private func parsePaletteSpecs(_ html: String) -> [String: Set<String>]? {
        guard let blockStart = html.range(of: "const specs = [") else {
            return nil
        }
        // The list is the `[...]` immediately following `const specs =`.
        let after = html[blockStart.upperBound...]
        guard let listEnd = after.range(of: "].filter(") else { return nil }
        let body = after[..<listEnd.lowerBound]

        // Each spec object: `{ tag: <tagExpr>, color: palette.<key> ... }`.
        // Match the tag expression (greedy up to the `, color:`) and the key.
        let specRE = try! NSRegularExpression(
            pattern: #"\{\s*tag:\s*([\s\S]*?),\s*color:\s*palette\.([A-Za-z]+)"#)
        // Within a tag expression, each Lezer tag is `t.<name>` optionally
        // wrapped in a single modifier call `t.<mod>(t.<name>)`.
        let tagRE = try! NSRegularExpression(
            pattern: #"t\.[A-Za-z]+(?:\(\s*t\.[A-Za-z]+\s*\))?"#)

        var out: [String: Set<String>] = [:]
        let bodyStr = String(body)
        let bodyRange = NSRange(bodyStr.startIndex..., in: bodyStr)
        for m in specRE.matches(in: bodyStr, range: bodyRange) {
            guard let tagExprR = Range(m.range(at: 1), in: bodyStr),
                  let keyR = Range(m.range(at: 2), in: bodyStr) else { continue }
            let tagExpr = String(bodyStr[tagExprR])
            let key = String(bodyStr[keyR])
            let teRange = NSRange(tagExpr.startIndex..., in: tagExpr)
            var tags = Set<String>()
            for tm in tagRE.matches(in: tagExpr, range: teRange) {
                if let r = Range(tm.range, in: tagExpr) {
                    // Normalize whitespace inside modifier calls
                    // (`t.function( t.variableName )` → `t.function(t.variableName)`).
                    let raw = String(tagExpr[r])
                    let normalized = raw.replacingOccurrences(
                        of: #"\s+"#, with: "", options: .regularExpression)
                    tags.insert(normalized)
                }
            }
            out[key, default: []].formUnion(tags)
        }
        return out
    }

    private func loadHTML() throws -> String {
        let url = try XCTUnwrap(
            CodeMirrorResources.hostHTMLURL,
            "codemirror.html missing from ViewerUI resources")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Sanity: the parser actually found the spec block + a healthy number of
    /// mappings (so a parse regression doesn't make the diff vacuously pass).
    func test_parserLocatesPaletteSpecs() throws {
        let html = try loadHTML()
        let specs = try XCTUnwrap(
            parsePaletteSpecs(html),
            "could not locate `const specs = [...]` in codemirror.html — the "
            + "JS host's palette spec moved or was renamed")
        XCTAssertGreaterThanOrEqual(
            specs.count, 15,
            "parsed only \(specs.count) palette specs — parser likely broke")
    }

    /// THE drift guard: the Lezer tags the JS host maps to each palette key are
    /// EXACTLY the canonical map's `lezerTags` for that `TokenKind`. Any
    /// add/drop/rename/re-key in the HTML fails here.
    func test_jsPaletteSpecsMatchCanonicalMap() throws {
        let html = try loadHTML()
        let js = try XCTUnwrap(parsePaletteSpecs(html))

        // Canonical: palette-key (TokenKind raw value) → set of Lezer tags.
        var canonical: [String: Set<String>] = [:]
        for (kind, tags) in HighlightScopeMap.lezerTagsByKind {
            canonical[kind.rawValue] = Set(tags)
        }

        // Every canonical kind must be mapped in the JS host …
        for (key, tags) in canonical {
            let jsTags = js[key] ?? []
            XCTAssertEqual(
                jsTags, tags,
                "Lezer tags for palette key '\(key)' diverge between "
                + "codemirror.html and HighlightScopeMap.\n  JS: \(jsTags.sorted())"
                + "\n  canonical: \(tags.sorted())")
        }

        // … and the JS host must not map any palette key the canonical map
        // doesn't know about (would be an editor-only color with no Source
        // counterpart).
        let canonicalKeys = Set(canonical.keys)
        let jsKeys = Set(js.keys)
        XCTAssertTrue(
            jsKeys.subtracting(canonicalKeys).isEmpty,
            "codemirror.html maps palette key(s) absent from HighlightScopeMap: "
            + "\(jsKeys.subtracting(canonicalKeys).sorted())")
    }
}
