import XCTest
@testable import ViewerCore

/// Focused coverage for the recently-opened sidebar panel.
///
/// `.recentlyOpened` is the newest `SidebarPanelKind` case (global,
/// history-gated, not root-scoped). The base `SidebarPanelKindTests`
/// suite notably DOES NOT pin its `appStorageKey` in
/// `test_appStorageKeys_are_stable` (nor `.lspNavigation`'s) — the
/// source comments call those keys "fresh, stable, pinned by tests",
/// so this file closes that gap: a rename of either persistence key
/// would silently invalidate user layout state on next launch.
///
/// Also pins the data-presence contract (`hasRecents` ⇒ present, global)
/// from the `SidebarDataPresence` angle the base suite touches lightly.
final class RecentlyOpenedPanelKindTests: XCTestCase {

    // MARK: - appStorageKey stability (the gap in the base suite)

    func test_recentlyOpened_appStorageKey_isStable() {
        XCTAssertEqual(SidebarPanelKind.recentlyOpened.appStorageKey,
                       "MarkdownViewer.sidebar.recentlyOpened.height")
    }

    /// `.lspNavigation`'s key is also absent from the base suite's
    /// stability pins — close that gap here so neither fresh key drifts.
    func test_lspNavigation_appStorageKey_isStable() {
        XCTAssertEqual(SidebarPanelKind.lspNavigation.appStorageKey,
                       "MarkdownViewer.sidebar.lspNavigation.height")
    }

    /// Every panel's `appStorageKey` must be unique — a collision would
    /// make two panels share persisted-height state. Catches a copy-paste
    /// of `recentlyOpened`'s key onto a future panel.
    func test_allAppStorageKeys_areUnique() {
        let keys = SidebarPanelKind.allCases.map(\.appStorageKey)
        XCTAssertEqual(Set(keys).count, keys.count,
                       "two panels share an appStorageKey: \(keys)")
    }

    /// Each key is namespaced under the stable `MarkdownViewer.sidebar.`
    /// prefix and ends in `.height` — the convention the @AppStorage
    /// readers and any defaults-migration tooling rely on.
    func test_recentlyOpened_appStorageKey_followsNamingConvention() {
        let key = SidebarPanelKind.recentlyOpened.appStorageKey
        XCTAssertTrue(key.hasPrefix("MarkdownViewer.sidebar."), key)
        XCTAssertTrue(key.hasSuffix(".height"), key)
    }

    // MARK: - Enum membership / identity

    /// `.recentlyOpened` must be in `allCases` and in the registry's
    /// default order — a case added to the enum but forgotten in the
    /// registry would never render.
    func test_recentlyOpened_isInAllCasesAndDefaultOrder() {
        XCTAssertTrue(SidebarPanelKind.allCases.contains(.recentlyOpened))
        XCTAssertTrue(SidebarPanelRegistry.defaultOrder.contains(.recentlyOpened))
    }

    /// It sits just before `.pluginSections` (history above the plugin
    /// catch-all) — pin the local order so a reshuffle is caught.
    func test_recentlyOpened_ordering_precedesPluginSections() {
        let order = SidebarPanelRegistry.defaultOrder
        guard let ri = order.firstIndex(of: .recentlyOpened),
              let pi = order.firstIndex(of: .pluginSections) else {
            return XCTFail("recentlyOpened / pluginSections missing from order")
        }
        XCTAssertLessThan(ri, pi)
    }

    /// `id` is the raw value (`Identifiable` conformance) — pinned because
    /// SwiftUI `ForEach` keys on it; a drift would reset per-row UI state.
    func test_recentlyOpened_id_equalsRawValue() {
        XCTAssertEqual(SidebarPanelKind.recentlyOpened.id, "recentlyOpened")
        XCTAssertEqual(SidebarPanelKind.recentlyOpened.rawValue, "recentlyOpened")
    }

    /// Rail-button surfaces are non-empty + their specific values are
    /// pinned (the base suite only asserts non-empty/unique across all).
    func test_recentlyOpened_displayNameAndSymbol() {
        XCTAssertEqual(SidebarPanelKind.recentlyOpened.displayName, "Recent")
        XCTAssertEqual(SidebarPanelKind.recentlyOpened.systemImage,
                       "clock.arrow.circlepath")
    }

    func test_recentlyOpened_defaultHeight_matchesParity() {
        XCTAssertEqual(SidebarPanelKind.recentlyOpened.defaultHeight, 220)
    }

    // MARK: - Codable raw-value stability

    /// The Codable representation is the raw value `"recentlyOpened"` —
    /// a workspace-state JSON written by an older build must still decode.
    func test_recentlyOpened_codableRawValue_isStable() throws {
        let data = try JSONEncoder().encode(SidebarPanelKind.recentlyOpened)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"recentlyOpened\"")
        let decoded = try JSONDecoder().decode(
            SidebarPanelKind.self, from: Data("\"recentlyOpened\"".utf8))
        XCTAssertEqual(decoded, .recentlyOpened)
    }

    // MARK: - Data-presence contract (global, history-gated)

    /// Present iff there are recents — and crucially GLOBAL: present even
    /// with no folder open (unlike root-gated panels). This is the
    /// distinguishing behavior of this panel.
    func test_presence_isGlobal_notRootGated() {
        // Recents present, no root → still shown.
        XCTAssertTrue(SidebarDataPresence.isPresent(
            .recentlyOpened,
            SidebarDataPresence.Inputs(hasRoot: false, hasRecents: true)))
        // Recents present, root open → shown.
        XCTAssertTrue(SidebarDataPresence.isPresent(
            .recentlyOpened,
            SidebarDataPresence.Inputs(hasRoot: true, hasRecents: true)))
        // No recents, root open → hidden (history is the only gate).
        XCTAssertFalse(SidebarDataPresence.isPresent(
            .recentlyOpened,
            SidebarDataPresence.Inputs(hasRoot: true, hasRecents: false)))
        // Nothing at all → hidden.
        XCTAssertFalse(SidebarDataPresence.isPresent(
            .recentlyOpened, SidebarDataPresence.Inputs()))
    }

    /// `hasRecents` is the ONLY input that toggles this panel — flipping
    /// any other input with recents fixed must not change its presence.
    func test_presence_ignoresUnrelatedInputs() {
        let withRecents = { (extra: (inout SidebarDataPresence.Inputs) -> Void) -> Bool in
            var i = SidebarDataPresence.Inputs(hasRecents: true)
            extra(&i)
            return SidebarDataPresence.isPresent(.recentlyOpened, i)
        }
        XCTAssertTrue(withRecents { $0.hasRoot = true })
        XCTAssertTrue(withRecents { $0.hasRepo = true })
        XCTAssertTrue(withRecents { $0.hasLSPLanguage = true })
        XCTAssertTrue(withRecents { $0.claudeHasTranscripts = true })
    }
}
