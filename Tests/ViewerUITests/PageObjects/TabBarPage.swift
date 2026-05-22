import XCTest
import Foundation

/// Page Object for the top-level tab bar (accessibility id
/// `mdv.tabbar`).
///
/// Existing live-app tests count tabs via
/// `PlatformGroupContainer` children inside the tabbar subtree; that
/// logic is preserved here. The "active tab" inference uses
/// `dump["window"]["title"]`, since the live app's title is set to
/// the selected file's last path component (see `DocumentModel`).
struct TabBarPage: DumpPage {
    let dump: [String: Any]

    init(dump: [String: Any]) { self.dump = dump }

    /// Subtree rooted at `mdv.tabbar`, or `nil` if the identifier
    /// hasn't propagated (a known SwiftUI/AppKit bridge gap on some
    /// builds — callers should treat this as a "no info" signal, not a
    /// hard failure).
    var subtree: [String: Any]? { subtree(withIdentifier: "mdv.tabbar") }

    /// Visible tab cells. May be empty when the a11y identifier didn't
    /// surface on the realised NSView; see `InteractionScriptTests`
    /// for the historical context.
    var tabCells: [[String: Any]] {
        guard let bar = subtree else { return [] }
        var out: [[String: Any]] = []
        func walk(_ n: [String: Any]) {
            if (n["class"] as? String) == "PlatformGroupContainer" { out.append(n) }
            if let kids = n["subviews"] as? [[String: Any]] { kids.forEach(walk) }
        }
        walk(bar)
        return out
    }

    /// Number of visible tabs. Returns `nil` (not `0`) when the
    /// tabbar subtree is missing, so callers can distinguish "0 tabs"
    /// from "tabbar identifier didn't propagate this run".
    var tabCount: Int? {
        guard subtree != nil else { return nil }
        return tabCells.count
    }

    /// Best-effort title of the active tab, derived from the window
    /// title. Returns `nil` when the title is empty.
    var activeTabTitle: String? {
        guard let t = windowTitle, !t.isEmpty else { return nil }
        return t
    }

    // MARK: - Assertions

    /// Assert the window title reflects a tab whose filename matches.
    /// Uses `contains` because the title format is
    /// `"<filename> — TextView"` on some builds.
    func assertActiveTab(
        named expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = activeTabTitle ?? ""
        XCTAssertTrue(
            actual.contains(expected),
            "Expected active tab to be '\(expected)', window title was '\(actual)'",
            file: file, line: line)
    }

    /// Assert the active tab is NOT named `forbidden` — useful after
    /// closing a specific tab.
    func assertActiveTabNotNamed(
        _ forbidden: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = activeTabTitle ?? ""
        XCTAssertFalse(
            actual.contains(forbidden),
            "Active tab should no longer reference '\(forbidden)', got '\(actual)'",
            file: file, line: line)
    }
}
