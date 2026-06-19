import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-921 — the split-pane CLOSE action contract, end-to-end at the model
/// layer. The on-screen `xmark` button (`SplitPaneView` header, ~:118) is wired
/// as `Button(action: onClose)` with `onClose: { model.closeSplit() }`
/// (`ContentView`). This pins the SAME closure ContentView passes — and the
/// per-pane teardown the view's `.onDisappear` runs — so a regression in the
/// close path (slot leak, stuck `splitURL`, a synchronous disk read on close)
/// fails on the host gate. The actual tap event reaching the button is VM-only
/// (SwiftUI owns gesture routing) and stays at review.
///
/// Tier 1 main-actor; uses the REAL controller/coordinator (no mocks) so the
/// `closeSplit() -> tabCoordinator.closeSplit() { splitURL = nil }` +
/// `refreshSplitDiffMarks()` chain is exercised exactly as shipped.
@MainActor
final class SplitPaneCloseActionTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyStoreURL: URL!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitPaneCloseActionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "SplitPaneCloseActionTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        historyStoreURL = tmpDir.appendingPathComponent("history.json")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: historyStoreURL),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    private func writeFile(_ name: String, _ contents: String = "x") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - The exact closure ContentView passes to the xmark button

    /// `onClose: { model.closeSplit() }` — open a split, then invoke the SAME
    /// closure and assert the pane closes (the user-reported "can't close").
    func test_closeSplit_closure_nilsSplitURL() throws {
        let model = makeModel()
        let split = try writeFile("a.txt", "hello\n")

        model.openInSplit(split)
        XCTAssertNotNil(model.splitURL, "openInSplit pins the file")
        XCTAssertTrue(model.isSplitOpen)

        // This is byte-for-byte the closure ContentView wires to the button.
        let onClose: () -> Void = { model.closeSplit() }
        onClose()

        XCTAssertNil(model.splitURL, "close action must clear the split URL")
        XCTAssertFalse(model.isSplitOpen, "split is no longer open after close")
    }

    /// Closing then re-opening must work — the close fully resets state so the
    /// next open isn't wedged (idempotency of the close → open cycle).
    func test_closeSplit_thenReopen_roundTrips() throws {
        let model = makeModel()
        let a = try writeFile("a.txt")
        let b = try writeFile("b.txt")

        model.openInSplit(a)
        model.closeSplit()
        XCTAssertNil(model.splitURL)

        model.openInSplit(b)
        XCTAssertEqual(model.splitURL,
                       b.standardizedFileURL.resolvingSymlinksInPath(),
                       "split re-opens cleanly after a close")
        model.closeSplit()
        XCTAssertNil(model.splitURL)
    }

    /// `toggleSplit()` (the ⌘⇧\ menu/keybinding path) closes when a split is
    /// open — the other way the user closes the pane.
    func test_toggleSplit_closesWhenOpen() throws {
        let model = makeModel()
        let a = try writeFile("a.txt")

        model.openInSplit(a)
        XCTAssertNotNil(model.splitURL)

        model.toggleSplit()   // open ⇒ toggle closes
        XCTAssertNil(model.splitURL, "toggleSplit closes an open split")
    }

    /// Idempotent: closing an already-closed split is a harmless no-op (a
    /// double-tap / redundant menu invocation must not crash or wedge state).
    func test_closeSplit_whenAlreadyClosed_isNoOp() {
        let model = makeModel()
        XCTAssertNil(model.splitURL)
        model.closeSplit()
        XCTAssertNil(model.splitURL, "closing a closed split stays closed")
    }

    // MARK: - Per-pane CSV filter slot cleanup (.onDisappear)

    /// `SplitPaneView.onDisappear` runs `model.clearCsvFilterState(forTabID:)`
    /// for the pane's pseudo-tab id, so the model's filter-state map doesn't
    /// grow by one every open/close cycle. Pin that release: a slot set for the
    /// split pseudo-tab is gone after the cleanup the view performs on close.
    func test_closeSplit_releasesPerPaneCsvFilterSlot() throws {
        let model = makeModel()
        let csv = try writeFile("data.csv", "a,b\n1,2\n")

        // The split pane keys CSV filter state on a per-instance pseudo-tab id
        // (SplitPaneView.@State splitCSVTabID). Simulate the pane having stored
        // a filter, then exercise the exact teardown its .onDisappear runs.
        let splitCSVTabID = UUID()
        model.openInSplit(csv)
        var filter = DocumentModel.CSVFilterState()
        filter.globalQuery = "needle"
        model.setCsvFilterState(filter, forTabID: splitCSVTabID)
        XCTAssertEqual(model.csvFilterState(forTabID: splitCSVTabID).globalQuery,
                       "needle", "slot is occupied while the split CSV is shown")
        XCTAssertNotNil(model.csvFilterStates[splitCSVTabID])

        // User clicks xmark → the pane disappears → close + slot cleanup.
        model.closeSplit()
        model.clearCsvFilterState(forTabID: splitCSVTabID)   // SplitPaneView.onDisappear

        XCTAssertNil(model.splitURL)
        XCTAssertNil(model.csvFilterStates[splitCSVTabID],
                     "the per-pane CSV filter slot is freed on close — no per-open-close growth")
        XCTAssertEqual(model.csvFilterState(forTabID: splitCSVTabID),
                       DocumentModel.CSVFilterState(),
                       "a freed slot reads back as the default (empty) filter")
    }

    /// Slot cleanup is scoped to the split pseudo-tab only — closing the split
    /// must NOT drop a real tab's CSV filter state (no over-broad clear).
    func test_closeSplit_doesNotClearUnrelatedCsvSlots() throws {
        let model = makeModel()
        let realTabID = UUID()
        var keep = DocumentModel.CSVFilterState()
        keep.globalQuery = "keep-me"
        model.setCsvFilterState(keep, forTabID: realTabID)

        let splitCSVTabID = UUID()
        let csv = try writeFile("d.csv", "a\n1\n")
        model.openInSplit(csv)
        model.setCsvFilterState(DocumentModel.CSVFilterState(), forTabID: splitCSVTabID)

        model.closeSplit()
        model.clearCsvFilterState(forTabID: splitCSVTabID)

        XCTAssertEqual(model.csvFilterState(forTabID: realTabID).globalQuery,
                       "keep-me", "an unrelated tab's CSV filter survives a split close")
    }

    // MARK: - The "slow / takes very long" angle: no synchronous disk read on close

    /// Regression for the "takes a very long time" half of the report. The
    /// close path is `closeSplit() -> tabCoordinator.closeSplit() {splitURL=nil}`
    /// + `refreshSplitDiffMarks()`, which short-circuits on `splitURL == nil`
    /// (cancel task, return) — it NEVER calls `TextFileLoader().load`, never
    /// touches disk, never spawns a diff task. Prove it by closing a split whose
    /// backing file has been DELETED: a synchronous load/stat on the close path
    /// would fail or stall; the close must still complete instantly and cleanly.
    func test_closeSplit_doesNotReadDisk_evenWhenFileIsGone() throws {
        let model = makeModel()
        let gone = try writeFile("ephemeral.txt", "bytes\n")
        model.openInSplit(gone)
        XCTAssertNotNil(model.splitURL)

        // Delete the file out from under the open split.
        try FileManager.default.removeItem(at: gone)
        XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))

        // Close must not depend on the file (no load on the close path).
        let started = Date()
        model.closeSplit()
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(model.splitURL, "split closes cleanly with no backing file")
        // Generous bound: a real synchronous file read/diff would be orders of
        // magnitude slower; this is pure in-memory state mutation.
        XCTAssertLessThan(elapsed, 0.5,
                          "close is a synchronous state flip — no disk read / diff on the close path")
    }
}
