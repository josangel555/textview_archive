import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Regression coverage for the audit fix in
/// `Sources/ViewerUI/Automation/DocumentModel+AutomationHost.swift`.
///
/// [S4 / contract] `automationCurrentState().selectedTabIndex` must be
/// 1-based so it round-trips through the `select_tab` tool, which consumes
/// a 1-based `byIndex` (`let zero = index - 1`). Before the fix it emitted
/// the internal 0-based `tabs.selectedIndex`, so an automation client that
/// read `current_state.selectedTabIndex` and fed it straight back into
/// `select_tab.byIndex` (the natural pattern) selected the wrong tab, and
/// feeding back `0` silently no-op'd.
///
/// Host-headless (`HeadlessUITestCase`); part of the merge gate. No window
/// is opened, no WKWebView is minted — this exercises only the
/// `DocumentModel` `AutomationHost` conformance over tab state.
@MainActor
final class Audit_Sources_ViewerUI_Automation_DocumentModel_AutomationHost_swift_Tests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuditAutomationHost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "AuditAutomationHost-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await super.tearDown()
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - selectedTabIndex is 1-based (round-trips with select_tab)

    /// The first tab is selected; `current_state` must report `1`, not the
    /// internal 0. (Tab creation / selection is synchronous in
    /// `openResolved`, independent of async file-load completion.)
    func test_currentState_firstTab_emits1Based() throws {
        let model = makeModel()
        let a = try writeFile("a.md", "# A\n")
        _ = model.automationOpenPath(a, newTab: false)

        XCTAssertEqual(model.tabs.selectedIndex, 0, "precondition: internal index is 0-based")
        XCTAssertEqual(model.automationCurrentState().selectedTabIndex, 1,
                       "current_state must emit selectedTabIndex 1-based")
    }

    /// The crux of the finding: read `current_state.selectedTabIndex` and
    /// feed it straight back into `select_tab.byIndex`. With the fix this is
    /// an identity (same tab stays selected, no off-by-one). Before the fix,
    /// feeding back the 0-based `0` no-op'd (`indices.contains(-1)` false).
    func test_selectedTabIndex_roundTripsThroughSelectTab() throws {
        let model = makeModel()
        let a = try writeFile("a.md", "# A\n")
        let b = try writeFile("b.md", "# B\n")
        _ = model.automationOpenPath(a, newTab: false)
        _ = model.automationOpenPath(b, newTab: true)

        // Select the first tab via the 1-based external API.
        XCTAssertTrue(model.automationSelectTab(byIndex: 1, byId: nil))
        XCTAssertEqual(model.tabs.selectedIndex, 0)

        // Read it back from current_state...
        guard let reported = model.automationCurrentState().selectedTabIndex else {
            return XCTFail("selectedTabIndex should be non-nil with tabs open")
        }
        XCTAssertEqual(reported, 1, "reported index is 1-based")

        // ...feed the SAME value back into select_tab: must be a no-op
        // (already selected), proving the bases agree. A base mismatch
        // would either move the selection or silently fail.
        XCTAssertFalse(model.automationSelectTab(byIndex: reported, byId: nil),
                       "re-selecting the already-selected tab via the reported index must no-op")
        XCTAssertEqual(model.tabs.selectedIndex, 0,
                       "round-trip must keep the same tab selected (no off-by-one)")

        // And selecting the second tab then reading back yields 2.
        XCTAssertTrue(model.automationSelectTab(byIndex: 2, byId: nil))
        XCTAssertEqual(model.automationCurrentState().selectedTabIndex, 2)
    }

    /// With no tabs open, `selectedIndex` is nil and must stay nil (the
    /// 1-based remap preserves the no-selection sentinel rather than
    /// reporting a spurious index).
    func test_currentState_noTabs_emitsNil() throws {
        let model = makeModel()
        XCTAssertNil(model.tabs.selectedIndex, "precondition: no tabs => nil")
        XCTAssertNil(model.automationCurrentState().selectedTabIndex,
                     "no selection must remain nil after 1-based remap")
    }
}
