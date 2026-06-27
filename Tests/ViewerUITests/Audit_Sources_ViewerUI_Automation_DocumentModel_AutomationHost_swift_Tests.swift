import XCTest
import SwiftUI
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

    // MARK: - agent-readable journey state (split / vim / dirty)

    /// current_state exposes the journey-critical state an agent asserts on:
    /// split-open, vim-mode, and per-tab dirty — each reflecting the model.
    func test_currentState_reflects_split_vim_and_dirty_fields() throws {
        let model = makeModel()
        let a = try writeFile("s.md", "# A\n")
        _ = model.automationOpenPath(a, newTab: false)
        // Baseline: the new agent-readable fields are present + default-false.
        let st = model.automationCurrentState()
        XCTAssertFalse(st.isSplitOpen)
        XCTAssertFalse(st.vimModeEnabled)
        XCTAssertEqual(st.tabs.first?.isDirty, false)
        // Vim mode reflects the model.
        model.vimModeEnabled = true
        XCTAssertTrue(model.automationCurrentState().vimModeEnabled, "vimMode reflects the model")
        // Split state reflects the model.
        model.openInSplit(a)
        XCTAssertTrue(model.automationCurrentState().isSplitOpen, "split state reflects the model")
    }

    /// current_state mirrors the live session list (the app-level session-tab
    /// strip) so an agent can enumerate sessions to drive the session-* verbs by
    /// id/name — the READ half of the session action surface. Needs a wired
    /// coordinator (HeadlessHarness mirrors the main.swift launch wiring; the bare
    /// makeModel() has none → empty, which is the negative-control teeth).
    func test_currentState_lists_live_sessions() throws {
        let harness = HeadlessHarness(label: "AuditAutomationHostSessions")
        defer { harness.cleanup() }
        harness.model.sessionsCoordinator = harness.sessions  // mirror main.swift:421
        let coordinatorSessions = harness.sessions.core.sessions
        let st = harness.model.automationCurrentState()
        XCTAssertEqual(st.sessions.count, coordinatorSessions.count,
                       "current_state mirrors the coordinator's session count")
        XCTAssertEqual(Set(st.sessions.map { $0.id }),
                       Set(coordinatorSessions.map { $0.id.uuidString }),
                       "session ids round-trip to the coordinator")
        XCTAssertEqual(st.sessions.filter { $0.isActive }.count,
                       coordinatorSessions.isEmpty ? 0 : 1,
                       "exactly one active session is flagged when sessions exist")
        // Negative control: no coordinator wired → empty (the populate genuinely
        // READS the coordinator; it can't fabricate a list from a bare model).
        XCTAssertTrue(makeModel().automationCurrentState().sessions.isEmpty,
                      "no coordinator → empty session list")
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

    // MARK: - automationFind negative paths (TSK-164)

    /// [TSK-164] The Swift automation seam (`automationFind`) had zero
    /// negative-path coverage. These two tests pin the current behaviour of
    /// the two early-return / swallow branches in
    /// `Sources/ViewerUI/Automation/DocumentModel+AutomationHost.swift`:
    ///
    ///  1. a non-text selected tab (binary / preview / error / empty /
    ///     loading / `hostedView`) returns `[]` without ever touching
    ///     `FindEngine`, and
    ///  2. a syntactically-invalid regex query has its `FindEngine` throw
    ///     swallowed by the `try? … ?? []` on the search line, also yielding
    ///     `[]`.
    ///
    /// (2) documents *today's* behaviour — a hostile/invalid query is
    /// reduced to an empty result rather than surfaced as a tool error.
    /// When TSK-153 lands (round-tripping a `find` tool error instead of
    /// swallowing it) this assertion is expected to flip; the test then
    /// becomes the tripwire that forces it to be updated deliberately.

    /// A `.hostedView` tab is the simplest fully-synchronous non-text tab:
    /// `openHostedView` appends it and selection lands on it immediately
    /// (no async file load, no window, no WKWebView). `automationFind` must
    /// short-circuit to `[]` for any non-`.loaded` state.
    func test_automationFind_nonTextSelectedTab_returnsEmpty() throws {
        let model = makeModel()
        _ = model.openHostedView(title: "History", rootView: EmptyView())

        // Precondition: the selected tab is a non-text (hostedView) state.
        guard let tab = model.tabs.selected else {
            return XCTFail("openHostedView should leave a selected tab")
        }
        guard case .hostedView = tab.state else {
            return XCTFail("selected tab should be in .hostedView state, got \(tab.state)")
        }

        // A query that WOULD match if there were searchable text — proving
        // the empty result is the non-text guard firing, not an empty corpus.
        let q = FindQuery(pattern: "History", kind: .literal)
        XCTAssertEqual(model.automationFind(q), [],
                       "non-text selected tab must yield [] without searching")
    }

    /// An invalid-regex query against a loaded text tab. `FindEngine`
    /// throws `FindError.invalidRegex`; the `try? … ?? []` on the
    /// `automationFind` search line swallows it. `(` is an unbalanced
    /// group: it passes the ReDoS `RegexComplexityGuard.reject` (no nested
    /// quantifier, no alternation-under-quantifier) and fails only at
    /// `NSRegularExpression` compile — i.e. it exercises the `invalidRegex`
    /// throw, not the `unsafeRegex` guard.
    func test_automationFind_invalidRegex_swallowsThrowAsEmpty_today() throws {
        let model = makeModel()
        let a = try writeFile("a.md", "alpha (beta) gamma\n")
        _ = model.automationOpenPath(a, newTab: false)

        // Sanity: a literal substring search over the same loaded text DOES
        // find a hit, so the tab really is searchable and the [] below is
        // attributable to the swallowed regex throw, not an empty corpus.
        XCTAssertFalse(model.automationFind(FindQuery(pattern: "beta", kind: .literal)).isEmpty,
                       "precondition: the loaded text tab is searchable")

        // Today: the invalid-regex throw is reduced to []. When TSK-153
        // round-trips the find-tool error instead of swallowing it, this
        // assertion is expected to change.
        let bad = FindQuery(pattern: "(", kind: .regex)
        XCTAssertEqual(model.automationFind(bad), [],
                       "invalid regex is swallowed to [] today (pin until TSK-153)")
    }
}
