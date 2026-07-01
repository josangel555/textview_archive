import XCTest
import ViewerKit
@testable import ViewerUI

/// TSK-1140 — pure coverage for the ⌘F bag-routing decision extracted from
/// `main.swift.findInPage`. A wrong branch means ⌘F opens a find bar that can't
/// search the active content (the exact bug the PDF branch fixes). Order-sensitive.
final class FindBarRoutingTests: XCTestCase {

    func test_rendered_whenTogglableAndRendered() {
        XCTAssertEqual(
            FindBarRouting.target(viewMode: .rendered, category: .markdown, supportsViewModeToggle: true),
            .rendered)
    }

    func test_editor_whenEditorMode_regardlessOfCategory() {
        XCTAssertEqual(
            FindBarRouting.target(viewMode: .editor, category: .plainText, supportsViewModeToggle: true),
            .editor)
    }

    func test_pdf_whenPdfCategory_andNotRenderedOrEditor() {
        // TSK-1140: a PDF tab routes to the PDF find bar (was falling through to source).
        XCTAssertEqual(
            FindBarRouting.target(viewMode: .source, category: .pdf, supportsViewModeToggle: false),
            .pdf)
    }

    func test_source_default() {
        XCTAssertEqual(
            FindBarRouting.target(viewMode: .source, category: .plainText, supportsViewModeToggle: true),
            .source)
    }

    func test_rendered_fallsThroughToSource_whenNotTogglable() {
        // HTML in rendered mode has no find runtime + no toggle → source, not rendered.
        XCTAssertEqual(
            FindBarRouting.target(viewMode: .rendered, category: .html, supportsViewModeToggle: false),
            .source)
    }

    func test_editorWins_overPdfCategory() {
        // ORDER: editor beats the pdf-category branch (defensive — shouldn't co-occur).
        XCTAssertEqual(
            FindBarRouting.target(viewMode: .editor, category: .pdf, supportsViewModeToggle: false),
            .editor)
    }

    func test_nilCategory_isSource() {
        XCTAssertEqual(
            FindBarRouting.target(viewMode: .source, category: nil, supportsViewModeToggle: true),
            .source)
    }
}
