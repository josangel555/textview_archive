import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-637: the OUTLINE panel's model serves markdown WITHOUT an LSP server
/// — the heading tree flows through the same `LSPDocumentSymbol` surface the
/// panel already renders. Headless (model layer; no window, no pool calls —
/// the markdown branch is synchronous and never touches the LSP pool).
final class MarkdownOutlinePanelTests: HeadlessUITestCase {

    @MainActor
    private func makeModel() -> LSPOutlineModel {
        LSPOutlineModel(pool: LSPPool())
    }

    @MainActor
    func test_markdownFile_isSupported_andServesHeadingTree() {
        let model = makeModel()
        model.setFile(
            URL(fileURLWithPath: "/tmp/doc.md"),
            text: "# One\n## One.A\n# Two\n")
        XCTAssertTrue(model.isSupported, ".md must be outline-supported now")
        XCTAssertFalse(model.isLoading, "the markdown branch is synchronous")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.symbols.map(\.name), ["One", "Two"])
        XCTAssertEqual(model.symbols.first?.children.map(\.name), ["One.A"])
    }

    @MainActor
    func test_markdownExtensionVariants_andUnsupportedStaysUnsupported() {
        let model = makeModel()
        model.setFile(URL(fileURLWithPath: "/tmp/doc.markdown"), text: "# H\n")
        XCTAssertTrue(model.isSupported)
        XCTAssertEqual(model.symbols.map(\.name), ["H"])

        // A registry-less, non-markdown file stays unsupported (the
        // pre-TSK-637 gate is intact for everything else).
        model.setFile(URL(fileURLWithPath: "/tmp/notes.txt"), text: "# not md\n")
        XCTAssertFalse(model.isSupported)
        XCTAssertTrue(model.symbols.isEmpty)
    }

    @MainActor
    func test_clearingFile_resets() {
        let model = makeModel()
        model.setFile(URL(fileURLWithPath: "/tmp/doc.md"), text: "# H\n")
        XCTAssertTrue(model.isSupported)
        model.setFile(nil, text: nil)
        XCTAssertFalse(model.isSupported)
        XCTAssertTrue(model.symbols.isEmpty)
    }
}
