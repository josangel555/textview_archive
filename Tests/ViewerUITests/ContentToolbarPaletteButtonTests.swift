import XCTest
@testable import ViewerUI

/// TSK-756: the content-toolbar's far-right command-palette button is wired to
/// `model.showPalette()`. The button's on-screen presence + click is the VM
/// tier (SwiftUI render), but this pins the exact MODEL action it triggers —
/// open flips `isPalettePresented` true, dismiss flips it false — so a
/// regression of the palette-open path fails on the host gate even though the
/// pixel/click validation is VM-only.
@MainActor
final class ContentToolbarPaletteButtonTests: XCTestCase {

    func test_showPalette_opensAndDismisses() {
        let model = DocumentModel()
        XCTAssertFalse(model.isPalettePresented, "palette starts closed")
        model.showPalette()
        XCTAssertTrue(model.isPalettePresented,
                      "showPalette (the toolbar button's action) must open the palette")
        model.dismissPalette()
        XCTAssertFalse(model.isPalettePresented, "dismissPalette must close it again")
    }
}
