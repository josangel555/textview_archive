import XCTest
@testable import ViewerUI

/// Host tests for the status-bar memory formatter (TSK-366). Pure logic, no
/// tier — the chip's RENDER is the VM tail, but the label/tooltip CONTRACT
/// (headline = app footprint, per-tab = an honest byte proxy, never a
/// fabricated 0) is pinned here so a regression fails the host gate.
final class StatusBarMemoryTests: XCTestCase {

    func test_label_isAppFootprintMiB() {
        let bytes: UInt64 = 142 * 1024 * 1024
        let (label, _) = StatusBarMemory.format(appFootprintBytes: bytes, tabContentBytes: nil)
        XCTAssertEqual(label, ByteFormat.mib(bytes),
            "the headline must be the app footprint formatted as MiB")
    }

    func test_nilFootprint_rendersDashNotFabricatedZero() {
        let (label, _) = StatusBarMemory.format(appFootprintBytes: nil, tabContentBytes: 1000)
        XCTAssertEqual(label, "—",
            "a failed task_info must render '—', never a fabricated 0")
    }

    func test_tooltip_includesPerTabProxy_whenBytesGiven() {
        let (_, tip) = StatusBarMemory.format(appFootprintBytes: 1, tabContentBytes: 4096)
        XCTAssertTrue(tip.contains("This tab's loaded content"),
            "tooltip should carry the per-tab content proxy:\n\(tip)")
        XCTAssertTrue(tip.contains(ByteFormat.human(4096)),
            "tooltip should show the human byte size of the tab content:\n\(tip)")
        XCTAssertTrue(tip.contains("not the tab's RSS"),
            "the per-tab figure MUST be labelled a proxy, not RSS (honesty):\n\(tip)")
    }

    func test_tooltip_omitsPerTabProxy_whenNil() {
        let (_, tip) = StatusBarMemory.format(appFootprintBytes: 1, tabContentBytes: nil)
        XCTAssertFalse(tip.contains("This tab's loaded content"),
            "no per-tab line when there are no bytes:\n\(tip)")
    }

    func test_tooltip_omitsPerTabProxy_whenNegative() {
        let (_, tip) = StatusBarMemory.format(appFootprintBytes: 1, tabContentBytes: -5)
        XCTAssertFalse(tip.contains("This tab's loaded content"),
            "a negative byte count is ignored, not formatted:\n\(tip)")
    }

    func test_tooltip_alwaysExplainsWebKitExclusionAndToolWindow() {
        let (_, tip) = StatusBarMemory.format(appFootprintBytes: 1, tabContentBytes: nil)
        XCTAssertTrue(tip.contains("excludes the shared WebKit helper"),
            "the headline's scope (no WebKit helpers) must be stated:\n\(tip)")
        XCTAssertTrue(tip.contains("Memory tool window"),
            "the tooltip should point at the full breakdown:\n\(tip)")
    }
}
