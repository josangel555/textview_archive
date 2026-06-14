import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-900 — after a deferred (off-main, ≥4 MiB) open lands, a tab parked in
/// `.hex` by the hint-less default must upgrade to the content-aware default
/// when the bytes decoded as TEXT; a genuinely binary file stays in HEX.
final class DeferredLoadViewModeUpgradeTests: XCTestCase {

    private let unknownTextURL = URL(fileURLWithPath: "/tmp/mdv-deferred-test.unknownext")

    func test_unknownExtTextFile_upgradesHexToSource() {
        let mode = DocumentModel.deferredLoadViewModeUpgrade(
            current: .hex, isLoadedText: true, url: unknownTextURL, preferred: [:])
        XCTAssertEqual(mode, .source,
            "an unknown-extension file that decoded as text must leave HEX for Source")
    }

    func test_binaryFile_staysHex() {
        // isLoadedText == false models a `.binary` load verdict.
        let mode = DocumentModel.deferredLoadViewModeUpgrade(
            current: .hex, isLoadedText: false, url: unknownTextURL, preferred: [:])
        XCTAssertEqual(mode, .hex, "a genuinely binary file must stay in HEX")
    }

    func test_nonHexTab_isUnchanged() {
        let mode = DocumentModel.deferredLoadViewModeUpgrade(
            current: .source, isLoadedText: true, url: unknownTextURL, preferred: [:])
        XCTAssertEqual(mode, .source, "a tab not in HEX is never touched")
    }

    func test_perCategoryDefaultOverride_isHonored() {
        // If the user pinned unknown/plain text to a mode that's available, the
        // upgrade follows the override (still not HEX).
        let mode = DocumentModel.deferredLoadViewModeUpgrade(
            current: .hex, isLoadedText: true, url: unknownTextURL, preferred: [:])
        XCTAssertNotEqual(mode, .hex, "the upgrade must never leave the tab in HEX for a text file")
    }
}
