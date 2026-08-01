import XCTest
@testable import ViewerUI

/// I-05 (owner intake 2026-08-01) — the git-status open-mode toggle: a row
/// click opens the file's DIFF (default) or SOURCE, both into the ephemeral
/// preview slot. The routing rule is pure; this file pins the matrix plus the
/// view wiring (source-level) so a silent regression back to permanent
/// `openPath` row-clicks fails on the host gate.
final class GitStatusOpenModeTests: XCTestCase {

    // MARK: - Routing matrix

    func test_diffMode_trackedFile_showsDiff() {
        XCTAssertEqual(
            GitStatusOpenMode.clickAction(mode: .diff, isUntracked: false),
            .showDiff)
    }

    func test_diffMode_untrackedFile_fallsBackToSourcePreview() {
        // An untracked file has no diff — a placeholder "(no diff output)"
        // document would be noise; show the file itself.
        XCTAssertEqual(
            GitStatusOpenMode.clickAction(mode: .diff, isUntracked: true),
            .previewSource)
    }

    func test_sourceMode_opensSourcePreview_regardlessOfTracking() {
        XCTAssertEqual(
            GitStatusOpenMode.clickAction(mode: .source, isUntracked: false),
            .previewSource)
        XCTAssertEqual(
            GitStatusOpenMode.clickAction(mode: .source, isUntracked: true),
            .previewSource)
    }

    func test_persistenceKey_andDefault_areStable() {
        // The key is persisted user state — renaming it silently resets the
        // user's choice. Diff is the documented default (it also covers
        // deleted files, whose source no longer exists).
        XCTAssertEqual(GitStatusOpenMode.defaultsKey,
                       "MarkdownViewer.gitPanel.statusOpenMode")
        XCTAssertEqual(GitStatusOpenMode(rawValue: "diff"), .diff)
        XCTAssertEqual(GitStatusOpenMode(rawValue: "source"), .source)
    }

    // MARK: - View wiring pin (source-level)

    /// The row click must route through the pure rule and land in the
    /// EPHEMERAL preview slot — not the permanent `openPath`. A behavioral
    /// drive of the private row closure isn't host-reachable (SwiftUI view),
    /// so this pins the wiring at the source level; the render tail is the
    /// VM scene capture.
    func test_gitStatusTab_rowClick_isWiredThroughClickAction_andPreview() throws {
        let source = try String(contentsOf: statusTabURL, encoding: .utf8)
        XCTAssertTrue(source.contains("GitStatusOpenMode.clickAction(mode:"),
            "row clicks must route through the pure open-mode rule")
        XCTAssertTrue(source.contains("doc.openPreview(url: url)"),
            "source mode must open the EPHEMERAL preview slot, not a permanent tab")
        XCTAssertTrue(source.contains("mdv.git.openModeToggle"),
            "the Diff|Source toggle must exist (AX id) in the status tab header")
    }

    private var statusTabURL: URL {
        URL(fileURLWithPath: #filePath)                // .../Tests/ViewerUITests/Git/GitStatusOpenModeTests.swift
            .deletingLastPathComponent()               // Git/
            .deletingLastPathComponent()               // ViewerUITests/
            .deletingLastPathComponent()               // Tests/
            .deletingLastPathComponent()               // repo root
            .appendingPathComponent("Sources/ViewerUI/Git/GitStatusTab.swift")
    }
}
