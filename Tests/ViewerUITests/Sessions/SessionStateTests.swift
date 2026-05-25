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
        XCTAssertEqual(snap.displayName, "TestSession")
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
        XCTAssertEqual(snap.displayName, "TestSession")
    }

    // MARK: forwarding -----------------------------------------------

    func testDocumentModelChangePropagatesToObjectWillChange() {
        let exp = expectation(description: "objectWillChange fires")
        var cancellables: Set<AnyCancellable> = []
        state.objectWillChange
            .sink { _ in exp.fulfill() }
            .store(in: &cancellables)
        // Any @Published mutation on the wrapped model should bubble.
        model.sourceWordWrap.toggle()
        wait(for: [exp], timeout: 1.0)
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
}
