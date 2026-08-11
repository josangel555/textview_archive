import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-921 / TSK-922 — the split-pane OBSERVATION-PROPAGATION pin (root cause).
///
/// THE BUG (owner: "it's a race condition — it works when you switch tabs, but
/// if you stay in the tab, nothing happens"):
///   - `splitURL` is `@Published` on `TabCoordinator` (a NESTED ObservableObject).
///   - `openInSplit` / `closeSplit` mutate `tabCoordinator.splitURL`, firing ONLY
///     `tabCoordinator.objectWillChange` — and DELIBERATELY NOT
///     `DocumentModel.objectWillChange` (PERF #1: forwarding it would re-body the
///     whole content tree on every split toggle; pinned by
///     `TabRepublishInvariantTests.test_openInSplit_doesNotRepublishDocumentModel`).
///   - `ContentView` GATES the split pane on `splitURL` but previously observed
///     ONLY `@ObservedObject var model: DocumentModel`. Since the open/close
///     mutation never fires `model.objectWillChange`, `ContentView.body` was never
///     re-evaluated → the split pane did not appear (open) / disappear (close).
///   - Switching tabs mutates state that DOES fire `model.objectWillChange`
///     (`updateDerived` → a `@Published` on DocumentModel), forcing a re-body that
///     finally re-reads `splitURL` and shows/hides the pane. THAT is "works only
///     when I switch tabs."
///
/// THE FIX: `ContentView` now observes `model.tabCoordinator` DIRECTLY
/// (`@ObservedObject var tabCoordinator: TabCoordinator`) — the same
/// narrow-observation pattern it already uses for `sidebar` / `find` /
/// `panelLayout` / `terminalPane` — so an open/close re-bodies `ContentView`
/// immediately, WITHOUT reintroducing the PERF #1 republish storm.
///
/// What these tests pin (host-testable propagation; the on-screen "appears
/// instantly" stays VM/owner-confirmed):
///   - `tabCoordinator.objectWillChange` — the signal `ContentView` now observes —
///     FIRES SYNCHRONOUSLY on BOTH `openInSplit` AND `closeSplit`.
///   - the PERF invariant is preserved: `model.objectWillChange` still fires ZERO
///     times on those calls (we did not "fix" the bug by re-bridging the storm).
///
/// TEETH: revert the `ContentView` `@ObservedObject var tabCoordinator` (so the
/// split gate is driven only by `model.objectWillChange`) and the split would
/// once again update only on a `model`-republishing event (a tab switch) — the
/// exact bug. These tests assert the coordinator signal fires while the model
/// signal does not, which is precisely the propagation channel the fix relies on.
@MainActor
final class SplitObservationTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitObservationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "SplitObservationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String = "x") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Count `objectWillChange` fires on the coordinator (the channel
    /// `ContentView` now observes) while `mutate` runs. `objectWillChange`
    /// fires SYNCHRONOUSLY on a `@Published` willSet, so no async hop is needed
    /// — but we yield once to mirror the republish-invariant helper and catch
    /// any deferred publish.
    private func countCoordinatorRepublishes(
        of model: DocumentModel,
        whileRunning mutate: () -> Void
    ) async -> Int {
        var count = 0
        let sub = model.tabCoordinator.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        mutate()
        await Task.yield()
        return count
    }

    private func countModelRepublishes(
        of model: DocumentModel,
        whileRunning mutate: () -> Void
    ) async -> Int {
        var count = 0
        let sub = model.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        mutate()
        await Task.yield()
        return count
    }

    // MARK: - The propagation channel ContentView relies on (the fix)

    /// OPEN: `openInSplit` must fire `tabCoordinator.objectWillChange` — that is
    /// the published signal `ContentView` observes to re-body and create the
    /// split pane. If this did NOT fire (and `model.objectWillChange` doesn't
    /// either — see below), the split would only appear on a later tab switch:
    /// the reported bug.
    func test_openInSplit_firesTabCoordinatorObjectWillChange() async throws {
        let model = makeModel()
        let url = try writeFile("a.md", "# a\n")
        await Task.yield()

        let count = await countCoordinatorRepublishes(of: model) {
            model.openInSplit(url)
        }

        XCTAssertGreaterThan(count, 0,
            "openInSplit must fire tabCoordinator.objectWillChange so ContentView re-bodies and SHOWS the split immediately (not only after a tab switch)")
        XCTAssertNotNil(model.splitURL, "openInSplit pins the split file")
    }

    /// CLOSE: `closeSplit` must ALSO fire `tabCoordinator.objectWillChange` —
    /// the close path was the owner's "even worse" case. Same channel; verified
    /// SEPARATELY because the close path is distinct (`splitURL = nil`).
    func test_closeSplit_firesTabCoordinatorObjectWillChange() async throws {
        let model = makeModel()
        let url = try writeFile("a.md", "# a\n")
        model.openInSplit(url)
        XCTAssertNotNil(model.splitURL)
        await Task.yield()

        let count = await countCoordinatorRepublishes(of: model) {
            model.closeSplit()
        }

        XCTAssertGreaterThan(count, 0,
            "closeSplit must fire tabCoordinator.objectWillChange so ContentView re-bodies and REMOVES the split immediately (not only after a tab switch)")
        XCTAssertNil(model.splitURL, "closeSplit clears the split file")
    }

    /// `toggleSplit` (⌘⇧\) — both directions must fire the coordinator
    /// signal so ContentView re-bodies. I-19 (2026-08-11): for MARKDOWN the
    /// toggle drives the PER-TAB split-editing layout (a `tabs` mutation —
    /// same coordinator signal); files without a rendered preview keep the
    /// classic same-file pane (`splitURL`), covered below.
    func test_toggleSplit_firesTabCoordinatorObjectWillChange_bothDirections() async throws {
        let model = makeModel()
        let url = try writeFile("a.md", "# a\n")
        model.open(url: url)            // currentURL set so toggle has a file to split
        await Task.yield()

        let openCount = await countCoordinatorRepublishes(of: model) {
            model.toggleSplit()        // off ⇒ per-tab split-editing
        }
        XCTAssertTrue(model.isSplitEditingActive, "toggle enters the per-tab layout")
        XCTAssertNil(model.splitURL, "markdown same-file split does not claim the pane")
        XCTAssertGreaterThan(openCount, 0,
            "toggleSplit (enter) fires the coordinator signal")

        let closeCount = await countCoordinatorRepublishes(of: model) {
            model.toggleSplit()        // on ⇒ off
        }
        XCTAssertFalse(model.isSplitEditingActive, "toggle exits the layout")
        XCTAssertGreaterThan(closeCount, 0,
            "toggleSplit (exit) fires the coordinator signal")
    }

    /// The classic pane path (no rendered preview): both directions still
    /// fire the coordinator signal via `splitURL`.
    func test_toggleSplit_paneFallback_firesTheSignal_bothDirections() async throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "text\n")
        model.open(url: url)
        await Task.yield()

        let openCount = await countCoordinatorRepublishes(of: model) {
            model.toggleSplit()        // closed ⇒ open pane
        }
        XCTAssertNotNil(model.splitURL, "no preview ⇒ the classic same-file pane")
        XCTAssertGreaterThan(openCount, 0)

        let closeCount = await countCoordinatorRepublishes(of: model) {
            model.toggleSplit()        // open ⇒ close
        }
        XCTAssertNil(model.splitURL)
        XCTAssertGreaterThan(closeCount, 0)
    }

    // MARK: - PERF invariant preserved (the fix did NOT re-bridge the storm)

    /// The fix observes the coordinator directly — it must NOT have re-bridged
    /// `tabCoordinator.objectWillChange` into `DocumentModel.objectWillChange`
    /// (that's the PERF #1 storm `TabRepublishInvariantTests` guards). Both
    /// open and close stay at ZERO model republishes.
    func test_openAndClose_doNotRepublishDocumentModel() async throws {
        let model = makeModel()
        let url = try writeFile("a.md", "# a\n")
        await Task.yield()

        let openModelCount = await countModelRepublishes(of: model) {
            model.openInSplit(url)
        }
        XCTAssertEqual(openModelCount, 0,
            "openInSplit must NOT republish DocumentModel — ContentView observes the coordinator directly (PERF #1 invariant)")

        let closeModelCount = await countModelRepublishes(of: model) {
            model.closeSplit()
        }
        XCTAssertEqual(closeModelCount, 0,
            "closeSplit must NOT republish DocumentModel — same PERF #1 invariant")
    }

    // MARK: - Negative control (guards against a silently-disabled publisher)

    /// Without this, every test above would pass vacuously if the coordinator's
    /// `objectWillChange` were silently disabled. A direct `splitURL` assignment
    /// (the `@Published` the whole bug hinges on) must fire the signal.
    func test_splitURL_directAssignment_firesCoordinatorSignal() async throws {
        let model = makeModel()
        let url = try writeFile("a.md", "# a\n")
        await Task.yield()
        let count = await countCoordinatorRepublishes(of: model) {
            model.tabCoordinator.splitURL = url
        }
        XCTAssertGreaterThan(count, 0,
            "splitURL is @Published — a direct assignment must fire tabCoordinator.objectWillChange; if this is 0 the publisher is broken and the propagation tests are vacuous")
    }
}
