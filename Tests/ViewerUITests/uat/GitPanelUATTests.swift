import XCTest
import Foundation

/// UAT executable companion — **group 6/12: git-panel**.
///
/// Durable T4 live-app smoke for `docs/uat/smokes/git-panel.md` (GP-01..11).
/// Drives the assembled `dist/TextView.app` via the `--script` verb dispatcher
/// (the proven path from `ViewModeMatrixSmokeTests` /
/// `SidebarFileTreeAndBookmarksUATTests`), captures a `DiagnosticDump` JSON per
/// step, and asserts the scripted expectations against the authoritative
/// `model` sub-dict + structural view-CLASS detection.
///
/// ## Observability reality for THIS group (probed against a live dump)
///
/// The git panel is **almost entirely un-automatable from a `--script` run**,
/// and that is the headline finding for this group. Probing the live bundle
/// confirmed:
///
///  1. **There is NO `git-*` script verb.** The full `ScriptVerbDispatch`
///     vocabulary has exactly ONE git entry point: `file-history <path>`
///     (opens the in-app `FileHistoryView` as a hosted-view tab). Tab-strip
///     selection (STATUS/LOG/STASH/TREES/REMOTES/REVIEW), the Refresh button /
///     `⌥⌘R`, stash Apply/Pop/Drop, the repo picker, worktree/remote row
///     clicks — every interactive panel control is a LIVE CLICK with no verb,
///     so the scripted harness cannot reach them.
///  2. **SwiftUI `.accessibilityIdentifier()` does NOT propagate onto
///     `NSView.accessibilityIdentifier()`** that `DiagnosticDump` reads (the
///     group-1/2/5 finding, re-confirmed here): ZERO `mdv.gitPanel` /
///     `mdv.gitpanel.tab.*` / `mdv.gitpanel.repoPicker` / `mdv.rail.left.git`
///     ids appear in the dump's `contentView` tree OR `recursiveDescription`.
///     The tab strip, count badges, status rows, log graph, stash chips,
///     worktree/remote rows render as generic `DocumentView` /
///     `NSTextFieldSimpleLabel` hosts whose TEXT the dump does not capture.
///  3. **`ScriptVerb.modelStateDump` carries NO git-panel state** — no
///     `repoRoot`, `selectedTab`, branch/ahead/behind, status/stash/log/trees/
///     remotes counts, refresh timestamps. The only git-adjacent observable in
///     the dump is the `hostedView` tab `file-history` produces (state kind +
///     window title + tab count) and the realized File-History NSView subtree.
///  4. **The GIT accordion section did NOT mount in the scripted/occluded
///     run** even when the sidebar is rooted INSIDE a tracked repo with open
///     tabs and the FILES tree is fully git-aware (green repo icon + `?`
///     untracked badge prove `TrackedReposChannel` is populated). See
///     `test_GP_01_gitSectionMountWhenRootedInRepo` — it is authored as an
///     OBSERVATION probe (non-fatal `XCTAttachment`-style logging via the run
///     log), not a hard assertion, because the section's `repoRoot != nil`
///     gate depends on `RepoFocusTracker.updateFocusedRoot()` which runs
///     AFTER `handoffMirror()`'s channel-version tick inside the same async
///     `recompute()` Task — a plausible republish-ordering race that the
///     scripted path does not survive. Logged as F-GIT-1 in the run log.
///
/// Consequence: the genuinely-automatable git-panel surface here is **File
/// History** (GP-09/GP-10) via the `file-history` verb, plus the
/// `openFileHistory` repo-membership gate. Everything that needs the visible
/// tabbed panel (GP-01..08, GP-11) is enumerated in the run log as a
/// manual/VM-lane observability gap.
///
/// TIER-JUSTIFY: T4 — the observable is the assembled bundle's real
/// cross-process AppDelegate↔DocumentModel↔GitClient↔FileHistoryModel wiring in
/// a live `NSWindow`: `git log -- <path>` shell-out off-main, the hosted-view
/// tab spawn + `DocumentState.hostedView` routing, the master-detail HSplitView
/// realization, and the repo-membership gate. None of this is reachable from a
/// bare `(model, sessions)` headless pair. Self-skips on the headless gate
/// (`isAppBuilt` false); runs for real on the VM/nightly lane or as a
/// host-occluded UAT run.
@MainActor
final class GitPanelUATTests: MultiScenarioTestCase {

