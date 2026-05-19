import XCTest
@testable import ViewerUI

/// Unit-level coverage for the right-click → "Open in New Session"
/// callback. The actual menu items (in SidebarView's FileRowContextMenu
/// + BookmarksSection's BookmarkRow) are SwiftUI Buttons whose tap
/// closures invoke `model.openFolderInNewSession?(url)`. Without
/// ViewInspector, we can't introspect the menu directly — but we can
/// pin down the contract the menu items depend on:
///
///   1. The closure exists as a stored property on DocumentModel.
///   2. It starts nil (no UI host) so tests + previews don't see the
///      menu item.
///   3. When set, the menu's `if let` guard activates and invoking the
///      stored closure forwards the URL verbatim.
///
/// The actual rendering — that the menu item is *visible* under the
/// guard — is a VM live-app concern.
@MainActor
final class OpenInNewSessionTests: XCTestCase {

    func test_openFolderInNewSession_defaultsToNil() {
        let model = DocumentModel()
        XCTAssertNil(model.openFolderInNewSession,
            "default must be nil so SwiftUI `if let` hides the menu item")
    }

    func test_openFolderInNewSession_invokesClosureWithURL() {
        let model = DocumentModel()
        let target = URL(fileURLWithPath: "/tmp/proj/sub")
        var received: URL?
        model.openFolderInNewSession = { received = $0 }
        model.openFolderInNewSession?(target)
        XCTAssertEqual(received, target,
            "closure must receive the URL passed by the menu item verbatim")
    }

    func test_openFolderInNewSession_multipleInvocations() {
        // The menu item is repeatable — user can right-click multiple
        // folders in succession. Each invocation must reach the callback
        // independently; no debouncing or coalescing in this path.
        let model = DocumentModel()
        var calls: [URL] = []
        model.openFolderInNewSession = { calls.append($0) }
        let urls = [
            URL(fileURLWithPath: "/a"),
            URL(fileURLWithPath: "/b"),
            URL(fileURLWithPath: "/c"),
        ]
        for u in urls { model.openFolderInNewSession?(u) }
        XCTAssertEqual(calls, urls)
    }

    func test_openFolderInNewSession_clearable() {
        // Setting to nil disables the menu item (UI host detaches).
        // Subsequent invocations through `?(...)` must be no-ops, not
        // crashes.
        let model = DocumentModel()
        var calls = 0
        model.openFolderInNewSession = { _ in calls += 1 }
        model.openFolderInNewSession?(URL(fileURLWithPath: "/a"))
        model.openFolderInNewSession = nil
        model.openFolderInNewSession?(URL(fileURLWithPath: "/b"))
        XCTAssertEqual(calls, 1)
    }
}
