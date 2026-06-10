import XCTest
import ViewerCore

/// TSK-274 — the tab drag-and-drop wire format. Two consumers (tab-strip
/// reorder + session-pill move) decode this; a silent format drift would
/// break drops with no error anywhere.
final class TabDragPayloadTests: XCTestCase {

    func test_roundTrip() {
        let id = UUID()
        XCTAssertEqual(TabDragPayload.tabID(from: TabDragPayload.encode(id)), id)
    }

    func test_rejectsForeignAndMalformedPayloads() {
        XCTAssertNil(TabDragPayload.tabID(from: "just some dropped text"))
        XCTAssertNil(TabDragPayload.tabID(from: "mdv-tab:not-a-uuid"))
        XCTAssertNil(TabDragPayload.tabID(from: ""))
        // Prefix must anchor at the start.
        XCTAssertNil(TabDragPayload.tabID(from: "x mdv-tab:\(UUID().uuidString)"))
    }
}
