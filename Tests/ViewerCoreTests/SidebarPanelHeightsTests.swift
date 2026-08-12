import XCTest
import CoreGraphics
@testable import ViewerCore

/// Host-side pure-logic tests for the resizable sidebar sections
/// model. Drag-handle / cursor interaction is exercised by the
/// VM-only UI test bundles — see `ResizableSectionDivider.swift`.
///
/// (The window-fraction ceiling + the TSK-592 commit-suppression
/// predicate — and their tests — were DELETED 2026-08-12 in the owner's
/// special-case sweep: the one-rule stack is floors-only with overflow
/// scrolling; `SidebarStackLayoutTests` covers the live layout math.)
final class SidebarPanelHeightsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SidebarPanelHeightsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: clamp

    /// Owner 2026-08-12: NO minimum on any tool window — the floor is 0.
    /// The clamp's only remaining job is rejecting negative garbage.
    func test_clamp_floorIsZero_negativeGarbageClamps() {
        XCTAssertEqual(SidebarPanelHeights.clamp(0), 0)
        XCTAssertEqual(SidebarPanelHeights.clamp(40), 40,
                       "any non-negative height is legal — panels shrink to nothing")
        XCTAssertEqual(SidebarPanelHeights.clamp(-50), 0)
    }

    func test_clamp_passesThrough_anyNonNegativeHeight() {
        XCTAssertEqual(SidebarPanelHeights.clamp(120), 120)
        XCTAssertEqual(SidebarPanelHeights.clamp(400), 400)
    }

    // MARK: read-back

    func test_readClamped_returnsDefault_whenKeyMissing() {
        let value = SidebarPanelHeights.readClamped(.bookmarks, from: defaults)
        XCTAssertEqual(value, SidebarPanel.bookmarks.defaultHeight)
    }

    /// The clamp-on-read now only rejects NEGATIVE garbage (no floor —
    /// a persisted tiny height is a legitimate near-minimized panel).
    func test_readClamped_keepsTinyValues_rejectsNegative() {
        defaults.set(20.0, forKey: SidebarPanel.bookmarks.appStorageKey)
        XCTAssertEqual(SidebarPanelHeights.readClamped(.bookmarks, from: defaults), 20)
        defaults.set(-80.0, forKey: SidebarPanel.bookmarks.appStorageKey)
        XCTAssertEqual(SidebarPanelHeights.readClamped(.bookmarks, from: defaults), 0)
    }

    func test_readClamped_passesThroughLegalPersistedValue() {
        defaults.set(180.0, forKey: SidebarPanel.searchAnywhere.appStorageKey)
        let value = SidebarPanelHeights.readClamped(.searchAnywhere, from: defaults)
        XCTAssertEqual(value, 180.0)
    }

    // MARK: section identity

    /// Persistence keys are a public contract — renaming any of them
    /// invalidates per-user layout state. Pin them with a test so the
    /// rename can't slip through.
    func test_appStorageKeys_are_stable() {
        XCTAssertEqual(SidebarPanel.bookmarks.appStorageKey,
                       "MarkdownViewer.sidebar.bookmarks.height")
        XCTAssertEqual(SidebarPanel.searchAnywhere.appStorageKey,
                       "MarkdownViewer.sidebar.searchAnywhere.height")
        XCTAssertEqual(SidebarPanel.gitPanel.appStorageKey,
                       "MarkdownViewer.sidebar.gitPanel.height")
        XCTAssertEqual(SidebarPanel.claudeTimeline.appStorageKey,
                       "MarkdownViewer.sidebar.claudeTimeline.height")
        XCTAssertEqual(SidebarPanel.lspOutline.appStorageKey,
                       "MarkdownViewer.sidebar.lspOutline.height")
        XCTAssertEqual(SidebarPanel.recentlyOpened.appStorageKey,
                       "MarkdownViewer.sidebar.recentlyOpened.height")
        XCTAssertEqual(SidebarPanel.pluginSections.appStorageKey,
                       "MarkdownViewer.sidebar.pluginSections.height")
    }

    /// Owner 2026-08-12: the floor is ZERO — no tool window has a minimum
    /// height; panels shrink to nothing (header-only = "minimized") and
    /// their content scrolls internally. A revert to any positive floor
    /// goes red here.
    func test_noMinimumHeight_onAnyToolWindow() {
        XCTAssertEqual(SidebarPanelHeights.minExpandedHeight, 0)
    }
}
