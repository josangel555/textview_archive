import XCTest
@testable import ViewerUI

/// TSK-1302 — the side file-property pane (MetadataPanel) is suppressed while the in-place image
/// editor is active, so the full-width editor isn't crowded/covered by it. It still shows otherwise
/// when the "Info" toggle is on. Pure host test of the gate predicate (no view instantiation).
final class ContentViewMetadataGateTests: XCTestCase {

    func test_metadataPanel_suppressedWhileEditingImage_TSK1302() {
        XCTAssertTrue(
            ContentView.showsPreviewMetadataPanel(showPreview: true, isEditingImage: false),
            "Info on + not editing → the file-property pane shows")
        XCTAssertFalse(
            ContentView.showsPreviewMetadataPanel(showPreview: true, isEditingImage: true),
            "Info on + editing an image → suppressed (don't crowd the editor)")
        XCTAssertFalse(
            ContentView.showsPreviewMetadataPanel(showPreview: false, isEditingImage: false),
            "Info off → hidden")
        XCTAssertFalse(
            ContentView.showsPreviewMetadataPanel(showPreview: false, isEditingImage: true),
            "Info off + editing → hidden")
    }
}
