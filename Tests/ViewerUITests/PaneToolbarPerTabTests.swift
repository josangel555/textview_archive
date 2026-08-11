import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// I-21 pane toolbars (owner 2026-08-11: "each tab identifies its content
/// and decides its own visualization") — the per-TAB display derivations
/// the split panes' `ContentToolbar` renders from. Each pins that the
/// PASSED tab's data drives the answer, independent of the app-wide
/// selected tab (the classic selected-tab properties stay untouched).
@MainActor
final class PaneToolbarPerTabTests: XCTestCase {

    private func makeTab(_ name: String, viewMode: ViewMode = .editor) -> Tab {
        Tab(url: URL(fileURLWithPath: "/tmp/panetb/\(name)"),
            state: .empty, viewMode: viewMode)
    }

    func test_toolbarModeSegments_deriveFromTheTabsContentType() {
        let model = DocumentModel()
        let md = makeTab("doc.md"), txt = makeTab("notes.txt")
        XCTAssertEqual(model.toolbarModeSegments(for: md),
                       [.primary(.render), .split, .primary(.editor), .primary(.hex)],
                       "markdown offers Render | Split | Editor | HEX")
        XCTAssertEqual(model.toolbarModeSegments(for: txt),
                       [.primary(.editor), .primary(.hex)],
                       "plain text has no rich lens and no Split")
    }

    func test_presentation_readsTheTabsOwnLens_notTheSelectedTabs() {
        let model = DocumentModel()
        let rendered = makeTab("a.md", viewMode: .rendered)
        let editor = makeTab("b.md", viewMode: .editor)
        model.tabCoordinator.append(rendered)
        model.tabCoordinator.append(editor)   // b selected (editor lens)

        XCTAssertEqual(model.viewModePresentation(for: rendered).primary, .render,
                       "the pane toolbar shows ITS tab's lens")
        XCTAssertEqual(model.viewModePresentation.primary, .editor,
                       "the classic selected-tab read is untouched")
    }

    func test_segmentSelection_readsTheTabsSplitFlag() {
        let model = DocumentModel()
        var split = makeTab("c.md", viewMode: .editor)
        split.isSplitEditing = true
        let p = model.viewModePresentation(for: split)
        XCTAssertTrue(model.isToolbarSegmentSelected(.split, presentation: p, tab: split))
        XCTAssertFalse(model.isToolbarSegmentSelected(
            .primary(.editor), presentation: p, tab: split),
            "Split claims the selection exclusively (TSK-898 rule, per tab)")
    }

    func test_pathBreadcrumb_forURL_walksThatPath_andNilIsEmpty() {
        let model = DocumentModel()
        let crumbs = model.pathBreadcrumb(for: URL(fileURLWithPath: "/tmp/panetb/doc.md"))
        XCTAssertEqual(crumbs.map(\.name), ["/", "tmp", "panetb", "doc.md"])
        XCTAssertEqual(crumbs.last?.isFile, true)
        XCTAssertTrue(model.pathBreadcrumb(for: nil).isEmpty)
    }
}
