import XCTest
@testable import ViewerCore

/// TSK-903 — GFM task list items render a disabled checkbox (Swift path). The
/// A/B suite pins rust==swift; this pins that the checkbox is actually EMITTED
/// (so a regression that drops it in BOTH engines, still parity-equal, fails).
final class MarkdownTaskListTests: XCTestCase {

    func test_checkedItem_rendersDisabledCheckedCheckbox() {
        let html = HTMLRenderer().render("- [x] done")
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled checked/> done"),
            "checked task item must emit a disabled+checked checkbox before the text; got: \(html)")
    }

    func test_uncheckedItem_rendersDisabledCheckbox_notChecked() {
        let html = HTMLRenderer().render("- [ ] todo")
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled/> todo"), html)
        XCTAssertFalse(html.contains("checked"), "an unchecked item must not be checked")
    }

    func test_plainListItem_hasNoCheckbox() {
        XCTAssertFalse(HTMLRenderer().render("- plain").contains("<input"))
    }
}
