import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1314 — the FILES tree must respect its per-panel `.files` override (the
/// shoulder toggle), not just folder-presence. Pins the model contract that the
/// SidebarView `filesPanelVisible` gate now consumes: an explicit `.hidden` override
/// makes `.files` not-visible even with a folder open (the bug was the tree staying
/// visible when only Bookmark was enabled — `filesPanel` keyed on `rootURL` and
/// bypassed `isVisible`). The on-screen tree-hide is the VM tail.
@MainActor
final class SidebarFilesVisibilityTests: XCTestCase {

    private func store() -> PanelLayoutStore {
        PanelLayoutStore(defaults: UserDefaults(suiteName: "FilesVis-\(UUID().uuidString)")!)
    }

    func test_filesOverride_gatesVisibility_independentOfFolderPresence() {
        let s = store()
        // Default `.auto` defers to data-presence (a folder being open).
        XCTAssertTrue(s.isVisible(.files, dataPresent: true), ".auto + folder ⇒ visible (default, unchanged)")

        // The shoulder toggle → `.hidden` must hide FILES even with a folder open.
        s.setOverride(.files, .hidden)
        XCTAssertFalse(s.isVisible(.files, dataPresent: true), ".hidden ⇒ not visible even with a folder")

        // `.shown` forces it on even without a folder (placeholder).
        s.setOverride(.files, .shown)
        XCTAssertTrue(s.isVisible(.files, dataPresent: false), ".shown ⇒ visible even without a folder")
    }
}
