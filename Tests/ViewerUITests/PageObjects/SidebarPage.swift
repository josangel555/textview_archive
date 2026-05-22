import XCTest
import Foundation

/// Page Object for the file-tree sidebar (accessibility id
/// `mdv.sidebar`).
///
/// The script runner exposes `sidebar-set-root`, `sidebar-walk-up`,
/// `sidebar-select-next`, `sidebar-select-prev`, `toggle-sidebar`. The
/// per-step dump's `model.sidebar` block (when present) carries
/// `rootURL`, `isVisible`, `selection` — we read those directly.
struct SidebarPage: DumpPage {
    let dump: [String: Any]

    init(dump: [String: Any]) { self.dump = dump }

    /// Subtree rooted at `mdv.sidebar`, or `nil` when the sidebar is
    /// hidden / the identifier didn't propagate.
    var subtree: [String: Any]? { subtree(withIdentifier: "mdv.sidebar") }

    /// Whether the sidebar is currently visible. Combines the model
    /// flag (authoritative when present) and the subtree presence.
    var isVisible: Bool {
        if let s = model["sidebar"] as? [String: Any],
           let v = s["isVisible"] as? Bool {
            return v
        }
        return subtree != nil
    }

    /// Current root URL string (`model.sidebar.rootURL`), if set.
    var rootURLString: String? {
        (model["sidebar"] as? [String: Any])?["rootURL"] as? String
    }

    /// File-tree rows visible under the sidebar subtree. Best-effort:
    /// we surface AppKit `NSOutlineView`-row classes when available
    /// and fall back to the subtree's direct children otherwise.
    var fileTreeRows: [[String: Any]] {
        guard let s = subtree else { return [] }
        var rows: [[String: Any]] = []
        func walk(_ n: [String: Any]) {
            if let cls = n["class"] as? String,
               cls.contains("Row") || cls.contains("Cell") {
                rows.append(n)
            }
            if let kids = n["subviews"] as? [[String: Any]] { kids.forEach(walk) }
        }
        walk(s)
        return rows
    }

    // MARK: - Assertions

    func assertVisible(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(isVisible,
            "Expected sidebar to be visible, was hidden",
            file: file, line: line)
    }

    func assertHidden(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(isVisible,
            "Expected sidebar to be hidden, was visible",
            file: file, line: line)
    }

    func assertRoot(
        endsWith suffix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = rootURLString ?? ""
        XCTAssertTrue(actual.hasSuffix(suffix),
            "Expected sidebar root to end with '\(suffix)', got '\(actual)'",
            file: file, line: line)
    }
}
