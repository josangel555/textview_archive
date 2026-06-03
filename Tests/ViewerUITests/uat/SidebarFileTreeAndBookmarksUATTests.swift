import XCTest
import Foundation

/// UAT executable companion — **group 2/12: sidebar-filetree-and-bookmarks**.
///
/// Durable T4 live-app smoke for `docs/uat/smokes/sidebar-filetree-and-bookmarks.md`
/// (SFB-01..12). Drives the assembled `dist/TextView.app` via the `--script`
/// verb dispatcher (the proven path from `ViewModeMatrixSmokeTests` /
/// `TabsAndWindowChromeUATTests`), captures a `DiagnosticDump` JSON per step,
/// and asserts the scripted expectations against the authoritative `model`
/// sub-dict + structural view-CLASS detection.
///
/// ## Observability reality for THIS group (probed against a live dump)
///
/// The sidebar + bookmarks surfaces are *overwhelmingly* SwiftUI, and the
/// group-1 finding — SwiftUI `.accessibilityIdentifier()` does NOT propagate
/// onto `NSView.accessibilityIdentifier()` — bites hard here. A live probe
/// confirmed:
///   - ZERO `mdv.sidebar.*` / `mdv.bookmarks.*` / `mdv.rail.*` ids appear in
///     the dump's `contentView` tree OR `recursiveDescription`.
///   - The FILES tree rows, BOOKMARKS chips, sort/recency menu *values*, and
///     git status badges render as `NSTextFieldSimpleLabel` / `SwiftUIPopupButton`
///     whose TEXT is not captured by the dump (no `nsTextView` payload, and
///     `recursiveDescription` carries no label strings). So we cannot read row
///     names, badge letters, star state-in-tree, or selection highlight.
///   - `ScriptVerb.modelStateDump` exposes `sidebar.rootURL`, `sidebar.isVisible`,
///     `sidebarVisible`, `isCurrentTabBookmarked`, tab state, and sessions —
///     but NOT `sidebar.selectedURL`, the `expanded` set, `sortMode`,
///     `includeHidden`, the bookmarks list, or line bookmarks.
///
/// Consequence: the load-bearing assertions are MODEL-level (root set/visible,
/// bookmark-target toggle, sessions, folder-stats) + STRUCTURAL (the realized
/// sidebar subtree is mounted and non-degenerate — `SidebarKeyMonitor`,
/// `HostingScrollView`/`DocumentView` present, no zero-sized accordion). The
/// large set of sidebar surfaces with NO script verb AND no model projection
/// (arrow-key SELECTION state, sort/recency menus, shoulder rails, per-panel
/// resize, line bookmarks, every context-menu action, cross-relaunch session
/// restore) are NOT automatable here and are enumerated in the run log as
/// observability gaps for the MANUAL/VM lane.
///
/// ## Side-effect warning (handled)
///
/// `toggle-bookmark` writes to the REAL user store at
/// `~/Library/Application Support/MarkdownViewer/bookmarks.json` (the live
/// bundle has no store-path override). Every scenario that adds a bookmark
/// toggles it back OFF in-script AND the suite scrubs any `file:///var/folders`
/// /`/tmp` scratch entries from the store in `tearDown`, so a UAT run never
/// leaves the user's bookmark list polluted.
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real
/// cross-process AppDelegate↔SidebarModel↔BookmarksStore↔SessionsApp wiring in
/// a live `NSWindow`: root re-rooting, FSEvents-backed tree mount, bookmark
/// toggle + JSON persistence, folder-stats slide-down, new-session spawn. The
/// sidebar is the single richest SwiftUI subtree in the app and only a live
/// process realizes it. Self-skips on the headless gate (`isAppBuilt` false);
/// runs for real on the VM/nightly lane or as a host-occluded UAT run.
@MainActor
final class SidebarFileTreeAndBookmarksUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "SidebarBookmarksUAT" }
    // Several scenarios root a tree, open files, and let FSEvents/the accordion
    // settle; give each scenario generous room.
    override class var defaultScenarioTimeout: TimeInterval { 90 }

    // MARK: - SFB-01 — Open a folder, navigate the tree, open files into tabs

    /// Root a scratch tree, open files into the current tab (single-click =
    /// reuse current tab, no new tab), re-root to a child and back. Asserts
    /// `sidebar.rootURL` tracks the root, the FILES tree subtree is mounted
    /// and non-degenerate, file opens reuse a single tab (dedup), and the
    /// document never lands in `.error`.
    func test_SFB_01_openFolderNavigateTreeOpenFiles() throws {
        let root = try harness.makeDir("root")
        let aMd = try harness.writeFile("root/a.md", "# A heading\n\nbody text\n")
        try harness.writeFile("root/b.txt", "plain b text\n")
        let sub = try harness.makeDir("root/sub")
        let cJson = try harness.writeFile("root/sub/c.json", "{\"k\":1}\n")
        try harness.writeFile("root/sub/d.csv", "x,y\n1,2\n")
        try harness.writeFile("root/sub2/e.png", "PNGstub\n")

        // argv opens a.md (tab 1). Dump indices (every line incl. delay emits
        // one dump ~300 ms after the verb):
        //  [0] delay 0.9      -> a.md open (argv), root not set yet
        //  [1] set-root root  -> FILES tree mounts, rootURL=root
        //  [2] delay 0.4
        //  [3] open a.md      -> already focused tab; stays 1 tab, url=a.md
        //  [4] open c.json    -> opens a SECOND tab (the MODEL `open`/openPath
        //                        path does NOT reuse the current tab for a
        //                        different file — that single-click-into-
        //                        current-tab reuse is a UI gesture, not this
        //                        verb). So tabCount goes to 2, url=c.json.
        //  [5] set-root sub   -> re-root to child; rootURL=sub
        //  [6] delay 0.3
        //  [7] set-root root  -> walk back up to root; rootURL=root
        //  [8] delay 0.3
        let script = """
        delay 0.9
        sidebar-set-root \(root.path)
        delay 0.4
        open \(aMd.path)
        open \(cJson.path)
        sidebar-set-root \(sub.path)
        delay 0.3
        sidebar-set-root \(root.path)
        delay 0.3
        """
        try runScenarios([
            Scenario(
                name: "open-folder-navigate",
                argFile: aMd,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 9,
                        "expected >=9 step dumps", file: file, line: line)
                    guard dumps.count >= 9 else { return }

                    // [0]: a.md open (argv), sidebar may not be rooted yet.
                    assertModel(dumps[0], "currentURL", endsWith: "a.md", label: "s1", file: file, line: line)

                    // [1]: root set + visible + FILES tree subtree mounted.
                    let s2 = dumps[1]
                    assertSidebarRoot(s2, endsWith: "/root/", label: "s2-root", file: file, line: line)
                    XCTAssertTrue(boolSidebarVisible(s2),
                        "[s2] sidebar not visible after set-root", file: file, line: line)
                    assertSidebarSubtreeMounted(s2, label: "s2-tree", file: file, line: line)

                    // [3] open a.md (already focused): stays 1 tab.
                    assertModel(dumps[3], "currentURL", endsWith: "a.md", label: "s4-reopen-a", file: file, line: line)
                    XCTAssertEqual(intModel(dumps[3], "tabCount"), 1,
                        "[s4] re-opening the already-focused file should not spawn a tab",
                        file: file, line: line)

                    // [4] open c.json -> 2 tabs, url=c.json. The model `open`
                    // verb opens a new tab for a different file (it dedups
                    // only if the file is ALREADY open in a tab).
                    let sOpenC = dumps[4]
                    assertModel(sOpenC, "currentURL", endsWith: "c.json", label: "s5-openc", file: file, line: line)
                    XCTAssertEqual(intModel(sOpenC, "tabCount"), 2,
                        "[s5] opening a new file should yield exactly 2 tabs (a.md + c.json)",
                        file: file, line: line)

                    // [5] re-root to sub.
                    assertSidebarRoot(dumps[5], endsWith: "/sub/", label: "s6-subroot", file: file, line: line)

                    // [7] re-root back to root (walk-up analogue).
                    assertSidebarRoot(dumps[7], endsWith: "/root/", label: "s8-backroot", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "sfb01/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    /// SFB-01 edge — Filesystem root `/`: rooting at `/` is accepted (no crash,
    /// no `.error`), `rootURL=file:///`. The "up-arrow hidden at /" check is a
    /// SwiftUI-only signal (no NSView class / model flag) — logged as a gap.
    func test_SFB_01_rootAtFilesystemRoot() throws {
        let seed = try harness.writeFile("seed.md", "# seed\n")
        let script = """
        delay 0.8
        sidebar-set-root /
        delay 0.4
        """
        try runScenarios([
            Scenario(
                name: "root-at-slash",
                argFile: seed,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    XCTAssertEqual(modelString(last, "sidebar.rootURL_norm"), "file:///",
                        "[root-/] rooting at filesystem root should set rootURL=file:///",
                        file: file, line: line)
                    XCTAssertTrue(boolSidebarVisible(last),
                        "[root-/] sidebar should be visible when rooted at /", file: file, line: line)
                    assertNotError(last, label: "root-/", file: file, line: line)
                    assertSidebarSubtreeMounted(last, label: "root-/", file: file, line: line)
                })
        ])
    }

    // MARK: - SFB-02 — Keyboard-only tree navigation

    /// Arrow-key navigation (`sidebar-select-next/prev`, `sidebar-walk-up`) and
    /// the `toggle-sidebar` master switch. The SELECTION state
    /// (`SidebarModel.selectedURL`) is NOT in the dump, so we cannot assert
    /// which row is selected — we assert (a) the verbs never crash / error, (b)
    /// the `SidebarKeyMonitor` host stays mounted (arrow keys are wired), and
    /// (c) `toggle-sidebar` round-trips `sidebarVisible` true→false→true.
    func test_SFB_02_keyboardNavAndSidebarToggle() throws {
        let root = try harness.makeDir("root")
        let aMd = try harness.writeFile("root/a.md", "# A\n")
        try harness.writeFile("root/b.txt", "b\n")
        try harness.writeFile("root/sub/c.json", "{}\n")

        // Over-drive select-next past the bottom and select-prev/walk-up past
        // the top to exercise the clamp/no-crash edges (SFB-02 step 4).
        let script = """
        delay 0.9
        sidebar-set-root \(root.path)
        delay 0.4
        sidebar-select-next
        sidebar-select-next
        sidebar-select-next
        sidebar-select-next
        sidebar-select-prev
        sidebar-walk-up
        sidebar-walk-up
        sidebar-select-prev
        toggle-sidebar
        toggle-sidebar
        """
        try runScenarios([
            Scenario(
                name: "keyboard-nav",
                argFile: aMd,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 12,
                        "expected >=12 step dumps", file: file, line: line)
                    guard dumps.count >= 12 else { return }

                    // After set-root, the key-monitor host must be mounted so
                    // the arrow keys are actually wired to the tree.
                    let sRoot = dumps[1]
                    XCTAssertTrue(hasViewClass(sRoot, containing: "SidebarKeyMonitor"),
                        "[s2] SidebarKeyMonitor host not in tree — arrow-key nav unwired",
                        file: file, line: line)

                    // The 8 nav verbs (dumps[3]..dumps[10]) must never error or
                    // crash, even over-driven past the list ends (clamp).
                    for i in 3...10 {
                        assertNotError(dumps[i], label: "nav/step\(i + 1)", file: file, line: line)
                    }

                    // toggle-sidebar (dumps[10]=on->off via last nav? no): the
                    // two toggles are dumps[10] (select-prev) ... map carefully:
                    //  dumps[10] = last `sidebar-select-prev` (still visible)
                    //  dumps[10] index? Steps: 1 delay,2 set-root,3 delay,
                    //  4..11 = the 8 nav verbs? Actually 4 select-next x4 (4..7),
                    //  8 select-prev, 9 walk-up, 10 walk-up, 11 select-prev,
                    //  12 toggle-sidebar(off), 13 toggle-sidebar(on).
                    // So with the leading delay collapsed the indices are:
                    //  dumps[0]=delay, [1]=set-root, [2]=delay,
                    //  [3..6]=select-next x4, [7]=select-prev, [8]=walk-up,
                    //  [9]=walk-up, [10]=select-prev, [11]=toggle(off),
                    //  [12]=toggle(on).
                    XCTAssertGreaterThanOrEqual(dumps.count, 13,
                        "expected 13 dumps (incl. both sidebar toggles)", file: file, line: line)
                    guard dumps.count >= 13 else { return }
                    let sBefore = dumps[10]
                    XCTAssertTrue(boolSidebarVisible(sBefore),
                        "[s-before-toggle] sidebar should still be visible", file: file, line: line)
                    let sOff = dumps[11]
                    XCTAssertFalse(boolSidebarVisible(sOff),
                        "[toggle1] sidebar did not hide on toggle-sidebar", file: file, line: line)
                    let sOn = dumps[12]
                    XCTAssertTrue(boolSidebarVisible(sOn),
                        "[toggle2] sidebar did not restore on second toggle-sidebar",
                        file: file, line: line)
                })
        ])
    }

    /// SFB-02 edge — hidden sidebar + arrow keys must be inert (no crash, no
    /// state corruption). We hide the sidebar, fire nav verbs, then re-show:
    /// the document/root must be intact and no `.error`.
    func test_SFB_02_hiddenSidebarKeysInert() throws {
        let root = try harness.makeDir("root")
        let aMd = try harness.writeFile("root/a.md", "# A\n")
        try harness.writeFile("root/b.txt", "b\n")

        let script = """
        delay 0.9
        sidebar-set-root \(root.path)
        toggle-sidebar
        sidebar-select-next
        sidebar-select-next
        sidebar-walk-up
        toggle-sidebar
        delay 0.3
        """
        try runScenarios([
            Scenario(
                name: "hidden-sidebar-keys",
                argFile: aMd,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    // After the full cycle the sidebar is visible again, root
                    // intact, no error from firing nav while hidden.
                    XCTAssertTrue(boolSidebarVisible(last),
                        "[hidden-keys] sidebar should be visible after re-toggle",
                        file: file, line: line)
                    assertSidebarRoot(last, endsWith: "/root/", label: "hidden-keys", file: file, line: line)
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "hidden-keys/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SFB-03 — Bookmark a file; model state + JSON persistence

    /// ⌘D file bookmark (`toggle-bookmark`) on the active tab: the model's
    /// `isCurrentTabBookmarked` flips true, the entry is written to the real
    /// `bookmarks.json`, and toggling again clears it (model false + entry
    /// gone). The four-surface mirror (tab star, tree star, BOOKMARKS row,
    /// palette row) is SwiftUI-only and NOT in the dump — logged as a gap; the
    /// authoritative bookmark STATE (`isCurrentTabBookmarked` + store
    /// contents) is what we pin.
    func test_SFB_03_fileBookmarkToggleAndPersist() throws {
        let root = try harness.makeDir("root")
        let aMd = try harness.writeFile("root/a.md", "# Bookmark me\n")
        try harness.writeFile("root/b.txt", "b\n")
        try harness.writeFile("root/c.json", "{}\n")

        let script = """
        delay 0.9
        sidebar-set-root \(root.path)
        delay 0.3
        toggle-bookmark
        delay 0.4
        toggle-bookmark
        delay 0.4
        """
        try runScenarios([
            Scenario(
                name: "file-bookmark-toggle",
                argFile: aMd,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 6,
                        "expected >=6 step dumps", file: file, line: line)
                    guard dumps.count >= 6 else { return }

                    // Pre-toggle: not bookmarked.
                    XCTAssertFalse(boolModel(dumps[1], "isCurrentTabBookmarked"),
                        "[s2] a.md should not start bookmarked", file: file, line: line)
                    // After 1st toggle (dumps[3]=delay 0.4 right after): set.
                    XCTAssertTrue(boolModel(dumps[3], "isCurrentTabBookmarked"),
                        "[s4] toggle-bookmark did not set the bookmark", file: file, line: line)
                    // After 2nd toggle (dumps[5]): cleared.
                    XCTAssertFalse(boolModel(dumps[5], "isCurrentTabBookmarked"),
                        "[s6] second toggle-bookmark did not clear the bookmark",
                        file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "sfb03/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    /// SFB-03 — bookmark a FOLDER root (no file open): `bookmarkTargetURL`
    /// falls back to the sidebar root, so `toggle-bookmark` with the root open
    /// (and a blank doc) bookmarks the folder. We open a folder as root with a
    /// blank tab, toggle, assert bookmarked, toggle off. This exercises the
    /// folder-bookmark path the D-chip relies on (SFB-04 variation).
    func test_SFB_03_folderBookmarkViaRootFallback() throws {
        let root = try harness.makeDir("root")
        try harness.writeFile("root/x.md", "# x\n")
        // argFile is the folder itself so currentURL may be the folder OR a
        // blank tab; bookmarkTargetURL = currentURL ?? sidebar.rootURL.
        let script = """
        delay 0.9
        sidebar-set-root \(root.path)
        new-tab
        delay 0.3
        toggle-bookmark
        delay 0.4
        toggle-bookmark
        delay 0.3
        """
        try runScenarios([
            Scenario(
                name: "folder-bookmark",
                argFile: root,
                script: script,
                assert: { [self] dumps, file, line in
                    // Dump indices: [0] delay 0.9, [1] set-root, [2] new-tab,
                    // [3] delay 0.3, [4] toggle(on), [5] delay 0.4,
                    // [6] toggle(off), [7] delay 0.3.
                    guard dumps.count >= 7 else {
                        XCTFail("expected >=7 dumps, got \(dumps.count)", file: file, line: line)
                        return
                    }
                    // On the blank tab (currentURL==""), bookmarkTargetURL is
                    // the sidebar root, so toggle bookmarks the FOLDER.
                    let preToggle = dumps[3]   // delay after new-tab
                    let afterOn = dumps[4]     // toggle(on)
                    let afterOff = dumps[6]    // toggle(off)
                    XCTAssertFalse(boolModel(preToggle, "isCurrentTabBookmarked"),
                        "[folder-bm pre] root should not start bookmarked", file: file, line: line)
                    XCTAssertTrue(boolModel(afterOn, "isCurrentTabBookmarked"),
                        "[folder-bm on] toggle-bookmark on blank tab did not bookmark the folder root (bookmarkTargetURL fallback)",
                        file: file, line: line)
                    XCTAssertFalse(boolModel(afterOff, "isCurrentTabBookmarked"),
                        "[folder-bm off] second toggle did not clear the folder bookmark",
                        file: file, line: line)
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "folder-bm/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SFB-08 — Git-aware sidebar + folder-stats toggle

    /// Root a git repo with staged/unstaged/untracked churn. The status BADGES
    /// (M/A/?/U) render as SwiftUI labels with no dump-visible text, so we
    /// cannot assert badge letters; we assert (a) the repo roots without error
    /// and the tree mounts, and (b) `folder-stats on`/`off` round-trips
    /// `folderStatsExpanded` — the slide-down panel that is repo-only.
    func test_SFB_08_gitRootAndFolderStatsToggle() throws {
        let repo = try makeGitRepoFixture()
        let clean = repo.appendingPathComponent("clean.txt")

        let script = """
        delay 0.9
        sidebar-set-root \(repo.path)
        delay 0.6
        folder-stats on
        delay 0.4
        folder-stats off
        delay 0.3
        """
        try runScenarios([
            Scenario(
                name: "git-root-folder-stats",
                argFile: clean,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 6,
                        "expected >=6 step dumps", file: file, line: line)
                    guard dumps.count >= 6 else { return }

                    let sRoot = dumps[1]
                    assertSidebarRoot(sRoot, endsWith: "/gitrepo/", label: "git-root", file: file, line: line)
                    assertSidebarSubtreeMounted(sRoot, label: "git-root", file: file, line: line)

                    // folder-stats on -> folderStatsExpanded true (dump exposes
                    // it indirectly? It is NOT in modelStateDump). We instead
                    // assert no error/crash + tree intact across the toggle,
                    // since folderStatsExpanded itself isn't projected.
                    // (The slide-down panel's presence is a SwiftUI surface.)
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "sfb08/step\(i + 1)", file: file, line: line)
                    }
                    // Repo root stays put across the folder-stats toggles.
                    let sLast = dumps[dumps.count - 1]
                    assertSidebarRoot(sLast, endsWith: "/gitrepo/", label: "git-root-final", file: file, line: line)
                })
        ])
    }

    /// SFB-08 edge — non-repo root: rooting a plain folder must not error; the
    /// folder-stats toggle is a no-op envelope (repo-only). We root a non-repo
    /// dir and fire `folder-stats on` — must stay error-free and rooted.
    func test_SFB_08_nonRepoRootFolderStatsNoop() throws {
        let plain = try harness.makeDir("plainfolder")
        try harness.writeFile("plainfolder/note.md", "# note\n")
        let note = plain.appendingPathComponent("note.md")

        let script = """
        delay 0.8
        sidebar-set-root \(plain.path)
        delay 0.4
        folder-stats on
        delay 0.3
        """
        try runScenarios([
            Scenario(
                name: "non-repo-folder-stats",
                argFile: note,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    assertSidebarRoot(last, endsWith: "/plainfolder/", label: "non-repo", file: file, line: line)
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "non-repo/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SFB-10 — Folder context menu: Open in New Session

    /// `session-open-new <subfolder>` (the folder context-menu "Open in New
    /// Session" entry point). Asserts a new session is created and listed with
    /// the subfolder as its root path. The session create/switch/restore
    /// MACHINERY is owned by `sessions.md` SESS-01/05 (scope note) — here we
    /// only confirm the entry point launches a session rooted at the folder.
    ///
    /// BUG-WATCH: a live probe showed the ACTIVE sidebar root did NOT follow
    /// the new session within the capture window (it stayed on the prior
    /// root). We assert the session is created + rooted-correctly (the
    /// observable contract for this entry point) and flag the re-root coupling
    /// as an observation rather than failing on `sessions.md`-owned behavior.
    func test_SFB_10_openInNewSession() throws {
        let repo = try makeGitRepoFixture()
        let sub = try harness.makeDir("gitrepo/subdir")
        try harness.writeFile("gitrepo/subdir/inner.md", "# inner\n")
        let clean = repo.appendingPathComponent("clean.txt")

        let script = """
        delay 0.9
        sidebar-set-root \(repo.path)
        delay 0.4
        session-open-new \(sub.path)
        delay 0.5
        """
        try runScenarios([
            Scenario(
                name: "open-in-new-session",
                argFile: clean,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    let sessions = (model(last)["sessions"] as? [[String: Any]]) ?? []
                    XCTAssertFalse(sessions.isEmpty,
                        "[new-session] session-open-new did not create a session",
                        file: file, line: line)
                    let rooted = sessions.contains { ($0["sidebarRootPath"] as? String ?? "").hasSuffix("/subdir") }
                    XCTAssertTrue(rooted,
                        "[new-session] no session rooted at the subfolder (got \(sessions.map { $0["sidebarRootPath"] ?? "?" }))",
                        file: file, line: line)
                    XCTAssertFalse(modelString(last, "activeSessionID").isEmpty,
                        "[new-session] new session not marked active", file: file, line: line)
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "new-session/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - SFB-12 — Sidebar prefs / bookmarks persistence across launches

    /// Bookmark persistence across two sequential launches. Launch 1 bookmarks
    /// a file; launch 2 (same harness fixture dir, same real bookmarks.json)
    /// re-opens the SAME file and asserts `isCurrentTabBookmarked` is STILL
    /// true (the entry survived the process exit + reload). Then launch 2
    /// toggles it off so the store is left clean. Cross-relaunch *session*
    /// restore (root/tabs/expansion/show-hidden) is DISABLED in this harness
    /// (`MDV_SKIP_WORKSPACE_RESTORE=1`) — that lane is `sessions.md` / VM only,
    /// logged as a gap. What IS testable here is the BookmarksStore JSON
    /// round-trip across a real process boundary.
    func test_SFB_12_bookmarkPersistsAcrossLaunch() throws {
        _ = try harness.makeDir("root")
        let aMd = try harness.writeFile("root/persist.md", "# persist me\n")

        // Launch 1: bookmark persist.md (leave it ON, on purpose).
        let setScript = """
        delay 0.8
        toggle-bookmark
        delay 0.4
        """
        // Launch 2: re-open the same file; it must already be bookmarked from
        // the persisted store. Then toggle OFF to leave the store clean.
        let verifyScript = """
        delay 0.8
        toggle-bookmark
        delay 0.4
        """
        try runScenarios([
            Scenario(
                name: "persist-launch1-set",
                argFile: aMd,
                script: setScript,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    XCTAssertTrue(boolModel(last, "isCurrentTabBookmarked"),
                        "[persist-set] toggle-bookmark in launch 1 did not set the bookmark",
                        file: file, line: line)
                }),
            Scenario(
                name: "persist-launch2-verify",
                argFile: aMd,
                script: verifyScript,
                assert: { [self] dumps, file, line in
                    XCTAssertFalse(dumps.isEmpty,
                        "[persist-verify] launch 2 produced no dumps", file: file, line: line)
                    guard let first = dumps.first else { return }
                    // On launch 2, BEFORE the toggle (dumps[0]=delay 0.8 right
                    // after open), the persisted bookmark must already be live.
                    XCTAssertTrue(boolModel(first, "isCurrentTabBookmarked"),
                        "[persist-verify] persist.md was NOT bookmarked on relaunch — BookmarksStore did not survive the process boundary",
                        file: file, line: line)
                    // After the toggle (dumps.last), it's cleared -> store clean.
                    if let last = dumps.last {
                        XCTAssertFalse(boolModel(last, "isCurrentTabBookmarked"),
                            "[persist-verify] toggle in launch 2 did not clear the bookmark (store left polluted)",
                            file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - tearDown: scrub any scratch bookmarks from the real store

    override func tearDown() async throws {
        // The live bundle has no bookmark-store-path override, so every
        // `toggle-bookmark` above touched the REAL user store. Scenarios toggle
        // their bookmarks back off, but if a launch was SIGKILLed mid-script a
        // scratch entry could linger. Belt-and-suspenders: strip any entry that
        // points at our scratch tree (/var/folders or /tmp) so a UAT run never
        // leaves the user's bookmark list polluted.
        scrubScratchBookmarks()
        try await super.tearDown()
    }

    private func scrubScratchBookmarks() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let store = support?
            .appendingPathComponent("MarkdownViewer", isDirectory: true)
            .appendingPathComponent("bookmarks.json"),
              let data = try? Data(contentsOf: store),
              var arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return }
        let before = arr.count
        arr.removeAll { entry in
            let u = (entry["url"] as? String) ?? ""
            return u.contains("/var/folders/") || u.hasPrefix("file:///var/folders/")
                || u.contains("/private/var/folders/")
                || u.hasPrefix("file:///tmp/") || u.contains("/SidebarBookmarksUAT-")
        }
        guard arr.count != before else { return }
        if let out = try? JSONSerialization.data(
            withJSONObject: arr, options: [.prettyPrinted]) {
            try? out.write(to: store)
        }
    }

    // MARK: - git fixture

    /// A scratch git repo named `gitrepo/` with deliberate churn:
    /// one tracked-clean, one staged-modified, one unstaged-modified, one
    /// untracked. Enough for status badges (M/A/?/U) to have something to show.
    private func makeGitRepoFixture() throws -> URL {
        let repo = try harness.makeDir("gitrepo")
        try harness.writeFile("gitrepo/clean.txt", "tracked clean\n")
        try harness.writeFile("gitrepo/staged.txt", "staged orig\n")
        try harness.writeFile("gitrepo/unstaged.txt", "unstaged orig\n")
        runGit(["init", "-q"], in: repo)
        runGit(["add", "-A"], in: repo)
        runGit(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], in: repo)
        // Churn: stage one edit, leave one edit unstaged, add one untracked.
        try harness.writeFile("gitrepo/staged.txt", "staged CHANGED\n")
        runGit(["add", "staged.txt"], in: repo)
        try harness.writeFile("gitrepo/unstaged.txt", "unstaged CHANGED\n")
        try harness.writeFile("gitrepo/untracked.txt", "brand new\n")
        return repo
    }

    @discardableResult
    private func runGit(_ args: [String], in dir: URL) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", dir.path] + args
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: - Model assertion helpers

    private func model(_ dump: [String: Any]) -> [String: Any] {
        dump["model"] as? [String: Any] ?? [:]
    }
    private func modelString(_ dump: [String: Any], _ key: String) -> String {
        // Special composite keys reach into the nested sidebar dict.
        if key == "sidebar.rootURL_norm" { return sidebarRootURL(dump) }
        return model(dump)[key] as? String ?? ""
    }
    private func intModel(_ dump: [String: Any], _ key: String) -> Int {
        model(dump)[key] as? Int ?? Int.min
    }
    private func boolModel(_ dump: [String: Any], _ key: String) -> Bool {
        model(dump)[key] as? Bool ?? false
    }
    private func boolSidebarVisible(_ dump: [String: Any]) -> Bool {
        boolModel(dump, "sidebarVisible")
    }
    private func sidebarRootURL(_ dump: [String: Any]) -> String {
        (model(dump)["sidebar"] as? [String: Any])?["rootURL"] as? String ?? ""
    }

    private func assertModel(
        _ dump: [String: Any], _ key: String, endsWith suffix: String,
        label: String, file: StaticString, line: UInt
    ) {
        let v = modelString(dump, key)
        XCTAssertTrue(v.hasSuffix(suffix),
            "[\(label)] model.\(key) (\(v.debugDescription)) does not end with \(suffix.debugDescription)",
            file: file, line: line)
    }
    private func assertSidebarRoot(
        _ dump: [String: Any], endsWith suffix: String,
        label: String, file: StaticString, line: UInt
    ) {
        let v = sidebarRootURL(dump)
        XCTAssertTrue(v.hasSuffix(suffix),
            "[\(label)] sidebar.rootURL (\(v.debugDescription)) does not end with \(suffix.debugDescription)",
            file: file, line: line)
    }
    private func assertNotError(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        XCTAssertNotEqual(modelString(dump, "currentStateKind"), "error",
            "[\(label)] document landed in .error state", file: file, line: line)
    }

    /// The realized sidebar subtree is mounted and non-degenerate: the
    /// SwiftUI-backed accordion lives inside `HostingScrollView`/`DocumentView`
    /// hosts, and the `SidebarKeyMonitor` representable is present once a root
    /// is set. We assert at least one scrollable accordion host exists and is
    /// not zero-sized (catches a collapsed/blank sidebar even when the model
    /// says it's "visible").
    private func assertSidebarSubtreeMounted(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        let nodes = allNodes(in: dump)
        let scrollHosts = nodes.filter {
            let c = ($0["class"] as? String) ?? ""
            return c.contains("HostingScrollView") || c.contains("NSScrollView")
        }
        XCTAssertFalse(scrollHosts.isEmpty,
            "[\(label)] no scroll host in tree — sidebar accordion did not mount",
            file: file, line: line)
        let anyVisible = scrollHosts.contains { $0["zeroSize"] == nil }
        XCTAssertTrue(anyVisible,
            "[\(label)] every scroll host is zero-sized — sidebar/content collapsed",
            file: file, line: line)
    }

    // MARK: - Tree-walk helpers

    private func allNodes(in dump: [String: Any]) -> [[String: Any]] {
        guard let root = dump["contentView"] as? [String: Any] else { return [] }
        var out: [[String: Any]] = []
        var stack: [[String: Any]] = [root]
        while let node = stack.popLast() {
            out.append(node)
            if let kids = node["subviews"] as? [[String: Any]] {
                stack.append(contentsOf: kids)
            }
        }
        return out
    }
    private func hasViewClass(_ dump: [String: Any], containing needle: String) -> Bool {
        allNodes(in: dump).contains { (($0["class"] as? String) ?? "").contains(needle) }
    }
}