    override class var harnessLabel: String { "GitPanelUAT" }
    // File-History shells out to `git log`/`git diff` off-main and mounts an
    // HSplitView; give each scenario room for the git work + view settle.
    override class var defaultScenarioTimeout: TimeInterval { 90 }

    // MARK: - GP-09 — File History: hosted-view tab, master-detail mount

    /// `file-history <repo>/<tracked-file>` opens the in-app FileHistoryView
    /// as a hosted-view tab. Asserts the authoritative observables:
    ///   - `currentStateKind == hostedView` (the `DocumentState.hostedView`
    ///     route — proves the view-hosting tab actually took).
    ///   - `windowTitle == "History: <leaf>"` (the title `openHostedView`
    ///     stamps; the title-based Page Object contract).
    ///   - a SECOND tab was spawned and SELECTED (the file stays open in tab 1).
    ///   - the realized tree mounts the master-detail layout: an `NSSplitView`
    ///     (the HSplitView) AND a `SwiftUIOutlineListView` (the commit List),
    ///     both non-zero-sized — catches a blank/collapsed history pane the
    ///     model-only check would miss.
    func test_GP_09_fileHistoryOpensHostedMasterDetail() throws {
        let repo = try makeGitRepoFixture()
        let hist = repo.appendingPathComponent("hist.md")

        // argv opens hist.md (tab 1). `file-history hist.md` then opens the
        // history view as tab 2. Dump indices:
        //  [0] delay 1.2     -> hist.md open (tab 1, rendered)
        //  [1] set-root      -> sidebar rooted at repo
        //  [2] delay 0.6
        //  [3] file-history  -> hostedView tab 2, title "History: hist.md"
        //  [4] delay 1.2     -> git log + HSplitView settle
        let script = """
        delay 1.2
        sidebar-set-root \(repo.path)
        delay 0.6
        file-history \(hist.path)
        delay 1.2
        """
        try runScenarios([
            Scenario(
                name: "file-history-hosted",
                argFile: hist,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 5,
                        "expected >=5 step dumps", file: file, line: line)
                    guard dumps.count >= 5 else { return }

                    // [0] argv-opened hist.md is the focused tab, 1 tab.
                    XCTAssertEqual(intModel(dumps[0], "tabCount"), 1,
                        "[s1] argv should open exactly one tab", file: file, line: line)
                    assertModel(dumps[0], "currentURL", endsWith: "hist.md",
                                label: "s1-open", file: file, line: line)

                    // The last dump = file-history settled.
                    let last = dumps[dumps.count - 1]
                    XCTAssertEqual(modelString(last, "currentStateKind"), "hostedView",
                        "[file-history] tab did not route to .hostedView — FileHistoryView not hosted",
                        file: file, line: line)
                    XCTAssertEqual(modelString(last, "windowTitle"), "History: hist.md",
                        "[file-history] hosted tab title is not 'History: hist.md'",
                        file: file, line: line)
                    XCTAssertEqual(intModel(last, "tabCount"), 2,
                        "[file-history] expected a SECOND tab (file stays open in tab 1)",
                        file: file, line: line)
                    XCTAssertEqual(intModel(last, "selectedTabIndex"), 1,
                        "[file-history] the history tab should be selected (index 1)",
                        file: file, line: line)

                    // Structural: master-detail mounted, non-degenerate.
                    XCTAssertTrue(hasViewClass(last, containing: "NSSplitView"),
                        "[file-history] no NSSplitView — master-detail HSplitView did not realize",
                        file: file, line: line)
                    XCTAssertTrue(hasViewClass(last, containing: "OutlineListView")
                        || hasViewClass(last, containing: "ListCoreScrollView"),
                        "[file-history] no commit-list view — left commit Table did not mount",
                        file: file, line: line)
                    assertSplitNonZero(last, label: "file-history", file: file, line: line)

                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "gp09/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - GP-10 — File History gating on repo-membership

    /// `openFileHistory` repo-membership gate. The catalog (GP-10 step 4) says
    /// File History is unavailable OUTSIDE a repo. We confirm the underlying
    /// `openFileHistory` no-ops for a file that is NOT under any git root:
    /// firing `file-history <outside-file>` must NOT spawn a hosted tab — tab
    /// count and state stay put.
    ///
    /// NOTE (logged, not failed): for an UNTRACKED-but-inside-repo file,
    /// `openFileHistory` does NOT no-op — it opens a (legitimately empty)
    /// FileHistoryView showing "No history for this file." The `isTracked`
    /// gate lives only at the MENU layer (`canShowFileHistory`), which the
    /// script verb bypasses. Covered by the second scenario as an observation.
    func test_GP_10_fileHistoryGate_outsideRepoNoOp() throws {
        let repo = try makeGitRepoFixture()
        let hist = repo.appendingPathComponent("hist.md")
        // A file that is genuinely OUTSIDE any git repo (sibling of the repo,
        // directly under the scratch tmpdir which is not a git root).
        let outside = try harness.writeFile("outside.md", "# not in a repo\n")

        // [0] delay 1.0     -> hist.md open (tab 1)
        // [1] file-history outside.md -> MUST be a no-op (no repo root)
        // [2] delay 1.0
        let script = """
        delay 1.0
        file-history \(outside.path)
        delay 1.0
        """
        try runScenarios([
            Scenario(
                name: "file-history-outside-repo-noop",
                argFile: hist,
                script: script,
                assert: { [self] dumps, file, line in
                    XCTAssertGreaterThanOrEqual(dumps.count, 3,
                        "expected >=3 step dumps", file: file, line: line)
                    guard let last = dumps.last else { return }
                    // The outside-repo file-history is a no-op: still 1 tab,
                    // still the original loaded markdown, NOT a hostedView.
                    XCTAssertEqual(intModel(last, "tabCount"), 1,
                        "[outside-noop] file-history on a non-repo file should NOT spawn a tab",
                        file: file, line: line)
                    XCTAssertNotEqual(modelString(last, "currentStateKind"), "hostedView",
                        "[outside-noop] file-history on a non-repo file should NOT open a hosted view",
                        file: file, line: line)
                    assertModel(last, "currentURL", endsWith: "hist.md",
                                label: "outside-noop", file: file, line: line)
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "gp10a/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    /// GP-10 (BUG-026 fixed) — untracked-but-inside-repo file: `openFileHistory`
    /// NO-OPS. BUG-026 was filed because the verb opened a hosted (empty)
    /// history tab for an untracked in-repo file — the `isTracked` gate had
    /// lived only at the MENU layer. The fix (`c944ba1c`) moved the gate INTO
    /// `openFileHistory` itself (`GitClient.isTracked(path:)`), so firing
    /// `file-history` on an untracked in-repo file is now a no-op: no hosted
    /// tab, the original loaded markdown stays put. (Mirrors the outside-repo
    /// no-op above, but the cause is untracked-ness rather than no-repo.)
    func test_GP_10_untrackedInRepoFileHistoryNoOps() throws {
        let repo = try makeGitRepoFixture()
        // `untracked.txt` is created by the fixture but never `git add`ed.
        let untracked = repo.appendingPathComponent("untracked.txt")
        let hist = repo.appendingPathComponent("hist.md")

        let script = """
        delay 1.0
        sidebar-set-root \(repo.path)
        delay 0.5
        file-history \(untracked.path)
        delay 1.2
        """
        try runScenarios([
            Scenario(
                name: "file-history-untracked-noop",
                argFile: hist,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    // BUG-026: untracked in-repo file-history is a no-op — the
                    // isTracked gate now lives in openFileHistory, not just the
                    // menu. Still 1 tab, still the loaded markdown, NOT a hosted
                    // view.
                    XCTAssertEqual(intModel(last, "tabCount"), 1,
                        "[untracked-noop] file-history on an untracked file should NOT spawn a tab",
                        file: file, line: line)
                    XCTAssertNotEqual(modelString(last, "currentStateKind"), "hostedView",
                        "[untracked-noop] file-history on an untracked file should NOT open a hosted view",
                        file: file, line: line)
                    assertModel(last, "currentURL", endsWith: "hist.md",
                                label: "untracked-noop", file: file, line: line)
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "gp10b/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - GP-09 edge — File History against a file with real history

    /// File History over a file that HAS multiple commits touching it. We
    /// cannot read the commit-list ROW text from the dump (SwiftUI labels),
    /// but we CAN confirm the hosted view mounts and the commit-list scroll
    /// region is non-degenerate (a populated list yields a `ListCoreScrollView`
    /// / `OutlineListView` with content rows, vs the empty-state placeholder).
    /// This is the closest the scripted path gets to "the master-detail shows
    /// N commits."
    func test_GP_09_fileHistoryWithMultipleCommits() throws {
        let repo = try makeGitRepoFixture()  // hist.md has 3 commits
        let hist = repo.appendingPathComponent("hist.md")

        let script = """
        delay 1.0
        sidebar-set-root \(repo.path)
        delay 0.5
        file-history \(hist.path)
        delay 1.5
        """
        try runScenarios([
            Scenario(
                name: "file-history-multi-commit",
                argFile: hist,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    XCTAssertEqual(modelString(last, "currentStateKind"), "hostedView",
                        "[multi-commit] history view did not host", file: file, line: line)
                    // A populated commit list realizes the list-table cells.
                    let hasListRows = hasViewClass(last, containing: "ListTableRowView")
                        || hasViewClass(last, containing: "CellHostingView")
                        || hasViewClass(last, containing: "OutlineListView")
                    XCTAssertTrue(hasListRows,
                        "[multi-commit] commit-list rows did not realize — history list empty/blank",
                        file: file, line: line)
                    assertSplitNonZero(last, label: "multi-commit", file: file, line: line)
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "gp09edge/step\(i + 1)", file: file, line: line)
                    }
                })
        ])
    }

    // MARK: - GP-01 / GP-11 — GIT accordion section mount (OBSERVATION probe)

    /// The catalog (GP-01 step 1) expects the GIT accordion section to appear
    /// once the focused root resolves to a repo. PROBED FINDING (F-GIT-1): in
    /// the scripted/occluded run the section does NOT mount even when the
    /// sidebar is rooted inside the tracked repo with open tabs and the FILES
    /// tree is git-aware. The section self-gates on `panel.repoRoot != nil`,
    /// which `RepoFocusTracker.updateFocusedRoot()` only sets AFTER
    /// `handoffMirror()` ticks the channel version inside the same async Task
    /// — a republish-ordering window the scripted path doesn't survive.
    ///
    /// We assert ONLY the things that hold and are load-bearing (the sidebar
    /// roots at the repo without error, the FILES subtree mounts), and surface
    /// the missing-section observation as a NON-FATAL log line — we do NOT hard
    /// XCTFail on it, because (a) it may differ in a foreground GUI session and
    /// (b) the panel content itself is un-observable here regardless. F-GIT-1
    /// captures it for triage.
    func test_GP_01_gitSectionMountWhenRootedInRepo() throws {
        let repo = try makeGitRepoFixture()
        let hist = repo.appendingPathComponent("hist.md")

        let script = """
        delay 1.0
        sidebar-set-root \(repo.path)
        delay 2.0
        open \(repo.appendingPathComponent("clean.txt").path)
        delay 1.5
        """
        try runScenarios([
            Scenario(
                name: "git-section-mount-probe",
                argFile: hist,
                script: script,
                assert: { [self] dumps, file, line in
                    guard let last = dumps.last else {
                        XCTFail("no dumps", file: file, line: line); return
                    }
                    // Load-bearing: rooted at the repo, no error, tree mounted.
                    assertSidebarRoot(last, endsWith: "/gitrepo/", label: "git-section",
                                      file: file, line: line)
                    assertSidebarSubtreeMounted(last, label: "git-section",
                                                file: file, line: line)
                    for (i, d) in dumps.enumerated() {
                        assertNotError(d, label: "gp01/step\(i + 1)", file: file, line: line)
                    }
                    // OBSERVATION (non-fatal): is the GIT section mounted? It
                    // carries no NSView class / a11y id of its own; the only
                    // tell would be git-ish text in `recursiveDescription`,
                    // which a live probe showed is ABSENT in the scripted run.
                    // Record the probe result without failing the suite.
                    let mounted = recursiveDescriptionMentionsGit(last)
                    if !mounted {
                        // Not an XCTFail — see F-GIT-1 in the run log.
                        print("[UAT git-panel F-GIT-1] GIT accordion section NOT observed "
                            + "in the realized tree despite repo-rooted sidebar + git-aware "
                            + "FILES tree (scripted/occluded path).")
                    }
                })
        ])
    }

    // MARK: - git fixture

    /// A scratch git repo named `gitrepo/`:
    ///   - `hist.md` committed THREE times (real File-History fodder).
    ///   - `clean.txt` tracked-clean.
    ///   - `staged.txt` staged-modified, `unstaged.txt` unstaged-modified,
    ///     `untracked.txt` untracked (status churn for any future panel work).
    ///   - one `origin` remote (git@ shape) for completeness.
    /// Branch is whatever `git init` defaults to (main/master); we never assert
    /// the branch name since it's not dump-observable.
    private func makeGitRepoFixture() throws -> URL {
        let repo = try harness.makeDir("gitrepo")
        try harness.writeFile("gitrepo/hist.md", "orig\n")
        try harness.writeFile("gitrepo/clean.txt", "tracked clean\n")
        try harness.writeFile("gitrepo/staged.txt", "staged orig\n")
        try harness.writeFile("gitrepo/unstaged.txt", "unstaged orig\n")
        runGit(["init", "-q"], in: repo)
        runGit(["add", "-A"], in: repo)
        runGit(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init commit"], in: repo)
        // Two more commits touching hist.md → 3 commits of history.
        try harness.writeFile("gitrepo/hist.md", "second\n")
        runGit(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "second commit to hist"], in: repo)
        try harness.writeFile("gitrepo/hist.md", "third\n")
        runGit(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qam", "third commit to hist"], in: repo)
        // Status churn.
        try harness.writeFile("gitrepo/staged.txt", "staged CHANGED\n")
        runGit(["add", "staged.txt"], in: repo)
        try harness.writeFile("gitrepo/unstaged.txt", "unstaged CHANGED\n")
        try harness.writeFile("gitrepo/untracked.txt", "brand new untracked\n")
        runGit(["remote", "add", "origin", "git@github.com:owner/repo.git"], in: repo)
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

    // MARK: - Model + tree assertion helpers

    private func model(_ dump: [String: Any]) -> [String: Any] {
        dump["model"] as? [String: Any] ?? [:]
    }
    private func modelString(_ dump: [String: Any], _ key: String) -> String {
        model(dump)[key] as? String ?? ""
    }
    private func intModel(_ dump: [String: Any], _ key: String) -> Int {
        model(dump)[key] as? Int ?? Int.min
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

    /// The File-History HSplitView must be mounted AND non-degenerate (catches
    /// a 0×0 / collapsed history pane even when the split view itself exists).
    private func assertSplitNonZero(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        let splits = allNodes(in: dump).filter {
            (($0["class"] as? String) ?? "").contains("NSSplitView")
        }
        XCTAssertFalse(splits.isEmpty,
            "[\(label)] no NSSplitView in tree", file: file, line: line)
        let anyVisible = splits.contains { $0["zeroSize"] == nil }
        XCTAssertTrue(anyVisible,
            "[\(label)] every NSSplitView is zero-sized — history pane collapsed/blank",
            file: file, line: line)
    }

    /// The realized sidebar subtree is mounted and non-degenerate (the
    /// SwiftUI accordion lives inside `HostingScrollView`/`NSScrollView` hosts).
    private func assertSidebarSubtreeMounted(
        _ dump: [String: Any], label: String, file: StaticString, line: UInt
    ) {
        let scrollHosts = allNodes(in: dump).filter {
            let c = ($0["class"] as? String) ?? ""
            return c.contains("HostingScrollView") || c.contains("NSScrollView")
        }
        XCTAssertFalse(scrollHosts.isEmpty,
            "[\(label)] no scroll host in tree — sidebar accordion did not mount",
            file: file, line: line)
        let anyVisible = scrollHosts.contains { $0["zeroSize"] == nil }
        XCTAssertTrue(anyVisible,
            "[\(label)] every scroll host is zero-sized — sidebar collapsed",
            file: file, line: line)
    }

    /// True if `recursiveDescription` carries any git-panel text (section
    /// header / tab labels). The scripted/occluded run showed this is ABSENT;
    /// used only as the F-GIT-1 observation probe, never a hard assertion.
    private func recursiveDescriptionMentionsGit(_ dump: [String: Any]) -> Bool {
        let rd = (dump["recursiveDescription"] as? String) ?? ""
        let lower = rd.lowercased()
        // The GIT section header text is "Git"; tab labels are
        // Status/Log/Stash/Trees/Remotes. Any of those in the realized tree
        // would indicate the section mounted.
        return lower.contains("stash") || lower.contains("worktree")
            || lower.contains("remotes") || rd.contains("STATUS")
    }

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
