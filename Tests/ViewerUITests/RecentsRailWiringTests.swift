import XCTest
@testable import ViewerUI
import ViewerCore
import ViewerKit

/// Regression guard for the Recents shoulder-rail button wiring (2026-06-01).
///
/// `.recentlyOpened` is a registered `SidebarPanelKind`, so the rail's
/// `ForEach(panels)` already RENDERS a Recents toggle. The bug: both rail-side
/// `SidebarDataPresence.Inputs` builders (ContentView.railDataPresence,
/// ShoulderRailView.presence) omitted `hasRecents`, so it defaulted to false —
/// the button read permanently "no data" / off and the rail's presence
/// diverged from the accordion (SidebarView, which DID pass it). The fix wires
/// `hasRecents: !model.recents.isEmpty` into both rail builders.
///
/// We can't instantiate the private SwiftUI computed builders directly, so
/// these tests pin the two halves of the contract that, together, make the
/// button work: (1) opening a file populates `model.recents`, and (2) the
/// presence evaluator the rail uses resolves `.recentlyOpened` visible when
/// `hasRecents` is true — i.e. the wiring is the only remaining gap, and it's
/// now closed. A future re-drop of `hasRecents` from the rail builder would
/// make the live button wrong again; the structural intent is documented here
/// and the evaluator behaviour is locked.
@MainActor
final class RecentsRailWiringTests: XCTestCase {

    private var scratch: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyStoreURL: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-recents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // Isolated history + defaults so the test doesn't inherit the
        // developer's real recents (DocumentModel() reads persisted history).
        suiteName = "RecentsRailWiringTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        historyStoreURL = scratch.appendingPathComponent("history.json")
    }
    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
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

    func test_openingFile_populatesRecents_andRailPresenceResolvesVisible() throws {
        let model = makeModel()
        XCTAssertTrue(model.recents.isEmpty, "no recents before any open")

        // Pre-fix: with an empty recents list the rail presence for
        // .recentlyOpened is false (correct — nothing to show).
        let presenceEmpty = SidebarDataPresence.evaluate(
            SidebarDataPresence.Inputs(hasRecents: model.recents.isEmpty == false))
        XCTAssertEqual(presenceEmpty[.recentlyOpened], false,
                       "with no recents the Recents button should read off")

        // Open a file → it becomes a recent.
        let url = scratch.appendingPathComponent("note.md")
        try "hello\n".data(using: .utf8)!.write(to: url)
        model.open(url: url)
        XCTAssertFalse(model.recents.isEmpty, "opening a file records a recent")

        // The rail builder now passes `hasRecents: !model.recents.isEmpty`.
        // Reproduce that exact input and assert the panel resolves visible —
        // i.e. the wiring (had it been present pre-fix) produces the right
        // result. This is the behaviour the omitted `hasRecents` defeated.
        let presenceWithRecents = SidebarDataPresence.evaluate(
            SidebarDataPresence.Inputs(hasRecents: model.recents.isEmpty == false))
        XCTAssertEqual(presenceWithRecents[.recentlyOpened], true,
                       "after opening a file, the Recents rail button must read on/present")
    }

    func test_recentlyOpened_isARegisteredRailPanel() {
        // The Recents button only renders if .recentlyOpened is in the rail's
        // panel set. Pin that it's a real, default-ordered panel so the
        // button exists to be wired in the first place.
        XCTAssertTrue(SidebarPanelRegistry.defaultOrder.contains(.recentlyOpened),
                      ".recentlyOpened must be a default rail/accordion panel")
    }
}
