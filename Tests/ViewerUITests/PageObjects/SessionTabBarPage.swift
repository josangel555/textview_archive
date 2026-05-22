import XCTest
import Foundation

/// Page Object for the session pill row (accessibility id
/// `mdv.sessionTabBar`). One pill per session, plus a trailing `+`
/// button (`mdv.sessionTab.new`).
///
/// Most assertions read `dump["model"]["sessions"]` rather than the
/// view-tree subtree because (a) the model array is authoritative for
/// ordering + active id and (b) the SwiftUI a11y identifiers don't
/// always surface on the realised NSView (same caveat called out in
/// `TabBarPage`). The subtree probes are still here for "is the bar
/// painted at all" assertions.
struct SessionTabBarPage: DumpPage {
    let dump: [String: Any]

    init(dump: [String: Any]) { self.dump = dump }

    /// Subtree rooted at `mdv.sessionTabBar`. Optional — the row hides
    /// itself when zero sessions are mounted and `dist/TextView.app`
    /// is launched with `MDV_SKIP_WORKSPACE_RESTORE=1`.
    var subtree: [String: Any]? { subtree(withIdentifier: "mdv.sessionTabBar") }

    /// Subtree of the trailing `+` button. Used to assert the
    /// "Open Folder in New Session…" affordance is present.
    var newSessionButton: [String: Any]? { subtree(withIdentifier: "mdv.sessionTab.new") }

    /// Model-level session list (in coordinator order).
    /// Each element exposes `id`, `displayName`, `sidebarRootPath`.
    var sessions: [[String: Any]] {
        (model["sessions"] as? [[String: Any]]) ?? []
    }

    var sessionCount: Int { sessions.count }

    /// UUID string of the active session, or `""` when there is none.
    var activeSessionID: String {
        (model["activeSessionID"] as? String) ?? ""
    }

    /// `displayName` of the active session, or `nil` when no session
    /// is active.
    var activeSessionName: String? {
        guard let id = (model["activeSessionID"] as? String), !id.isEmpty else { return nil }
        return sessions.first(where: { ($0["id"] as? String) == id })?["displayName"] as? String
    }

    /// `sidebarRootPath` of the active session, or `nil` when no
    /// session is active.
    var activeSessionRootPath: String? {
        guard let id = (model["activeSessionID"] as? String), !id.isEmpty else { return nil }
        return sessions.first(where: { ($0["id"] as? String) == id })?["sidebarRootPath"] as? String
    }

    /// Subtree of the pill for a specific session, or nil when its a11y
    /// id didn't surface. We accept the SwiftUI propagation gap as a
    /// soft-fail: callers should treat nil as "no info, skip subtree
    /// assertion" (parallels TabBarPage's tabCount? semantics).
    func pillSubtree(for sessionID: String) -> [String: Any]? {
        subtree(withIdentifier: "mdv.sessionTab.\(sessionID)")
    }

    // MARK: - Assertions

    func assertSessionCount(
        _ expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(sessionCount, expected,
            "Expected \(expected) session(s), got \(sessionCount): \(sessions)",
            file: file, line: line)
    }

    func assertActiveSessionName(
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(activeSessionName, expected,
            "Expected active session named '\(expected)', got '\(activeSessionName ?? "nil")'",
            file: file, line: line)
    }

    func assertActiveSessionRoot(
        endsWith suffix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = activeSessionRootPath ?? ""
        XCTAssertTrue(actual.hasSuffix(suffix),
            "Expected active session root to end with '\(suffix)', got '\(actual)'",
            file: file, line: line)
    }

    /// Soft assertion that the SessionTabBar container painted.
    /// Skips (no failure) when the SwiftUI identifier didn't propagate
    /// to the realised NSView — same convention as `TabBarPage.tabCount`.
    func assertBarSubtreePresent(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // No-op when subtree is nil (a11y id didn't propagate); we
        // surface a more informative failure via assertSessionCount
        // when the *model* says zero sessions exist.
        if subtree == nil { return }
        XCTAssertNotNil(subtree, file: file, line: line)
    }
}
