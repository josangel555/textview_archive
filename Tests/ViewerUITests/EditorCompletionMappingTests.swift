import XCTest
@testable import ViewerUI
import ViewerCore

/// TSK-1136 — host coverage for the LSP→editor completion mapping that
/// `DocumentModel.requestCompletions` now feeds from `LSPPool.completion`. The live
/// round-trip + the CM6 autocomplete bridge are VM/render; this pins the pure
/// transform (ordering + field mapping) so a regression fails the host gate.
final class EditorCompletionMappingTests: XCTestCase {
    private func item(
        _ label: String, sort: String, detail: String? = nil, insert: String? = nil
    ) -> LSPCompletionItem {
        LSPCompletionItem(
            label: label, kind: nil, detail: detail, documentation: nil,
            insert: insert ?? label, editRange: nil, filterText: label,
            sortText: sort, isSnippet: false)
    }

    func test_orders_by_sortText_then_label_and_maps_fields() {
        let items = [
            item("zebra", sort: "2", detail: "Z"),
            item("mango", sort: "1"),
            item("apple", sort: "1", insert: "apple()"),
        ]
        let mapped = DocumentModel.editorCompletions(from: items)
        // sortText ascending, label as the stable tiebreak for equal sortText.
        XCTAssertEqual(mapped.map(\.label), ["apple", "mango", "zebra"])
        // `insert` (spec-resolved commit text) drives insertText; detail carries through.
        XCTAssertEqual(mapped.first { $0.label == "apple" }?.insertText, "apple()")
        XCTAssertEqual(mapped.first { $0.label == "zebra" }?.detail, "Z")
        XCTAssertEqual(mapped.first { $0.label == "mango" }?.insertText, "mango")
    }

    func test_empty_input_maps_to_empty() {
        XCTAssertTrue(DocumentModel.editorCompletions(from: []).isEmpty)
    }
}
