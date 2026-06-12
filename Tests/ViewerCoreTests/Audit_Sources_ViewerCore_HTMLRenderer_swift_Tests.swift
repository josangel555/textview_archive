import XCTest
@testable import ViewerCore

/// Regression coverage for the PARSE-03 *input-side* deep-nesting guard
/// in `HTMLRenderer.render` (audit finding,
/// `Sources/ViewerCore/HTMLRenderer.swift:16`).
///
/// The visitor's `maxDepth` guard runs DOWNSTREAM of `Document(parsing:)`.
/// cmark-gfm's native-C recursive descent overflows the stack and SIGSEGVs
/// the process on ~5000–6000 leading `>` (or list indentation) *before* the
/// visitor ever runs. The existing `G5ParserHardeningTests` deliberately
/// stay under cmark's parser limit (700 nests), so they never exercise the
/// real crash. This suite feeds the adversarial 10k-nested-`>` shape and
/// asserts the pre-parse scan short-circuits to a graceful, non-empty
/// result instead of crashing.
///
/// Host-safe: pure value logic, no AppKit / WKWebView.
final class Audit_Sources_ViewerCore_HTMLRenderer_swift_Tests: XCTestCase {

    private let renderer = HTMLRenderer()

    // MARK: - The crash repro: 10k leading `>` must not SIGSEGV

    func test_render_10k_nested_blockquote_does_not_crash() {
        // ~10k leading `>` is ~2× cmark's empirically-bisected crash floor
        // (~5000–6000). Before the input-side guard this faulted with
        // SIGSEGV (rc=139) inside Document(parsing:). The render must
        // instead return a graceful, non-empty marker.
        let deep = String(repeating: ">", count: 10_000) + " boom\n"
        let html = HTMLRenderer.renderSwiftPath(deep)
        XCTAssertFalse(html.isEmpty, "deep nesting must yield a graceful result, not a crash")
        XCTAssertEqual(html, HTMLVisitor.truncationMarker,
                       "over-deep input short-circuits to the truncation marker")
    }

    func test_render_10k_nested_blockquote_with_spaces_does_not_crash() {
        // The "> " spaced form doubles the per-line leading run.
        let deep = String(repeating: "> ", count: 10_000) + "boom\n"
        let html = HTMLRenderer.renderSwiftPath(deep)
        XCTAssertFalse(html.isEmpty)
        XCTAssertTrue(html.contains("truncated"))
    }

    func test_render_deep_list_indentation_does_not_crash() {
        // Leading-whitespace nesting (list-item continuation) is the other
        // arm cmark recurses on. A multi-thousand-space leading run trips
        // the same input-side ceiling.
        let deep = String(repeating: " ", count: 8_000) + "- item\n"
        let html = HTMLRenderer.renderSwiftPath(deep)
        XCTAssertEqual(html, HTMLVisitor.truncationMarker)
    }

    // MARK: - The guard predicate directly

    func test_exceedsLeadingBlockNesting_flags_over_blockquote_ceiling() {
        let over = String(repeating: ">", count: HTMLRenderer.maxLeadingBlockquoteRun + 1)
        XCTAssertTrue(HTMLRenderer.exceedsLeadingBlockNesting(over))
    }

    func test_exceedsLeadingBlockNesting_flags_over_indent_ceiling() {
        let over = String(repeating: " ", count: HTMLRenderer.maxLeadingIndentRun + 1) + "- x\n"
        XCTAssertTrue(HTMLRenderer.exceedsLeadingBlockNesting(over))
    }

    func test_exceedsLeadingBlockNesting_allows_at_and_below_ceiling() {
        let atBQ = String(repeating: ">", count: HTMLRenderer.maxLeadingBlockquoteRun)
        XCTAssertFalse(HTMLRenderer.exceedsLeadingBlockNesting(atBQ),
                       "exactly the blockquote ceiling is allowed; only strictly above is rejected")
        let atIndent = String(repeating: " ", count: HTMLRenderer.maxLeadingIndentRun) + "x\n"
        XCTAssertFalse(HTMLRenderer.exceedsLeadingBlockNesting(atIndent),
                       "exactly the indent ceiling is allowed")
        let below = String(repeating: ">", count: 100) + " quote\n"
        XCTAssertFalse(HTMLRenderer.exceedsLeadingBlockNesting(below))
    }

    func test_exceedsLeadingBlockNesting_blockquote_padding_spaces_not_indent() {
        // `> > > …` spends its leading bytes as `>` plus a single padding
        // space each. The contiguous-whitespace run must never exceed 1, so
        // a 5000-deep `> ` chain is governed purely by the blockquote
        // ceiling (5000 <= 5500) and is NOT rejected — guarding the live
        // host G5 corpus from a false reject.
        let spaced = String(repeating: "> ", count: 5_000) + "x\n"
        XCTAssertFalse(HTMLRenderer.exceedsLeadingBlockNesting(spaced),
                       "padding spaces between `>` markers must not count as deep indent")
    }

    func test_exceedsLeadingBlockNesting_resets_per_line() {
        // A short leading run on each of many lines must NOT accumulate
        // across line breaks — the bound is per-line maximal nesting.
        let manyShallow = String(
            repeating: ">>>> shallow\n",
            count: 4_000
        )
        XCTAssertFalse(HTMLRenderer.exceedsLeadingBlockNesting(manyShallow),
                       "per-line run must reset at each line break")
    }

    func test_exceedsLeadingBlockNesting_ignores_markers_not_at_line_start() {
        // `>` and spaces after real content are NOT leading block-nesting;
        // a long mid-line run of them must not trip the guard.
        let midLine = "text " + String(repeating: "> ", count: 5_000) + "more\n"
        XCTAssertFalse(HTMLRenderer.exceedsLeadingBlockNesting(midLine),
                       "only the leading run counts, not mid-line markers")
    }

    // MARK: - The guard must not regress legitimate documents

    func test_render_normal_document_unaffected_by_input_guard() {
        let html = HTMLRenderer.renderSwiftPath("> quote\n\n- a\n- b\n\n# Heading\n")
        XCTAssertFalse(html.contains("truncated"))
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("quote"))
    }

    func test_render_moderately_deep_doc_still_reaches_visitor_guard() {
        // 700 leading `>` (no interleaved spaces) = a 700-deep blockquote
        // run, which survives the input-side blockquote ceiling (5500) but
        // nests cmark's blockquote tree past the visitor's maxDepth (512). So it must
        // reach the visitor and emit the visitor-side truncation marker —
        // i.e. the input guard does NOT pre-empt the legitimate downstream
        // path; it only catches the genuinely cmark-crashing shapes.
        XCTAssertFalse(HTMLRenderer.exceedsLeadingBlockNesting(
            String(repeating: ">", count: 700)),
            "700 leading `>` must stay under the input-side ceiling")
        let deep = String(repeating: ">", count: 700) + " x\n"
        let html = HTMLRenderer.renderSwiftPath(deep)
        XCTAssertTrue(html.contains("truncated"))
        XCTAssertTrue(html.contains("blockquote"),
                      "moderately-deep input still parses through cmark + visitor")
    }
}
