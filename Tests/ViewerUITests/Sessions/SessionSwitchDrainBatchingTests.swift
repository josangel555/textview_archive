import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// Perf P2/P3 (TSK-1043/1044) — the bulk session-switch drain must NOT re-run
/// the per-tab `updateDerived()` storm (refreshDiffMarks / warmLSP / repoFocus
/// / noteActiveTabForRetention) once per outgoing tab, nor materialize a
/// transient survivor that's itself about to close.
///
/// Grounded in the TSK-1040 audit: `closeAllTabsPreservingDirty` loops
/// `closeTabUnconditionally`, which used to call `settleSelectionAfterClose`
/// (→ `materializeIfNeeded`) + `updateDerived()` + `startWatchingCurrentFile()`
/// on EVERY iteration — O(outgoing tabs) wasted work when only the final
/// (empty) state matters. The fix sets `isBulkDraining` for the loop and runs a
/// SINGLE reconcile at the end.
///
/// Pure model layer — no NSApplication / NSWindow / WebView; host-safe (T1m).
/// The probes are DEBUG-only (#if DEBUG), like `MountProbe`.
/// Filter: `swift test --filter ViewerUITests.SessionSwitchDrainBatching`
@MainActor
final class SessionSwitchDrainBatchingTests: XCTestCase {

    private lazy var tmpRoot: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwitchDrainBatching-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    @discardableResult
    private func makeFile(_ name: String, lines: Int = 5) -> URL {
        let url = tmpRoot.appendingPathComponent(name)
        let body = (1...lines).map { "line \($0)" }.joined(separator: "\n")
        try? Data(body.utf8).write(to: url)
        return url
    }

    private func makeModel() -> DocumentModel {
        let defaults = UserDefaults(suiteName: "SwitchDrainBatching-\(UUID().uuidString)")!
        return DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpRoot.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    #if DEBUG
    func test_bulkDrain_callsUpdateDerivedExactlyOnce_notPerTab() {
        let model = makeModel()
        // Five open tabs (lazy-appended → .empty). A pre-fix drain would call
        // updateDerived() once per `closeTabUnconditionally` (N) PLUS the final
        // reconcile — i.e. it scaled with tab count.
        for i in 0..<5 {
            model.appendLazyTab(url: makeFile("f\(i).md"), viewMode: .formatted)
        }
        XCTAssertEqual(model.tabs.tabs.count, 5)

        model.resetDrainProbes()
        model.closeAllTabsPreservingDirty()

        XCTAssertTrue(model.tabs.tabs.isEmpty, "the drain must clear every tab")
        XCTAssertEqual(model.updateDerivedCalls, 1,
            "the bulk drain must reconcile ONCE — got \(model.updateDerivedCalls) (per-tab storm regressed)")
    }

    func test_bulkDrain_doesNotMaterializeATransientSurvivor() {
        let model = makeModel()
        // Lazy (.empty) tabs are exactly the ones a per-close
        // `settleSelectionAfterClose` would materialize as the auto-selected
        // neighbor — wasted work since they're about to be closed too.
        for i in 0..<4 {
            model.appendLazyTab(url: makeFile("g\(i).md"), viewMode: .formatted)
        }

        model.resetDrainProbes()
        model.closeAllTabsPreservingDirty()

        XCTAssertEqual(model.materializeCalls, 0,
            "the bulk drain must NOT materialize a survivor about to close — got \(model.materializeCalls)")
    }

    func test_singleTabClose_stillReconcilesAndMaterializesNormally() {
        // Guard against over-suppression: a NORMAL (non-bulk) close must still
        // settle + reconcile, so closing one of two lazy tabs materializes the
        // surviving selected tab and updates derived state.
        let model = makeModel()
        model.appendLazyTab(url: makeFile("keep.md"), viewMode: .formatted)
        model.appendLazyTab(url: makeFile("drop.md"), viewMode: .formatted)
        model.selectTab(at: 1)   // select the one we'll close

        model.resetDrainProbes()
        model.closeTabUnconditionally(at: 1)   // single, NOT a bulk drain

        XCTAssertEqual(model.tabs.tabs.count, 1)
        XCTAssertGreaterThanOrEqual(model.updateDerivedCalls, 1,
            "a single close must still run updateDerived (the batching suppression is bulk-drain ONLY)")
        XCTAssertGreaterThanOrEqual(model.materializeCalls, 1,
            "a single close must still materialize the surviving selected lazy tab")
    }
    #endif
}
