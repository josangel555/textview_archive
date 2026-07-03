import XCTest
import AppKit
@testable import ViewerUI

/// TSK-1435 — hosted-view empty states. The catalog is the host-testable
/// contract: every hosted surface has a COMPLETE spec (id/icon/title/message),
/// so a surface can't silently regress to a blank or meaningless pane. The
/// rendered appearance is the VM/pixel tail (validation protocol rung 3).
final class HostedEmptyStateTests: XCTestCase {

    /// The surfaces the usability sweep (inventory theme #2) requires.
    /// Wiring sites: FeedReaderView (sidebar + item pane), HTTPClientView
    /// (response pane), SQLiteBrowserView (results area), FolderTreemapView
    /// (empty folder), ScriptConsoleView (output pane), TaskRunnerView
    /// (task list + output pane).
    private let requiredSurfaces = [
        "feedReader", "feedReader.items", "httpClient", "sqliteBrowser",
        "folderTreemap", "scriptConsole", "taskRunner", "taskRunner.output",
        // TSK-1461 — snippet manager (empty store / no search matches).
        "snippetManager", "snippetManager.noMatches",
    ]

    func test_catalog_coversEveryRequiredSurface() {
        let ids = EmptyStateCatalog.all.map(\.id)
        for surface in requiredSurfaces {
            XCTAssertTrue(ids.contains(surface),
                "catalog must carry a spec for '\(surface)' — a hosted view without one opens blank")
        }
    }

    func test_catalog_specsAreComplete() {
        for spec in EmptyStateCatalog.all {
            XCTAssertFalse(spec.id.isEmpty, "spec id must be non-empty")
            XCTAssertFalse(spec.icon.isEmpty, "\(spec.id): icon must be non-empty")
            XCTAssertFalse(spec.title.isEmpty, "\(spec.id): title (the what-is-this line) must be non-empty")
            XCTAssertFalse(spec.message.isEmpty, "\(spec.id): message (the next-step guidance) must be non-empty")
            if let label = spec.actionLabel {
                XCTAssertFalse(label.isEmpty, "\(spec.id): an action button must have a label")
            }
        }
    }

    func test_catalog_messagesAreGuidance_notBareStatements() {
        // A purposeful empty state tells the user what to DO, not just what
        // is missing ("No feeds"). Proxy contract: guidance is a sentence,
        // not a fragment — meaningfully longer than the old bare labels.
        for spec in EmptyStateCatalog.all {
            XCTAssertGreaterThan(spec.message.count, 40,
                "\(spec.id): message should be next-step guidance, not a bare '\(spec.message)'")
        }
    }

    func test_catalog_idsAreUnique() {
        let ids = EmptyStateCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate empty-state surface ids")
    }

    func test_accessibilityID_isNamespaced() {
        for spec in EmptyStateCatalog.all {
            XCTAssertEqual(spec.accessibilityID, "mdv.emptyState.\(spec.id)")
        }
    }

    func test_glyphs_resolveAsSFSymbols() {
        // A typo'd SF Symbol renders as a blank gap — pin that every catalog
        // icon actually resolves on this OS.
        for spec in EmptyStateCatalog.all {
            XCTAssertNotNil(
                NSImage(systemSymbolName: spec.icon, accessibilityDescription: nil),
                "\(spec.id): '\(spec.icon)' is not a resolvable SF Symbol")
        }
    }
}
