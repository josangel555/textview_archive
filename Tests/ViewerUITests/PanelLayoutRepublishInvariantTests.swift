import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Shoulder-rails invariant pin (2026-05-30).
///
/// `PanelLayoutStore` is a NEW observable owned by `DocumentModel`
/// (`public let panelLayout`). The whole point of the design is that
/// the rails / `SidebarView` / `ContentView` observe `model.panelLayout`
/// DIRECTLY — its `objectWillChange` must NOT be forwarded into
/// `DocumentModel.objectWillChange`.
///
/// This is the exact class of bug this branch already fixed twice:
///   - Forwarding it into DocumentModel ⇒ PERF #1 republish storm (a
///     rail toggle re-bodies the whole content tree).
///   - Leaving it observed-by-nobody ⇒ the `setCurrentViewMode`
///     dead-toggle (the rail/sidebar never re-body on a toggle).
///
/// Same shape as `SidebarRepublishInvariantTests` /
/// `TabRepublishInvariantTests`:
///   - mutate through `panelLayout`;
///   - assert `DocumentModel.objectWillChange` fires ZERO times;
///   - positive control: `panelLayout.objectWillChange` DOES fire on
///     its own mutation;
///   - negative control: `model.open` still republishes DocumentModel.
@MainActor
final class PanelLayoutRepublishInvariantTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelLayoutRepublishInvariantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "PanelLayoutRepublishInvariantTests-\(UUID().uuidString)"
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

    /// Count `DocumentModel.objectWillChange` fires during `mutate`.
    private func countDocumentRepublishes(
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

    // MARK: panelLayout shares the injected defaults

    /// Sanity: the store DocumentModel built reads from the same suite
    /// we injected via PreferencesStore — otherwise the toggle tests
    /// below would be exercising a `.standard`-backed store and could
    /// leak state across runs.
    func test_panelLayout_usesInjectedDefaults() async {
        // Pre-seed the suite with an override; a fresh model must load it.
        var seed = PanelVisibilityOverrides()
        seed.set(.git, .shown)
        seed.save(to: defaults)
        let model = makeModel()
        XCTAssertEqual(model.panelLayout.override(for: .git), .shown,
                       "PanelLayoutStore must load from the injected defaults suite")
    }

    // MARK: Visibility toggle must not republish DocumentModel

    func test_toggle_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.panelLayout.toggle(.git, dataPresent: false)
        }
        XCTAssertEqual(
            count, 0,
            "Rail toggle must not republish DocumentModel; rails/sidebar observe panelLayout directly"
        )
    }

    // MARK: Explicit override set must not republish DocumentModel

    func test_setOverride_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.panelLayout.setOverride(.bookmarks, .hidden)
        }
        XCTAssertEqual(
            count, 0,
            "Override set must not republish DocumentModel"
        )
    }

    // MARK: Edge assignment must not republish DocumentModel

    func test_setEdge_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.panelLayout.setEdge(.git, .right)
        }
        XCTAssertEqual(
            count, 0,
            "Edge assignment must not republish DocumentModel"
        )
    }

    // MARK: Positive control — panelLayout DOES republish on its own mutation

    /// Without this, a store with a silently-disabled `@Published` would
    /// make the "zero republishes" tests above vacuously true — the
    /// rail would never re-body and we'd never notice.
    func test_panelLayout_doesRepublishOnToggle() async {
        let model = makeModel()
        var count = 0
        let sub = model.panelLayout.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        model.panelLayout.toggle(.git, dataPresent: false)
        await Task.yield()
        XCTAssertGreaterThan(
            count, 0,
            "PanelLayoutStore.objectWillChange must fire on toggle so the rails/sidebar re-body"
        )
    }

    func test_panelLayout_doesRepublishOnSetEdge() async {
        let model = makeModel()
        var count = 0
        let sub = model.panelLayout.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        model.panelLayout.setEdge(.git, .right)
        await Task.yield()
        XCTAssertGreaterThan(
            count, 0,
            "PanelLayoutStore.objectWillChange must fire on edge change"
        )
    }

    // MARK: Negative control — DocumentModel still republishes on its own mutation

    /// Guards against a "publisher disabled" silent regression where
    /// every zero-republish test passes trivially.
    func test_documentModelOwnMutation_doesRepublish() async throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("a.md")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.open(url: url)
        }
        XCTAssertGreaterThan(
            count, 0,
            "DocumentModel.open must still republish — otherwise every other test in this file is vacuously true"
        )
    }

    // MARK: Write-through persistence

    /// A toggle persists synchronously into the injected defaults, so a
    /// fresh store on the same suite reads the same state back.
    func test_toggle_persistsThroughDefaults() async {
        let model = makeModel()
        model.panelLayout.toggle(.git, dataPresent: false)   // → .shown
        await Task.yield()
        XCTAssertEqual(model.panelLayout.override(for: .git), .shown)
        // "Relaunch": a brand-new store on the same suite.
        let reloaded = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(reloaded.override(for: .git), .shown,
                       "Toggle must write through to defaults synchronously")
    }
}
