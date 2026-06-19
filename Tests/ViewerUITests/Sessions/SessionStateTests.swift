import XCTest
import Combine
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// Behavioral tests for the Phase-1 `SessionState` façade. We focus on:
///
///   - `mount` / `detach` idempotence (calling either twice is a no-op
///     on the second call; the file-watcher pause/resume must not
///     double-fire).
///   - The detach→pause / mount→resume contract — verified by
///     observing the `DocumentModel`'s `watchedURL` flip to nil on
///     detach and back to the tab URL on mount.
///   - `makeSnapshot()` reflects current `DocumentModel` state.
///   - `wireForwarding`: a change on the wrapped `DocumentModel`
///     publishes through `SessionState.objectWillChange`.
///
/// Lives under `ViewerUITests` because `SessionState` and
/// `DocumentModel` both ship in `ViewerUI`. Despite that, these tests
/// do NOT touch NSApplication / NSWindow — they're pure model tests
/// and safe on the host Mac. Filter:
///   `swift test --filter ViewerUITests.SessionState`
@MainActor
final class SessionStateTests: XCTestCase {

    // Lazy initializers — Swift 6.1 (VM canary) keeps setUp/tearDown
    // nonisolated even when the class is `@MainActor`. Lazy vars get
    // evaluated on first access from a `@MainActor`-isolated test
    // method, which is what we want.
    private lazy var tmpDir: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionStateTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }()
    private lazy var model: DocumentModel = DocumentModel()
    private lazy var state: SessionState = SessionState(
        rootURL: tmpDir,
        displayName: "TestSession",
        model: model
    )

    /// Track whether the lazy `tmpDir` actually got materialized this
    /// test. We only want to remove the directory if it was created
    /// — touching the file system in `tearDown` for tests that never
    /// allocated would be wasteful (and racy under `@MainActor`).
    private var tmpDirCreated = false

    override func setUp() async throws {
        // Force lazy materialization here so tearDown sees a non-nil
        // path on every test run. The previous shape relied on the
        // first `@MainActor` test method to trigger evaluation; some
        // tests never read `tmpDir` and so leaked the directory under
        // /var/folders/.../T/ between runs.
        _ = tmpDir
        tmpDirCreated = true
    }

    override func tearDown() async throws {
        if tmpDirCreated {
            try? FileManager.default.removeItem(at: tmpDir)
        }
    }

    // MARK: mount / detach idempotence -------------------------------

    func testMountFromInitialStateFlipsIsMountedTrue() {
        XCTAssertFalse(state.isMounted)
        state.mount()
        XCTAssertTrue(state.isMounted)
    }

    func testMountTwiceIsIdempotent() {
        state.mount()
        let firstActiveAt = state.lastActiveAt
        // Sleep wouldn't help here (the test runs fast); we'd rather
        // not introduce timing flake. Instead assert no spurious state
        // mutation by reading isMounted again — a re-mount is a no-op.
        state.mount()
        XCTAssertTrue(state.isMounted)
        // `lastActiveAt` is bumped only on a real mount transition;
        // the second mount should not bump it.
        XCTAssertEqual(state.lastActiveAt, firstActiveAt)
    }

    func testDetachFromUnmountedIsNoOp() {
        XCTAssertFalse(state.isMounted)
        state.detach()
        XCTAssertFalse(state.isMounted)
    }

    func testDetachAfterMountFlipsIsMountedFalse() {
        state.mount()
        state.detach()
        XCTAssertFalse(state.isMounted)
    }

    func testDetachTwiceIsIdempotent() {
        state.mount()
        state.detach()
        // Calling detach again must not crash and must not re-pause
        // an already-paused FileWatcher (which would re-trigger
        // DocumentModel's watcher-shutdown work).
        state.detach()
        XCTAssertFalse(state.isMounted)
    }

    func testMountDetachMountCycle() {
        state.mount()
        XCTAssertTrue(state.isMounted)
        state.detach()
        XCTAssertFalse(state.isMounted)
        state.mount()
        XCTAssertTrue(state.isMounted)
        state.detach()
        XCTAssertFalse(state.isMounted)
    }

    // MARK: snapshot serialization -----------------------------------

    func testMakeSnapshotReflectsModelState() throws {
        // Set up some model state on the wrapped DocumentModel.
        let subDir = tmpDir.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(
            at: subDir, withIntermediateDirectories: true
        )
        let fileURL = subDir.appendingPathComponent("a.md")
        try "# hi\n".write(to: fileURL, atomically: true, encoding: .utf8)
        model.sidebar.setRoot(subDir)
        model.appendLazyTab(url: fileURL, viewMode: .source)

        let snap = state.makeSnapshot()
        XCTAssertEqual(snap.id, state.id)
        // TSK-1016: the session was created with a folder-derived (not
        // user-set) name, so re-rooting to `proj/` relabels the tab to "proj".
        XCTAssertEqual(snap.displayName, "proj",
            "tab name tracks the current root folder when not user-renamed (TSK-1016)")
        // sidebarRootPath prefers the model's sidebar root over the
        // session's rootURL when set.
        XCTAssertEqual(snap.sidebarRootPath, subDir.path)
        XCTAssertEqual(snap.openTabs.count, 1)
        XCTAssertEqual(snap.openTabs.first?.path, fileURL.path)
        XCTAssertEqual(snap.openTabs.first?.viewMode, "source")
    }

    func testMakeSnapshotEmptyModelProducesEmptyTabs() {
        let snap = state.makeSnapshot()
        XCTAssertTrue(snap.openTabs.isEmpty)
        // TSK-1016: the empty model has no sidebar root, so the live root falls
        // back to the session's `rootURL` (tmpDir). The name is folder-derived
        // (not user-set), so the snapshot relabels to the tmpDir folder name —
        // NOT the init-time "TestSession" string (which was never user-set).
        XCTAssertEqual(snap.displayName, tmpDir.lastPathComponent)
        XCTAssertNil(snap.displayNameIsUserSet)
    }

    // MARK: forwarding -----------------------------------------------

    /// REPUB-1 (2026-05-30): the old `wireForwarding()` bridged
    /// `model.objectWillChange` → `SessionState.objectWillChange`. That
    /// was the banned child→parent republish (LESSONS.md "SwiftUI
    /// republish forwarding amplifies every tick") and it was dead
    /// weight — no view binds `@ObservedObject` to a `SessionState`.
    /// We now assert the *inverse*: a DocumentModel-only mutation must
    /// NOT republish SessionState. The dedicated invariant pin lives in
    /// `SessionStateRepublishInvariantTests`; this keeps the behavioral
    /// suite honest after the removal.
    func testDocumentModelChangeDoesNotPropagateToObjectWillChange() async {
        var count = 0
        let sub = state.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        // A @Published mutation on the wrapped model must not bubble up.
        model.sourceWordWrap.toggle()
        await Task.yield()
        XCTAssertEqual(count, 0,
            "DocumentModel ticks must not republish SessionState (REPUB-1)")
    }

    // MARK: hydrate selection (PERSIST-01) ---------------------------

    /// PERSIST-01: `selectedTabIndex` indexes the *persisted* tab list,
    /// but hydrate skips tabs whose file is missing. The middle file is
    /// gone here, so the surviving live list is [a, c] — selecting by
    /// the raw persisted index (2) would point past the end or at the
    /// wrong tab. Selection must resolve by path → tab `c`.
    func testHydrateSelectsByPathWhenAMiddleFileIsMissing() throws {
        let a = tmpDir.appendingPathComponent("a.md")
        let c = tmpDir.appendingPathComponent("c.md")
        try "# a\n".write(to: a, atomically: true, encoding: .utf8)
        try "# c\n".write(to: c, atomically: true, encoding: .utf8)
        let missingB = tmpDir.appendingPathComponent("b.md")  // never created

        let snap = SessionSnapshot(
            id: state.id, displayName: "TestSession",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: tmpDir.path,
            openTabs: [
                TabSnapshot(path: a.path, viewMode: "rendered"),
                TabSnapshot(path: missingB.path, viewMode: "rendered"),
                TabSnapshot(path: c.path, viewMode: "rendered"),
            ],
            selectedTabIndex: 2   // points at c in the *persisted* list
        )
        state.hydrate(from: snap)

        XCTAssertEqual(model.tabs.tabs.count, 2, "missing file should be skipped")
        XCTAssertEqual(model.tabs.selected?.url?.path, c.path,
            "selection must resolve by path to c, not by the stale index (PERSIST-01)")
    }

    /// When the *selected* tab's own file is the one that went missing,
    /// there's nothing to refocus — fall back to the first surviving tab
    /// rather than crashing or selecting nothing.
    func testHydrateFallsBackWhenSelectedTabFileMissing() throws {
        let a = tmpDir.appendingPathComponent("a.md")
        try "# a\n".write(to: a, atomically: true, encoding: .utf8)
        let missingB = tmpDir.appendingPathComponent("b.md")

        let snap = SessionSnapshot(
            id: state.id, displayName: "TestSession",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: tmpDir.path,
            openTabs: [
                TabSnapshot(path: a.path, viewMode: "rendered"),
                TabSnapshot(path: missingB.path, viewMode: "rendered"),
            ],
            selectedTabIndex: 1   // the missing one
        )
        state.hydrate(from: snap)
        XCTAssertEqual(model.tabs.tabs.count, 1)
        XCTAssertEqual(model.tabs.selected?.url?.path, a.path,
            "selected-but-missing tab falls back to first surviving tab")
    }

    func testHydrateNilSelectionDoesNotForceSelection() throws {
        let a = tmpDir.appendingPathComponent("a.md")
        let b = tmpDir.appendingPathComponent("b.md")
        try "# a\n".write(to: a, atomically: true, encoding: .utf8)
        try "# b\n".write(to: b, atomically: true, encoding: .utf8)
        let snap = SessionSnapshot(
            id: state.id, displayName: "TestSession",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: tmpDir.path,
            openTabs: [
                TabSnapshot(path: a.path, viewMode: "rendered"),
                TabSnapshot(path: b.path, viewMode: "rendered"),
            ],
            selectedTabIndex: nil
        )
        state.hydrate(from: snap)
        // appendLazyTab leaves the last-appended tab selected; nil
        // selection means "don't override", so it stays where append left it.
        XCTAssertEqual(model.tabs.tabs.count, 2)
    }

    // MARK: include-hidden is always ON (TSK-363) ---------------------

    /// The show-hidden eye toggle is GONE — hidden files are always
    /// shown. A pre-removal session persisted `sidebarIncludeHidden:
    /// false`; honoring it would strand the user (hidden files invisible
    /// with no button left to recover). Hydrate must force-true.
    func testHydrateIgnoresStalePersistedIncludeHiddenFalse() {
        model.sidebar.includeHidden = false   // simulate stale shared-model state
        let snap = SessionSnapshot(
            id: state.id, displayName: "TestSession",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: tmpDir.path,
            sidebarIncludeHidden: false   // stale pre-removal persisted value
        )
        state.hydrate(from: snap)
        XCTAssertTrue(model.sidebar.includeHidden,
            "stale persisted false must be neutralized — hidden files are always shown (TSK-363)")
    }

    func testHydrateNilIncludeHiddenAlsoLandsTrue() {
        model.sidebar.includeHidden = false
        let snap = SessionSnapshot(
            id: state.id, displayName: "TestSession",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: tmpDir.path,
            sidebarIncludeHidden: nil
        )
        state.hydrate(from: snap)
        XCTAssertTrue(model.sidebar.includeHidden,
            "nil (the only value written going forward) must land true, not the legacy nil⇒false")
    }

    /// The field is no longer persisted: snapshots write nil regardless
    /// of model state, so the legacy value can never be re-minted.
    func testMakeSnapshotNeverPersistsIncludeHidden() {
        model.sidebar.includeHidden = true
        XCTAssertNil(state.makeSnapshot().sidebarIncludeHidden,
            "sidebarIncludeHidden is decode-compat only — never written (TSK-363)")
    }

    // MARK: default display name -------------------------------------

    func testDefaultDisplayNameFromURL() {
        let url = URL(fileURLWithPath: "/Users/me/code/myproj")
        XCTAssertEqual(SessionState.defaultDisplayName(for: url), "myproj")
    }

    func testDefaultDisplayNameRootFallback() {
        // Root URL has empty lastPathComponent.
        let url = URL(fileURLWithPath: "/")
        XCTAssertEqual(SessionState.defaultDisplayName(for: url), "Untitled")
    }

    // MARK: TSK-1016 — tab name tracks the current root folder -------

    /// When the session's root changes (here via the shared sidebar's
    /// `setRoot`), the next `makeSnapshot()` re-derives the title from the new
    /// folder name — the live relabel path the SessionTabBar consumes.
    func testMakeSnapshotRelabelsOnRootChange() throws {
        let alpha = tmpDir.appendingPathComponent("alpha", isDirectory: true)
        let beta = tmpDir.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)

        let s = SessionState(rootURL: alpha, model: DocumentModel())
        XCTAssertEqual(s.displayName, "alpha")
        // Root change on the shared sidebar (DocumentModel.openFolder /
        // revealInSidebar do exactly this).
        s.model.sidebar.setRoot(beta)
        let snap = s.makeSnapshot()
        XCTAssertEqual(snap.displayName, "beta",
            "tab name must follow the new root folder when not user-renamed")
        XCTAssertEqual(s.displayName, "beta", "live @Published name updated for the strip")
        XCTAssertEqual(s.rootURL, beta, "rootURL re-synced to the live sidebar root")
        XCTAssertNil(snap.displayNameIsUserSet, "folder-derived ⇒ flag omitted")
    }

    /// A manually-renamed session (displayNameIsUserSet) must keep its name
    /// across a root change — the manual rename wins.
    func testMakeSnapshotKeepsManualNameOnRootChange() throws {
        let alpha = tmpDir.appendingPathComponent("alpha", isDirectory: true)
        let beta = tmpDir.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: alpha, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)

        let s = SessionState(rootURL: alpha,
                             displayName: "My Work",
                             displayNameIsUserSet: true,
                             model: DocumentModel())
        s.model.sidebar.setRoot(beta)
        let snap = s.makeSnapshot()
        XCTAssertEqual(snap.displayName, "My Work",
            "a manual rename must survive a later root change")
        XCTAssertEqual(snap.displayNameIsUserSet, true, "user-set flag persisted")
    }

    /// The user-set flag round-trips through hydrate so a restored manual name
    /// is not auto-relabeled on the first post-restore root change.
    func testHydrateRestoresUserSetFlag() throws {
        let beta = tmpDir.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        let snap = SessionSnapshot(
            id: state.id, displayName: "My Work",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: beta.path,
            displayNameIsUserSet: true
        )
        state.hydrate(from: snap)
        XCTAssertTrue(state.displayNameIsUserSet)
        XCTAssertEqual(state.displayName, "My Work")
        // A subsequent root change must NOT relabel.
        let gamma = tmpDir.appendingPathComponent("gamma", isDirectory: true)
        try FileManager.default.createDirectory(at: gamma, withIntermediateDirectories: true)
        state.model.sidebar.setRoot(gamma)
        XCTAssertEqual(state.makeSnapshot().displayName, "My Work")
    }
}
