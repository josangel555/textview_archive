import XCTest
import ViewerKit
@testable import ViewerCore

/// A plain new (`.project`) session opens with ONLY the Files tool window;
/// every other panel starts closed (owner request 2026-06-20). Pinned at the
/// pure-logic layer: `PanelLayoutSnapshot.filesOnly` + `.project`'s default.
/// The on-screen result (rails actually closed) is render/VM.
final class SessionFilesOnlyDefaultTests: XCTestCase {

    func test_filesOnly_showsOnlyFiles_hidesEveryOtherPanel() {
        let ov = PanelVisibilityOverrides.decoded(PanelLayoutSnapshot.filesOnly.overrides)
        for k in SidebarPanelRegistry.defaultOrder {
            if k == .files {
                XCTAssertEqual(ov.state(k), .shown, "Files must be shown")
            } else {
                XCTAssertEqual(ov.state(k), .hidden,
                               "\(k) must be forced hidden in a fresh session")
            }
        }
    }

    /// A plain `.project` session's default layout IS files-only — so a new
    /// session opens clean. (Reverting `.project` to empty overrides — the old
    /// data-presence heuristic that auto-opened git/etc. — reddens this.)
    func test_projectDefaultLayout_isFilesOnly() {
        XCTAssertEqual(SessionKind.project.defaultPanelLayout,
                       PanelLayoutSnapshot.filesOnly)
        XCTAssertFalse(SessionKind.project.defaultPanelLayout.overrides.isEmpty,
                       "project default must carry explicit hide overrides, not the auto heuristic")
    }
}
